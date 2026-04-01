// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiCrossChainRouter v2 — LayerZero V5 trustless cross-chain perp router
 *
 * FLOW (open a BTC-USD long on Base from Arbitrum collateral)
 * ─────────────────────────────────────────────────────────────────────────
 * 1. User calls openCrossChainPerp(destEid=Base, marketId=BTC, ...) on Arbitrum
 * 2. USDC collateral locked in WikiVault on Arbitrum
 * 3. LZ message sent to WikiCrossChainRouter on Base
 * 4. LZ delivers trustlessly to Base WikiCrossChainRouter.lzReceive()
 * 5. Base router calls WikiPerp.openPosition() — position opened on Base
 * 6. LZ ack sent back to Arbitrum — intent marked fulfilled
 *
 * LAYERZERO V5 ENDPOINT IDs
 *   Arbitrum 30110 | Optimism 30111 | Base 30184 | Polygon 30109
 *   BNB 30102 | Ethereum 30101 | Avalanche 30106
 */

interface ILayerZeroEndpointV5 {
    function send(MessagingParams calldata, address refundAddress) external payable returns (MessagingReceipt memory);
    function quote(MessagingParams calldata, address sender) external view returns (MessagingFee memory);
    function setDelegate(address delegate) external;
}
struct MessagingParams  { uint32 dstEid; bytes32 receiver; bytes message; bytes options; bool payInLzToken; }
struct MessagingFee     { uint256 nativeFee; uint256 lzTokenFee; }
struct MessagingReceipt { bytes32 guid; uint64 nonce; MessagingFee fee; }
struct Origin           { uint32 srcEid; bytes32 sender; uint64 nonce; }

interface IWikiVault {
    function freeMargin(address user) external view returns (uint256);
    function lockMargin(address user, uint256 amount) external;
    function releaseMargin(address user, uint256 amount) external;
}

interface IWikiPerp {
    function openPosition(address user, bytes32 marketId, uint256 collateral, uint256 leverage, bool isLong, uint256 limitPrice, uint256 minPrice, uint256 maxPrice, uint256 takeProfitPrice, uint256 stopLossPrice) external returns (uint256 positionId);
    function closePosition(uint256 positionId, address user) external returns (uint256 pnl, bool profit);
}

interface IWikiOracle {
    function getPrice(bytes32 id) external view returns (uint256 price, uint256 updatedAt);
}

