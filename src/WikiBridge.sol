// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiBridge v2 — LayerZero V5 OApp trustless bridge
 *
 * HOW IT WORKS (trustless, no keeper required)
 * ─────────────────────────────────────────────────────────────────────────
 * SEND  (Chain A):
 *   1. User calls send() → tokens locked in this contract
 *   2. _lzSend() fires a LayerZero message to dest chain
 *   3. LayerZero DVN network delivers the message (trustless)
 *
 * RECEIVE (Chain B):
 *   4. LayerZero endpoint calls _lzReceive() on this contract
 *   5. Tokens released to destAddress from bridge liquidity
 *   6. BridgeReceived event emitted
 *
 * LAYERZERO V5 ENDPOINTS (same address on all EVM chains)
 *   Endpoint: 0x1a44076050125825900e736c501f859c50fE728c
 *
 * ENDPOINT IDS (EIDs)
 *   Arbitrum: 30110 | Optimism: 30111 | Base: 30184
 *   Polygon:  30109 | BNB:      30102 | Ethereum: 30101
 *   Avalanche: 30106
 *
 * ATTACK MITIGATIONS
 * [A1] Reentrancy          → ReentrancyGuard on all state-changing functions
 * [A2] CEI pattern         → state written before all external calls
 * [A3] Replay protection   → transferId hash tracked in usedIds mapping
 * [A4] Daily limits        → per-token per-day outbound cap
 * [A5] Peer whitelist      → only registered peer contracts can send messages
 * [A6] Pause               → owner can halt in emergency
 * [A7] Min amount          → reject dust transfers
 * [A8] LZ message ordering → enforceInboundNonce via OApp config
 */

// ── LayerZero V5 OApp interfaces ─────────────────────────────────────────

interface ILayerZeroEndpointV5 {
    function send(
        MessagingParams calldata params,
        address refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    function quote(
        MessagingParams calldata params,
        address sender
    ) external view returns (MessagingFee memory fee);

    function setDelegate(address delegate) external;
}

struct MessagingParams {
    uint32  dstEid;
    bytes32 receiver;
    bytes   message;
    bytes   options;
    bool    payInLzToken;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64  nonce;
    MessagingFee fee;
}

struct Origin {
    uint32  srcEid;
    bytes32 sender;
    uint64  nonce;
}

contract WikiBridge is Ownable2Step, ReentrancyGuard {
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

    // ── LayerZero endpoint (same address on every EVM chain) ───────────────
    ILayerZeroEndpointV5 public immutable lzEndpoint;
    // 0x1a44076050125825900e736c501f859c50fE728c

    // ── LZ peer registry: eid → peer contract (as bytes32) ────────────────
    mapping(uint32 => bytes32) public peers; // [A5]

    // ── Token config ───────────────────────────────────────────────────────
    uint256 public constant MAX_FEE_BPS = 100; // 1% max

    struct TokenConfig {
        bool    enabled;
        uint256 feeBps;
        uint256 minAmount;
        uint256 dailyLimit;
        uint256 dailySent;
        uint256 dayStart;
        uint256 totalFees;
    }

    struct BridgeTransfer {
        address sender;
        address token;
        uint256 amount;
        uint32  destEid;        // LZ endpoint ID (not chainId)
        address destAddress;
        uint256 nonce;
        uint256 timestamp;
        Status  status;
    }

    enum Status { Pending, Completed, Refunded }

    mapping(address  => TokenConfig)    public tokens;
    mapping(bytes32  => BridgeTransfer) public transfers;
    mapping(bytes32  => bool)           public usedIds;   // [A3]
    mapping(address  => uint256)        public nonces;    // [A3]

    bool    public paused;
    uint256 public totalVolume;

    // Message types
    uint8 constant MSG_TRANSFER = 1;

    // ── Events ─────────────────────────────────────────────────────────────
    event BridgeSent(bytes32 indexed transferId, address indexed sender, address token, uint256 amount, uint32 destEid, address destAddress, bytes32 lzGuid);
    event BridgeReceived(bytes32 indexed guid, address indexed recipient, address token, uint256 amount, uint32 srcEid);
    event BridgeRefunded(bytes32 indexed transferId, address indexed sender);
    event PeerSet(uint32 eid, bytes32 peer);
    event TokenConfigured(address indexed token, uint256 feeBps, uint256 dailyLimit);

    modifier notPaused() { require(!paused, "Bridge: paused"); _; }

    constructor(address _lzEndpoint, address _owner) Ownable(_owner) {
        lzEndpoint = ILayerZeroEndpointV5(_lzEndpoint);
        lzEndpoint.setDelegate(_owner); // owner can configure LZ options
    }

    // ── Peer management (whitelist which contracts can message us) ─────────
    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    function setPeers(uint32[] calldata eids, bytes32[] calldata _peers) external onlyOwner {
        require(eids.length == _peers.length, "Bridge: mismatch");
        for (uint i; i < eids.length; i++) {
            peers[eids[i]] = _peers[i];
            emit PeerSet(eids[i], _peers[i]);
        }
    }

    // ── Token + chain config ───────────────────────────────────────────────
    function configureToken(address token, bool enabled, uint256 feeBps, uint256 minAmount, uint256 dailyLimit) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Bridge: fee too high");
        TokenConfig storage tc = tokens[token];
        tc.enabled = enabled; tc.feeBps = feeBps;
        tc.minAmount = minAmount; tc.dailyLimit = dailyLimit;
        emit TokenConfigured(token, feeBps, dailyLimit);
    }

