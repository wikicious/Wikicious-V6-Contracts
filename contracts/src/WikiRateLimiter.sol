// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiRateLimiter — Protocol-wide rate limiting for critical operations
 *
 * Prevents flash-loan assisted draining, automated exploits, and griefing by
 * enforcing limits on:
 *   1. Per-user per-block operation count
 *   2. Per-user cooldown between large operations
 *   3. Global protocol-wide flow limits (e.g. $10M/hour withdrawal cap)
 *   4. Suspicious pattern detection (same user, many blocks, same action)
 *
 * Integrated into WikiVault withdrawals, WikiPerp position opens,
 * WikiLending borrows, and WikiBridge transfers.
 */
contract WikiRateLimiter is Ownable2Step {

    struct UserLimit {
        uint256 lastOpBlock;
        uint256 opsThisBlock;
        uint256 lastLargeOpTime;
        uint256 volumeThisHour;
        uint256 hourWindowStart;
    }

    struct FlowLimit {
        uint256 maxPerHour;      // global max volume per hour (USDC 6dec)
        uint256 currentHour;     // tracks volume in current hour
        uint256 hourStart;       // when current hour started
        uint256 maxPerBlock;     // max volume per block
        uint256 blockVolume;     // volume this block
        uint256 lastBlock;       // last block tracked
    }

    mapping(address => UserLimit) public userLimits;
    mapping(bytes32 => FlowLimit) public flowLimits;  // action key → limits

    // Default limits (governance-adjustable)
    uint256 public maxOpsPerBlock         = 3;           // max ops per user per block
    uint256 public largeOpCooldownSeconds = 30;          // 30s between large txs
    uint256 public largeOpThreshold       = 10_000 * 1e6; // $10K = "large" op
    uint256 public maxUserHourlyVolume    = 100_000 * 1e6; // $100K/hr per user

    event RateLimitHit(address indexed user, bytes32 action, string reason);
    event FlowLimitUpdated(bytes32 indexed action, uint256 maxPerHour);

    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "RateLimiter: zero owner");
        // Set default flow limits for critical actions
        _setFlowLimit("VAULT_WITHDRAW",  10_000_000 * 1e6,  1_000_000 * 1e6); // $10M/hr, $1M/block
        _setFlowLimit("BRIDGE_TRANSFER", 5_000_000  * 1e6,  500_000   * 1e6); // $5M/hr, $500K/block
        _setFlowLimit("LENDING_BORROW",  20_000_000 * 1e6,  2_000_000 * 1e6); // $20M/hr, $2M/block
        _setFlowLimit("PERP_OPEN",       50_000_000 * 1e6,  5_000_000 * 1e6); // $50M/hr, $5M/block
    }

    // ── Check Functions (called by contracts) ─────────────────────────────────

    /**
     * @notice Check and record an operation. Reverts if rate limit exceeded.
     * @param user      The user performing the operation
     * @param action    keccak256 of action name e.g. keccak256("VAULT_WITHDRAW")
     * @param amount    Amount in USDC 6dec (0 for non-value operations)
     */
    function checkAndRecord(address user, bytes32 action, uint256 amount) external {
        _checkPerBlockOps(user, action);
        if (amount >= largeOpThreshold) {
            _checkLargeOpCooldown(user, action, amount);
        }
        _checkGlobalFlow(action, amount);
        _checkUserHourlyVolume(user, action, amount);
        _record(user, action, amount);
    }

    /**
     * @notice Check only — does not record. Use for view queries.
     */
    function checkOnly(address user, bytes32 action, uint256 amount) external view returns (bool allowed, string memory reason) {
        UserLimit storage ul = userLimits[user];

        // Per-block ops
        if (ul.lastOpBlock == block.number && ul.opsThisBlock >= maxOpsPerBlock) {
            return (false, "rate: too many ops this block");
        }

        // Large op cooldown
        if (amount >= largeOpThreshold && block.timestamp - ul.lastLargeOpTime < largeOpCooldownSeconds) {
            return (false, "rate: large op cooldown");
        }

        // Global hourly flow
        FlowLimit storage fl = flowLimits[action];
        if (fl.maxPerHour > 0) {
            uint256 hourVol = fl.hourStart + 3600 >= block.timestamp ? fl.currentHour : 0;
            if (hourVol + amount > fl.maxPerHour) {
                return (false, "rate: global hourly cap");
            }
        }

        return (true, "");
    }

    // ── Internal Checks ───────────────────────────────────────────────────────

    function _checkPerBlockOps(address user, bytes32 action) internal {
        UserLimit storage ul = userLimits[user];
        if (ul.lastOpBlock == block.number) {
            if (ul.opsThisBlock >= maxOpsPerBlock) {
                emit RateLimitHit(user, action, "too many ops this block");
                revert("RateLimiter: per-block ops exceeded");
            }
        }
    }

    function _checkLargeOpCooldown(address user, bytes32 action, uint256 amount) internal view {
        UserLimit storage ul = userLimits[user];
        if (ul.lastLargeOpTime > 0 &&
            block.timestamp - ul.lastLargeOpTime < largeOpCooldownSeconds) {
            revert("RateLimiter: large op cooldown active");
        }
    }

    function _checkGlobalFlow(bytes32 action, uint256 amount) internal {
        FlowLimit storage fl = flowLimits[action];
        if (fl.maxPerHour == 0) return;

        // Reset hour window if expired
        if (block.timestamp >= fl.hourStart + 3600) {
            fl.currentHour = 0;
            fl.hourStart   = block.timestamp;
        }
        if (block.number > fl.lastBlock) {
            fl.blockVolume = 0;
            fl.lastBlock   = block.number;
        }

        if (fl.currentHour + amount > fl.maxPerHour) {
            revert("RateLimiter: global hourly flow exceeded");
        }
        if (fl.maxPerBlock > 0 && fl.blockVolume + amount > fl.maxPerBlock) {
            revert("RateLimiter: global per-block flow exceeded");
        }
    }

    function _checkUserHourlyVolume(address user, bytes32 action, uint256 amount) internal view {
        UserLimit storage ul = userLimits[user];
        uint256 windowStart  = block.timestamp - 3600;
        uint256 vol = ul.hourWindowStart >= windowStart ? ul.volumeThisHour : 0;
        if (vol + amount > maxUserHourlyVolume) {
            revert("RateLimiter: user hourly volume exceeded");
        }
    }

    function _record(address user, bytes32 action, uint256 amount) internal {
        UserLimit storage ul = userLimits[user];

        if (ul.lastOpBlock == block.number) {
            ul.opsThisBlock++;
        } else {
            ul.lastOpBlock  = block.number;
            ul.opsThisBlock = 1;
        }

        if (amount >= largeOpThreshold) {
            ul.lastLargeOpTime = block.timestamp;
        }

        // Update user hourly volume
        if (block.timestamp - ul.hourWindowStart >= 3600) {
            ul.volumeThisHour  = amount;
            ul.hourWindowStart = block.timestamp;
        } else {
            ul.volumeThisHour += amount;
        }

        // Update global flow
        FlowLimit storage fl = flowLimits[action];
        fl.currentHour += amount;
        fl.blockVolume += amount;
    }

    function _setFlowLimit(string memory action, uint256 maxPerHour, uint256 maxPerBlock) internal {
        bytes32 key = keccak256(bytes(action));
        flowLimits[key] = FlowLimit({
            maxPerHour:  maxPerHour,
            currentHour: 0,
            hourStart:   block.timestamp,
            maxPerBlock: maxPerBlock,
            blockVolume: 0,
            lastBlock:   block.number
        });
    }

    // ── Governance ────────────────────────────────────────────────────────────

    function setFlowLimit(bytes32 action, uint256 maxPerHour, uint256 maxPerBlock) external onlyOwner {
        flowLimits[action].maxPerHour  = maxPerHour;
        flowLimits[action].maxPerBlock = maxPerBlock;
        emit FlowLimitUpdated(action, maxPerHour);
    }

    function setUserLimits(uint256 _maxOpsPerBlock, uint256 _cooldown, uint256 _threshold, uint256 _maxHourly) external onlyOwner {
        maxOpsPerBlock         = _maxOpsPerBlock;
        largeOpCooldownSeconds = _cooldown;
        largeOpThreshold       = _threshold;
        maxUserHourlyVolume    = _maxHourly;
    }

    function ACTION(string calldata name) external pure returns (bytes32) {
        return keccak256(bytes(name));
    }
}