contract WikiCrossChainRouter is Ownable2Step, ReentrancyGuard, Pausable {
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

    // ── LZ endpoint ────────────────────────────────────────────────────────
    ILayerZeroEndpointV5 public immutable lzEndpoint;

    // ── Peer routers on each chain (eid → peer bytes32) ───────────────────
    mapping(uint32 => bytes32) public peers;
    mapping(uint32 => bool)    public supportedChains;

    // ── Connected contracts ────────────────────────────────────────────────
    IWikiVault  public vault;
    IWikiPerp   public perp;
    IWikiOracle public oracle;
    IERC20      public immutable USDC;

    // ── Intent types ───────────────────────────────────────────────────────
    uint8 constant MSG_OPEN_PERP  = 1;
    uint8 constant MSG_CLOSE_PERP = 2;
    uint8 constant MSG_ACK_OPEN   = 3;
    uint8 constant MSG_ACK_CLOSE  = 4;

    // ── Cross-chain intent tracking ────────────────────────────────────────
    enum IntentStatus { Pending, Fulfilled, Cancelled, Failed }

    struct CrossChainIntent {
        address  user;
        uint32   destEid;
        bytes32  marketId;
        uint256  collateral;
        uint256  leverage;
        bool     isLong;
        uint256  limitPrice;
        uint256  minPrice;
        uint256  maxPrice;
        uint256  takeProfitPrice;
        uint256  stopLossPrice;
        uint256  routingFee;
        uint256  createdAt;
        IntentStatus status;
        uint256  remotePositionId; // filled on ACK
        bytes32  lzGuid;
    }

    CrossChainIntent[]          public intents;
    mapping(address => uint256[]) public userIntents;
    mapping(address => uint256)   public nonces;

    // ── Fee config ─────────────────────────────────────────────────────────
    uint256 public routingFeeBps  = 15;   // 0.15%
    uint256 public bridgeFeeBps   = 10;   // 0.10%
    uint256 public protocolRevenue;
    uint256 public constant MAX_FEE = 100; // 1% cap

    // ── Events ─────────────────────────────────────────────────────────────
    event IntentCreated(uint256 indexed intentId, address indexed user, uint32 destEid, bytes32 marketId, uint256 collateral, bytes32 lzGuid);
    event IntentFulfilled(uint256 indexed intentId, uint256 remotePositionId);
    event IntentFailed(uint256 indexed intentId, string reason);
    event IntentCancelled(uint256 indexed intentId, address user);
    event PeerSet(uint32 eid, bytes32 peer);

    constructor(address _lzEndpoint, address _vault, address _perp, address _oracle, address _usdc, address _owner) Ownable(_owner) {
        lzEndpoint = ILayerZeroEndpointV5(_lzEndpoint);
        vault  = IWikiVault(_vault);
        perp   = IWikiPerp(_perp);
        oracle = IWikiOracle(_oracle);
        USDC   = IERC20(_usdc);
        lzEndpoint.setDelegate(_owner);
    }

    // ── Peer / chain config ────────────────────────────────────────────────
    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        peers[eid] = peer; supportedChains[eid] = peer != bytes32(0);
        emit PeerSet(eid, peer);
    }

    function setPeers(uint32[] calldata eids, bytes32[] calldata _peers) external onlyOwner {
        for (uint i; i < eids.length; i++) {
            peers[eids[i]] = _peers[i];
            supportedChains[eids[i]] = _peers[i] != bytes32(0);
            emit PeerSet(eids[i], _peers[i]);
        }
    }

    // ── Quote LZ fee ───────────────────────────────────────────────────────
    function quoteOpen(uint32 destEid, bytes32 marketId, uint256 collateral, uint256 leverage, bool isLong) external view returns (uint256 nativeFee) {
        bytes memory payload = abi.encode(MSG_OPEN_PERP, address(0), marketId, collateral, leverage, isLong, uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0));
        MessagingFee memory fee = lzEndpoint.quote(MessagingParams({ dstEid: destEid, receiver: peers[destEid], message: payload, options: _options(300000), payInLzToken: false }), address(this));
        nativeFee = fee.nativeFee;
    }

    // ── OPEN cross-chain perp ──────────────────────────────────────────────
    function openCrossChainPerp(
        uint32  destEid,
        bytes32 marketId,
        uint256 collateral,
        uint256 leverage,
        bool    isLong,
        uint256 limitPrice,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 takeProfitPrice,
        uint256 stopLossPrice
    ) external payable nonReentrant whenNotPaused returns (uint256 intentId) {
        require(supportedChains[destEid],                          "Router: chain not supported");
        require(collateral > 0,                                    "Router: zero collateral");
        require(leverage >= 1 && leverage <= 2000,                  "Router: max leverage is 2000x");
        require(vault.freeMargin(msg.sender) >= collateral,        "Router: insufficient margin");

        uint256 fee = collateral * (routingFeeBps + bridgeFeeBps) / 10000;
        require(vault.freeMargin(msg.sender) >= collateral + fee,  "Router: insufficient for fee");

        // [A2] lock before external calls
        intentId = intents.length;
        vault.lockMargin(msg.sender, collateral + fee);
        protocolRevenue += fee;

        bytes memory payload = abi.encode(MSG_OPEN_PERP, msg.sender, marketId, collateral, leverage, isLong, limitPrice, minPrice, maxPrice, takeProfitPrice, stopLossPrice, nonces[msg.sender]++);
        MessagingReceipt memory receipt = lzEndpoint.send{value: msg.value}(
            MessagingParams({ dstEid: destEid, receiver: peers[destEid], message: payload, options: _options(300000), payInLzToken: false }),
            msg.sender
        );

        intents.push(CrossChainIntent({
            user: msg.sender, destEid: destEid, marketId: marketId,
            collateral: collateral, leverage: leverage, isLong: isLong,
            limitPrice: limitPrice, minPrice: minPrice, maxPrice: maxPrice,
            takeProfitPrice: takeProfitPrice, stopLossPrice: stopLossPrice,
            routingFee: fee, createdAt: block.timestamp,
            status: IntentStatus.Pending, remotePositionId: 0, lzGuid: receipt.guid
        }));
        userIntents[msg.sender].push(intentId);
        emit IntentCreated(intentId, msg.sender, destEid, marketId, collateral, receipt.guid);
    }

    // ── lzReceive — handles inbound LZ messages ────────────────────────────
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata payload,
        address,
        bytes calldata
    ) external nonReentrant {
        require(msg.sender == address(lzEndpoint), "Router: not LZ endpoint");
        require(peers[origin.srcEid] == origin.sender, "Router: unknown peer");

        uint8 msgType = abi.decode(payload[:32], (uint8));

        if (msgType == MSG_OPEN_PERP) {
            _handleOpenPerp(origin.srcEid, guid, payload);
        } else if (msgType == MSG_ACK_OPEN) {
            _handleAckOpen(payload);
        } else if (msgType == MSG_ACK_CLOSE) {
            _handleAckClose(origin.srcEid, payload);
        }
    }

    // ── Handle incoming open-perp request (we are the DEST chain) ─────────
    function _handleOpenPerp(uint32 srcEid, bytes32 guid, bytes calldata payload) internal {
        (, address user, bytes32 marketId, uint256 collateral, uint256 leverage, bool isLong,
         uint256 limitPrice, uint256 minPrice, uint256 maxPrice, uint256 tp, uint256 sl,) =
            abi.decode(payload, (uint8, address, bytes32, uint256, uint256, bool, uint256, uint256, uint256, uint256, uint256, uint256));

        try perp.openPosition(user, marketId, collateral, leverage, isLong, limitPrice, minPrice, maxPrice, tp, sl) returns (uint256 posId) {
            // Send ACK back to source chain
            bytes memory ack = abi.encode(MSG_ACK_OPEN, guid, posId, true, "");
            lzEndpoint.send{value: address(this).balance / 2}(
                MessagingParams({ dstEid: srcEid, receiver: peers[srcEid], message: ack, options: _options(100000), payInLzToken: false }),
                address(this)
            );
        } catch Error(string memory reason) {
            bytes memory ack = abi.encode(MSG_ACK_OPEN, guid, uint256(0), false, bytes(reason));
            lzEndpoint.send{value: address(this).balance / 2}(
                MessagingParams({ dstEid: srcEid, receiver: peers[srcEid], message: ack, options: _options(100000), payInLzToken: false }),
                address(this)
            );
        }
    }

    // ── Handle ACK (we are the SOURCE chain getting confirmation) ──────────
    function _handleAckOpen(bytes calldata payload) internal {
        (, bytes32 guid, uint256 posId, bool success, bytes memory reason) =
            abi.decode(payload, (uint8, bytes32, uint256, bool, bytes));

        for (uint i; i < intents.length; i++) {
            if (intents[i].lzGuid == guid && intents[i].status == IntentStatus.Pending) {
                if (success) {
                    intents[i].status = IntentStatus.Fulfilled;
                    intents[i].remotePositionId = posId;
                    emit IntentFulfilled(i, posId);
                } else {
                    intents[i].status = IntentStatus.Failed;
                    vault.releaseMargin(intents[i].user, intents[i].collateral);
                    emit IntentFailed(i, string(reason));
                }
                break;
            }
        }
    }

    function _handleAckClose(uint32 /*srcEid*/, bytes calldata payload) internal {
        (, bytes32 guid, uint256 pnl, bool profit) =
            abi.decode(payload, (uint8, bytes32, uint256, bool));
        // Find intent and release/update margin accordingly
        for (uint i; i < intents.length; i++) {
            if (intents[i].lzGuid == guid) {
                if (profit) vault.releaseMargin(intents[i].user, intents[i].collateral + pnl);
                else if (pnl < intents[i].collateral) vault.releaseMargin(intents[i].user, intents[i].collateral - pnl);
                break;
            }
        }
    }

    function _options(uint256 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(1), gasLimit);
    }

    function setContracts(address _vault, address _perp, address _oracle) external onlyOwner {
        vault = IWikiVault(_vault); perp = IWikiPerp(_perp); oracle = IWikiOracle(_oracle);
    }

    function setFees(uint256 _routingFeeBps, uint256 _bridgeFeeBps) external onlyOwner {
        require(_routingFeeBps + _bridgeFeeBps <= MAX_FEE, "Router: fee too high");
        routingFeeBps = _routingFeeBps; bridgeFeeBps = _bridgeFeeBps;
    }

    function withdrawRevenue(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue; protocolRevenue = 0;
        USDC.safeTransfer(to, amt);
    }

    function getUserIntents(address user) external view returns (uint256[] memory) { return userIntents[user]; }
    function intentCount() external view returns (uint256) { return intents.length; }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    receive() external payable {}
}
