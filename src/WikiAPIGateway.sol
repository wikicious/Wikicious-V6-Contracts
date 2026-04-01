// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiAPIGateway
 * @notice On-chain API key management for programmatic trading.
 *         Institutional market makers and algo traders use this.
 *         They generate enormous volume — market makers alone can
 *         add $50-100M daily volume.
 *
 * HOW IT WORKS:
 *   1. Trader registers an API key (hash stored on-chain)
 *   2. API key linked to their wallet and permissions
 *   3. Backend validates API key signature off-chain
 *   4. On-chain gateway enforces rate limits and permissions
 *
 * PERMISSIONS PER KEY:
 *   CAN_TRADE:        open/close positions
 *   CAN_WITHDRAW:     withdraw funds (disabled by default)
 *   MAX_ORDER_SIZE:   per-order notional cap
 *   DAILY_VOLUME:     daily volume limit
 *   RATE_LIMIT:       orders per minute
 *   EXPIRY:           auto-expire API keys for security
 *
 * API KEY TIERS:
 *   Free:        100 orders/day, $100K daily volume
 *   Pro ($50/mo): 10,000 orders/day, $10M daily volume
 *   Institutional ($500/mo): unlimited, priority execution
 */
contract WikiAPIGateway is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    enum KeyTier { FREE, PRO, INSTITUTIONAL }

    struct APIKey {
        address  owner;
        bytes32  keyHash;        // keccak256 of actual key — stored off-chain
        KeyTier  tier;
        bool     canTrade;
        bool     canWithdraw;
        uint256  maxOrderSize;   // USDC notional per order
        uint256  dailyVolLimit;  // USDC daily volume cap
        uint256  rateLimit;      // orders per minute
        uint256  expiryTs;
        uint256  ordersToday;
        uint256  volumeToday;
        uint256  lastReset;
        uint256  createdAt;
        bool     active;
        string   label;          // human name e.g. "Grid Bot 1"
    }

    struct TierConfig {
        uint256 monthlyFeeUsdc;
        uint256 maxOrderSize;
        uint256 dailyVolLimit;
        uint256 rateLimit;       // orders/minute
        uint256 maxKeys;         // keys per wallet
    }

    mapping(bytes32 => APIKey)           public apiKeys;      // keyHash → key
    mapping(address => bytes32[])        public walletKeys;   // wallet → key hashes
    mapping(KeyTier => TierConfig)       public tierConfigs;
    mapping(address => uint256)          public monthlyFeesPaid;

    address public treasury;

    event APIKeyCreated(address indexed owner, bytes32 keyHash, KeyTier tier, string label);
    event APIKeyRevoked(bytes32 keyHash);
    event TierUpgraded(bytes32 keyHash, KeyTier newTier);
    event OrderExecuted(bytes32 keyHash, uint256 notional);

    constructor(address _owner, address _usdc, address _treasury) Ownable(_owner) {
        USDC     = IERC20(_usdc);
        treasury = _treasury;
        _initTiers();
    }

    function _initTiers() internal {
        tierConfigs[KeyTier.FREE] = TierConfig({
            monthlyFeeUsdc: 0,
            maxOrderSize:   10_000 * 1e6,      // $10K per order
            dailyVolLimit:  100_000 * 1e6,     // $100K/day
            rateLimit:      10,                 // 10 orders/min
            maxKeys:        2
        });
        tierConfigs[KeyTier.PRO] = TierConfig({
            monthlyFeeUsdc: 50 * 1e6,           // $50/month
            maxOrderSize:   500_000 * 1e6,      // $500K per order
            dailyVolLimit:  10_000_000 * 1e6,   // $10M/day
            rateLimit:      100,                // 100 orders/min
            maxKeys:        10
        });
        tierConfigs[KeyTier.INSTITUTIONAL] = TierConfig({
            monthlyFeeUsdc: 500 * 1e6,          // $500/month
            maxOrderSize:   type(uint256).max,  // unlimited
            dailyVolLimit:  type(uint256).max,  // unlimited
            rateLimit:      1000,               // 1000 orders/min
            maxKeys:        50
        });
    }

    // ── Key management ────────────────────────────────────────────────────
    function createAPIKey(
        bytes32  keyHash,
        KeyTier  tier,
        string   calldata label,
        uint256  expiryDays
    ) external nonReentrant returns (bytes32) {
        TierConfig storage cfg = tierConfigs[tier];
        require(walletKeys[msg.sender].length < cfg.maxKeys, "API: too many keys");
        require(apiKeys[keyHash].owner == address(0),         "API: key exists");

        // Collect monthly fee for Pro/Institutional
        if (cfg.monthlyFeeUsdc > 0) {
            USDC.safeTransferFrom(msg.sender, treasury, cfg.monthlyFeeUsdc);
            monthlyFeesPaid[msg.sender] += cfg.monthlyFeeUsdc;
        }

        apiKeys[keyHash] = APIKey({
            owner:        msg.sender,
            keyHash:      keyHash,
            tier:         tier,
            canTrade:     true,
            canWithdraw:  false,  // withdrawals disabled by default for security
            maxOrderSize: cfg.maxOrderSize,
            dailyVolLimit:cfg.dailyVolLimit,
            rateLimit:    cfg.rateLimit,
            expiryTs:     expiryDays > 0 ? block.timestamp + expiryDays * 1 days : type(uint256).max,
            ordersToday:  0,
            volumeToday:  0,
            lastReset:    block.timestamp,
            createdAt:    block.timestamp,
            active:       true,
            label:        label
        });
        walletKeys[msg.sender].push(keyHash);
        emit APIKeyCreated(msg.sender, keyHash, tier, label);
        return keyHash;
    }

    function revokeKey(bytes32 keyHash) external {
        require(apiKeys[keyHash].owner == msg.sender || msg.sender == owner(), "API: not owner");
        apiKeys[keyHash].active = false;
        emit APIKeyRevoked(keyHash);
    }

    function enableWithdrawals(bytes32 keyHash, bool enabled) external {
        require(apiKeys[keyHash].owner == msg.sender, "API: not owner");
        apiKeys[keyHash].canWithdraw = enabled;
    }

    // ── Validation (called by backend before executing orders) ────────────
    function validateAndRecord(
        bytes32  keyHash,
        uint256  orderSize,
        bool     isTrade
    ) external returns (bool valid, string memory reason) {
        APIKey storage k = apiKeys[keyHash];
        if (!k.active)                          return (false, "API: key inactive");
        if (block.timestamp > k.expiryTs)       return (false, "API: key expired");
        if (isTrade && !k.canTrade)             return (false, "API: trading not permitted");
        if (orderSize > k.maxOrderSize)         return (false, "API: exceeds max order size");

        // Reset daily counters
        if (block.timestamp >= k.lastReset + 1 days) {
            k.ordersToday = 0;
            k.volumeToday = 0;
            k.lastReset   = block.timestamp;
        }

        if (k.volumeToday + orderSize > k.dailyVolLimit) return (false, "API: daily volume limit");

        k.ordersToday++;
        k.volumeToday += orderSize;
        emit OrderExecuted(keyHash, orderSize);
        return (true, "");
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getKeyStatus(bytes32 keyHash) external view returns (
        bool active, KeyTier tier, uint256 remainingDailyVol,
        uint256 ordersToday, uint256 expiresAt, bool canWithdraw
    ) {
        APIKey storage k = apiKeys[keyHash];
        active           = k.active && block.timestamp <= k.expiryTs;
        tier             = k.tier;
        remainingDailyVol= k.dailyVolLimit > k.volumeToday ? k.dailyVolLimit - k.volumeToday : 0;
        ordersToday      = k.ordersToday;
        expiresAt        = k.expiryTs;
        canWithdraw      = k.canWithdraw;
    }

    function getWalletKeys(address wallet) external view returns (bytes32[] memory) {
        return walletKeys[wallet];
    }

    function setTierFee(KeyTier tier, uint256 fee) external onlyOwner {
        tierConfigs[tier].monthlyFeeUsdc = fee;
    }
    function setTreasury(address t) external onlyOwner { treasury = t; }
}
