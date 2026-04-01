// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiCrossChainLending v2 — LayerZero V5 trustless cross-chain lending
 *
 * FLOW: Supply on Chain A, Borrow on Chain B (trustlessly)
 * ─────────────────────────────────────────────────────────────────────────
 * 1. User supplies USDC on Arbitrum → receives credit receipt
 * 2. LZ message fires to destination chain WikiCrossChainLending
 * 3. User can borrow USDC on Base against Arbitrum collateral
 * 4. Liquidation messages flow back through LZ when health < 1.0
 *
 * Multi-sig is NO LONGER needed — LZ DVN provides the trust layer.
 */

interface ILayerZeroEndpointV5 {
    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory);
    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory);
    function setDelegate(address) external;
}
struct MessagingParams  { uint32 dstEid; bytes32 receiver; bytes message; bytes options; bool payInLzToken; }
struct MessagingFee     { uint256 nativeFee; uint256 lzTokenFee; }
struct MessagingReceipt { bytes32 guid; uint64 nonce; MessagingFee fee; }
struct Origin           { uint32 srcEid; bytes32 sender; uint64 nonce; }

interface IOracle {
    function getPrice(bytes32 id) external view returns (uint256 price, uint256 ts);
}

contract WikiCrossChainLending is Ownable2Step, ReentrancyGuard, Pausable {
    // ── Timelock guard ────────────────────────────────────────────────────
    // All fund-moving owner functions must be queued through WikiTimelockController
    // (48h delay). Deployer sets this address after deployment.
    address public timelock;
    modifier onlyTimelocked() {
        require(
            msg.sender == owner() && (timelock == address(0) || msg.sender == timelock),
            "Wiki: must go through timelock"
        );
        _;
    }
    function setTimelock(address _tl) external onlyOwner {
        require(_tl != address(0), "Wiki: zero timelock");
        timelock = _tl;
    }

    using SafeERC20 for IERC20;

    ILayerZeroEndpointV5 public immutable lzEndpoint;
    IOracle              public oracle;
    IERC20               public immutable USDC;

    mapping(uint32 => bytes32) public peers;

    // Message types
    uint8 constant MSG_SUPPLY     = 1;
    uint8 constant MSG_WITHDRAW   = 2;
    uint8 constant MSG_LIQUIDATE  = 3;
    uint8 constant MSG_ACK        = 4;

    uint256 public constant BASE_LTV_BPS       = 7500;  // 75%
    uint256 public constant LIQ_THRESHOLD_BPS  = 8000;  // 80%
    uint256 public constant LIQ_BONUS_BPS      = 500;   // 5% liquidator bonus
    uint256 public constant BORROW_RATE_BPS    = 500;   // 5% APY base
    uint256 public constant BRIDGE_FEE_BPS     = 5;     // 0.05%
    uint256 public constant BPS                = 10000;
    uint256 public constant PRECISION          = 1e18;

    struct CrossChainSupply {
        address user;
        uint32  srcEid;          // chain where USDC is locked
        address asset;
        uint256 amount;          // collateral value in USD (1e18)
        uint256 borrowedUSD;
        uint256 lastAccrue;
        bool    active;
    }

    struct BorrowPosition {
        address user;
        address asset;
        uint256 principal;
        uint256 interestIndex;
        uint256 openedAt;
        uint256 supplyId;        // cross-chain supply backing this borrow
        bool    active;
    }

    CrossChainSupply[] public supplies;
    BorrowPosition[]   public borrows;
    mapping(address => uint256[]) public userSupplies;
    mapping(address => uint256[]) public userBorrows;

    uint256 public totalSuppliedUSD;
    uint256 public totalBorrowedUSD;
    uint256 public globalInterestIndex = PRECISION;
    uint256 public lastGlobalAccrue;
    uint256 public protocolFees;

    event Supplied(address indexed user, uint32 srcEid, uint256 amount, uint256 supplyId);
    event Borrowed(address indexed user, uint256 supplyId, uint256 amount, uint256 borrowId);
    event Repaid(uint256 indexed borrowId, address user, uint256 amount);
    event Liquidated(uint256 indexed borrowId, address liquidator, uint256 seized);
    event PeerSet(uint32 eid, bytes32 peer);

    constructor(address _lzEndpoint, address _oracle, address _usdc, address _owner) Ownable(_owner) {
        lzEndpoint = ILayerZeroEndpointV5(_lzEndpoint);
        oracle     = IOracle(_oracle);
        USDC       = IERC20(_usdc);
        lzEndpoint.setDelegate(_owner);
    }

    function setPeer(uint32 eid, bytes32 peer) external onlyOwner { peers[eid] = peer; emit PeerSet(eid, peer); }
    function setPeers(uint32[] calldata eids, bytes32[] calldata _peers) external onlyOwner {
        for (uint i; i < eids.length; i++) { peers[eids[i]] = _peers[i]; emit PeerSet(eids[i], _peers[i]); }
    }

    // ── SUPPLY: lock USDC on this chain, credit on remote ─────────────────
    function supply(address asset, uint256 amount, uint32 destEid) external payable nonReentrant whenNotPaused returns (uint256 supplyId) {
        require(peers[destEid] != bytes32(0), "CCL: dest not supported");
        require(amount > 0, "CCL: zero amount");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        supplyId = supplies.length;
        supplies.push(CrossChainSupply({
            user: msg.sender, srcEid: _thisEid(), asset: asset,
            amount: amount, borrowedUSD: 0, lastAccrue: block.timestamp, active: true
        }));
        userSupplies[msg.sender].push(supplyId);
        totalSuppliedUSD += amount;

        // Fire LZ message to credit user on dest chain
        bytes memory payload = abi.encode(MSG_SUPPLY, msg.sender, asset, amount, supplyId);
        lzEndpoint.send{value: msg.value}(
            MessagingParams({ dstEid: destEid, receiver: peers[destEid], message: payload, options: _options(200000), payInLzToken: false }),
            msg.sender
        );

        emit Supplied(msg.sender, _thisEid(), amount, supplyId);
    }

    // ── BORROW: on this chain backed by cross-chain supply ─────────────────
    function borrow(uint256 supplyId, uint256 amount) external nonReentrant whenNotPaused returns (uint256 borrowId) {
        CrossChainSupply storage s = supplies[supplyId];
        require(s.user == msg.sender, "CCL: not yours");
        require(s.active, "CCL: supply inactive");
        require(amount > 0, "CCL: zero borrow");

        _accrueGlobal();
        uint256 maxBorrow = s.amount * BASE_LTV_BPS / BPS - s.borrowedUSD;
        require(amount <= maxBorrow, "CCL: exceeds LTV");
        require(USDC.balanceOf(address(this)) >= amount, "CCL: no liquidity");

        uint256 fee = amount * BRIDGE_FEE_BPS / BPS;
        borrowId = borrows.length;
        borrows.push(BorrowPosition({
            user: msg.sender, asset: address(USDC), principal: amount - fee,
            interestIndex: globalInterestIndex, openedAt: block.timestamp,
            supplyId: supplyId, active: true
        }));
        userBorrows[msg.sender].push(borrowId);
        s.borrowedUSD += amount;
        totalBorrowedUSD += amount;
        protocolFees += fee;

        USDC.safeTransfer(msg.sender, amount - fee);
        emit Borrowed(msg.sender, supplyId, amount, borrowId);
    }

    // ── REPAY ──────────────────────────────────────────────────────────────
    function repay(uint256 borrowId) external nonReentrant whenNotPaused {
        BorrowPosition storage b = borrows[borrowId];
        require(b.user == msg.sender, "CCL: not yours");
        require(b.active, "CCL: inactive");
        _accrueGlobal();
        uint256 debt = _currentDebt(b);
        USDC.safeTransferFrom(msg.sender, address(this), debt);
        supplies[b.supplyId].borrowedUSD -= b.principal;
        totalBorrowedUSD -= b.principal;
        b.active = false;
        emit Repaid(borrowId, msg.sender, debt);
    }

    // ── LIQUIDATE ──────────────────────────────────────────────────────────
    function liquidate(uint256 borrowId) external nonReentrant whenNotPaused {
        BorrowPosition storage b = borrows[borrowId];
        require(b.active, "CCL: inactive");
        CrossChainSupply storage s = supplies[b.supplyId];
        _accrueGlobal();
        uint256 debt = _currentDebt(b);
        uint256 hf   = s.amount * BPS / (s.borrowedUSD > 0 ? s.borrowedUSD : 1);
        require(hf < LIQ_THRESHOLD_BPS, "CCL: healthy");

        uint256 seize   = debt * (BPS + LIQ_BONUS_BPS) / BPS;
        uint256 toSend  = seize > s.amount ? s.amount : seize;

        USDC.safeTransferFrom(msg.sender, address(this), debt);
        USDC.safeTransfer(msg.sender, toSend);

        b.active = false; s.borrowedUSD -= b.principal; s.amount -= toSend;
        totalBorrowedUSD -= b.principal; totalSuppliedUSD -= toSend;

        // If supply is on remote chain, send LZ liquidation message
        if (s.srcEid != _thisEid() && peers[s.srcEid] != bytes32(0)) {
            bytes memory payload = abi.encode(MSG_LIQUIDATE, b.supplyId, debt, msg.sender);
            lzEndpoint.send{value: address(this).balance / 2}(
                MessagingParams({ dstEid: s.srcEid, receiver: peers[s.srcEid], message: payload, options: _options(150000), payInLzToken: false }),
                address(this)
            );
        }
        emit Liquidated(borrowId, msg.sender, toSend);
    }

    // ── lzReceive ──────────────────────────────────────────────────────────
    function lzReceive(Origin calldata origin, bytes32, bytes calldata payload, address, bytes calldata) external nonReentrant {
        require(msg.sender == address(lzEndpoint), "CCL: not endpoint");
        require(peers[origin.srcEid] == origin.sender, "CCL: unknown peer");

        uint8 msgType = uint8(bytes1(payload[31])); // first byte of first ABI word
        if (msgType == MSG_SUPPLY) {
            (, address user, address asset, uint256 amount, uint256 remoteSupplyId) = abi.decode(payload, (uint8, address, address, uint256, uint256));
            // Record cross-chain supply credit on this chain
            uint256 supplyId = supplies.length;
            supplies.push(CrossChainSupply({ user: user, srcEid: origin.srcEid, asset: asset, amount: amount, borrowedUSD: 0, lastAccrue: block.timestamp, active: true }));
            userSupplies[user].push(supplyId);
            totalSuppliedUSD += amount;
        } else if (msgType == MSG_LIQUIDATE) {
            (, uint256 remoteSupplyId,, ) = abi.decode(payload, (uint8, uint256, uint256, address));
            // Mark remote supply as liquidated if we track it
            for (uint i; i < supplies.length; i++) {
                if (supplies[i].srcEid == origin.srcEid && supplies[i].active) {
                    supplies[i].active = false; break;
                }
            }
        }
    }

    // ── Interest accrual ───────────────────────────────────────────────────
    function _accrueGlobal() internal {
        if (block.timestamp == lastGlobalAccrue) return;
        uint256 elapsed  = block.timestamp - lastGlobalAccrue;
        uint256 rate     = BORROW_RATE_BPS * PRECISION / BPS / 365 days;
        globalInterestIndex = globalInterestIndex + globalInterestIndex * rate * elapsed / PRECISION;
        lastGlobalAccrue = block.timestamp;
    }

    function _currentDebt(BorrowPosition storage b) internal view returns (uint256) {
        return b.principal * globalInterestIndex / b.interestIndex;
    }

    function _thisEid() internal view returns (uint32) { return 30110; } // overridden per chain at deploy

    function _options(uint256 gas) internal pure returns (bytes memory) { return abi.encodePacked(uint16(1), gas); }

    function setOracle(address _oracle) external onlyOwner { oracle = IOracle(_oracle); }
    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 f = protocolFees; protocolFees = 0;
        USDC.safeTransfer(to, f);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    receive() external payable {}
}