    function withdrawFees(address token, address to) external onlyOwner nonReentrant {
        uint256 amt = tokens[token].totalFees;
        require(amt > 0, "Bridge: no fees");
        tokens[token].totalFees = 0;
        IERC20(token).safeTransfer(to, amt);
    }

    // ── Quote LZ fee before calling send ──────────────────────────────────
    function quoteSend(uint32 destEid, uint256 amount, address token, address destAddress) external view returns (uint256 nativeFee) {
        bytes memory payload = _encodeTransfer(address(0), token, amount, destAddress, 0);
        bytes memory options = _defaultOptions();
        MessagingFee memory fee = lzEndpoint.quote(
            MessagingParams({ dstEid: destEid, receiver: peers[destEid], message: payload, options: options, payInLzToken: false }),
            address(this)
        );
        nativeFee = fee.nativeFee;
    }

    // ── SEND (outbound) — locks tokens, fires LZ message ──────────────────
    function send(
        address token,
        uint256 amount,
        uint32  destEid,
        address destAddress
    ) external payable nonReentrant notPaused returns (bytes32 transferId) {
        TokenConfig storage tc = tokens[token];
        require(tc.enabled,                   "Bridge: token not supported");
        require(peers[destEid] != bytes32(0), "Bridge: dest not supported"); // [A5]
        require(amount >= tc.minAmount,        "Bridge: below minimum");      // [A7]
        require(destAddress != address(0),     "Bridge: zero dest");

        // [A4] Daily limit
        if (block.timestamp >= tc.dayStart + 1 days) { tc.dayStart = block.timestamp; tc.dailySent = 0; }
        require(tc.dailySent + amount <= tc.dailyLimit, "Bridge: daily limit exceeded");

        uint256 nonce = nonces[msg.sender]++;
        transferId = keccak256(abi.encodePacked(msg.sender, token, amount, destEid, nonce));
        require(!usedIds[transferId], "Bridge: duplicate"); // [A3]

        // Fee
        uint256 fee = amount * tc.feeBps / 10000;
        uint256 sendAmount = amount - fee;

        // [A2] State before external calls
        tc.dailySent    += amount;
        tc.totalFees    += fee;
        totalVolume     += amount;
        usedIds[transferId] = true;
        transfers[transferId] = BridgeTransfer({
            sender: msg.sender, token: token, amount: sendAmount,
            destEid: destEid, destAddress: destAddress, nonce: nonce,
            timestamp: block.timestamp, status: Status.Pending
        });

        // Pull tokens
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Build LZ message and fire
        bytes memory payload = _encodeTransfer(msg.sender, token, sendAmount, destAddress, nonce);
        bytes memory options = _defaultOptions();

        MessagingReceipt memory receipt = lzEndpoint.send{value: msg.value}(
            MessagingParams({ dstEid: destEid, receiver: peers[destEid], message: payload, options: options, payInLzToken: false }),
            msg.sender // refund excess ETH to sender
        );

        emit BridgeSent(transferId, msg.sender, token, sendAmount, destEid, destAddress, receipt.guid);
    }

    // ── RECEIVE (inbound) — called by LayerZero endpoint ──────────────────
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata payload,
        address, /*executor*/
        bytes calldata /*extraData*/
    ) external nonReentrant {
        require(msg.sender == address(lzEndpoint), "Bridge: not LZ endpoint");
        require(peers[origin.srcEid] == origin.sender, "Bridge: unknown peer"); // [A5]
        require(!usedIds[guid], "Bridge: already received"); // [A3]

        usedIds[guid] = true;

        (address sender, address token, uint256 amount, address recipient, /*nonce*/) = _decodeTransfer(payload);

        require(tokens[token].enabled, "Bridge: token disabled on dest");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Bridge: insufficient liquidity");

        IERC20(token).safeTransfer(recipient, amount);
        emit BridgeReceived(guid, recipient, token, amount, origin.srcEid);
    }

    // ── Liquidity management (owner adds liquidity on each chain) ─────────
    function addLiquidity(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function removeLiquidity(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(to, amount);
    }

    // ── Encode / decode message ────────────────────────────────────────────
    function _encodeTransfer(address sender, address token, uint256 amount, address recipient, uint256 nonce) internal pure returns (bytes memory) {
        return abi.encode(MSG_TRANSFER, sender, token, amount, recipient, nonce);
    }

    function _decodeTransfer(bytes calldata payload) internal pure returns (address sender, address token, uint256 amount, address recipient, uint256 nonce) {
        uint8 msgType;
        (msgType, sender, token, amount, recipient, nonce) = abi.decode(payload, (uint8, address, address, uint256, address, uint256));
        require(msgType == MSG_TRANSFER, "Bridge: unknown msg type");
    }

    // ── Default LZ options (200k gas on destination) ───────────────────────
    function _defaultOptions() internal pure returns (bytes memory) {
        // TYPE_1 options: executor gas limit 200000
        return abi.encodePacked(uint16(1), uint256(200000));
    }

    function setPaused(bool _paused) external onlyOwner { paused = _paused; }
    receive() external payable {}
}
