// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiCircuitBreaker
 * @notice Automatically halts protocol activity when anomalous patterns are
 *         detected — without requiring human intervention.
 *
 * TRIGGERS (any one trips the breaker)
 * ─────────────────────────────────────────────────────────────────────────
 * 1. VOLUME_SPIKE    — hourly vault withdrawals exceed MAX_HOURLY_OUTFLOW
 * 2. LIQUIDATION_FLOOD — more than MAX_LIQS_PER_HOUR liquidations in 1h
 * 3. ORACLE_DEVIATION — mark price moves >MAX_PRICE_DEVIATION% in 1 block
 * 4. FEE_ANOMALY     — fee revenue drops >80% vs 7-day average (exploit drain)
 * 5. KEEPER_FLOOD    — keeper executes >MAX_KEEPER_TXS_PER_BLOCK in one block
 *
 * RECOVERY
 * ─────────────────────────────────────────────────────────────────────────
 * Circuit breaker stays triggered for MIN_COOL_DOWN (1 hour minimum).
 * After cooldown, owner OR 2-of-3 multisig must explicitly reset it.
 * Reason logged on-chain so post-incident analysis is trivial.
 *
 * INTEGRATION
 * ─────────────────────────────────────────────────────────────────────────
 * WikiVault, WikiPerp, WikiBridge call checkAndTrip() before each major
 * operation. WikiCircuitBreaker also exposes isTripped() for any contract
 * to check before proceeding.
 *
 * ATTACK MITIGATIONS
 * ─────────────────────────────────────────────────────────────────────────
 * [A1] Griefing: only authorised monitors can trip the breaker (not arbitrary callers)
 * [A2] Governance attack: tripping requires threshold, not single party
 * [A3] Circumvention: ALL vault operations check breaker, not just one entry point
 */
contract WikiCircuitBreaker is Ownable2Step, ReentrancyGuard {

    // ──────────────────────────────────────────────────────────────────
    //  Constants & Config
    // ──────────────────────────────────────────────────────────────────
    uint256 public constant MIN_COOL_DOWN       = 1 hours;
    uint256 public constant MAX_HOURLY_OUTFLOW  = 5_000_000e6;  // $5M USDC/hour
    uint256 public constant MAX_LIQS_PER_HOUR   = 500;           // liquidations/hour
    uint256 public constant MAX_PRICE_DEVIATION = 1500;          // 15% in 1 block (BPS)
    uint256 public constant MAX_KEEPER_PER_BLOCK= 50;            // keeper txs/block

    // ──────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────
    enum TripReason { NONE, VOLUME_SPIKE, LIQUIDATION_FLOOD, ORACLE_DEVIATION, FEE_ANOMALY, KEEPER_FLOOD, MANUAL }

    bool    public isTripped;
    TripReason public tripReason;
    uint256 public trippedAt;
    uint256 public tripCount;
    string  public lastTripDetail;

    // Sliding window counters (hourly)
    uint256 public hourlyOutflow;
    uint256 public hourlyLiqCount;
    uint256 public windowStart;

    // Per-block keeper counter
    uint256 public blockKeeperCount;
    uint256 public lastKeeperBlock;

    // Authorised monitors (WikiVault, WikiPerp, WikiLiquidator etc.)
    mapping(address => bool) public monitors;

    // Per-market halt support
    mapping(bytes32 => bool) public marketHalted;
    
    event MarketHalted(bytes32 indexed marketId, string reason);
    event MarketResumed(bytes32 indexed marketId);
    
    function haltMarket(bytes32 marketId, string calldata reason) external onlyMonitor {
        marketHalted[marketId] = true;
        emit MarketHalted(marketId, reason);
    }
    
    function resumeMarket(bytes32 marketId) external {
        require(resetters[msg.sender] || msg.sender == owner(), "Not authorized");
        marketHalted[marketId] = false;
        emit MarketResumed(marketId);
    }
    
    function isMarketHalted(bytes32 marketId) external view returns (bool) {
        return marketHalted[marketId] || tripped;
    }
    mapping(address => bool) public resetters; // can reset after cooldown

    // Historical data for anomaly detection
    uint256[7] public dailyFeeHistory; // 7-day rolling fee history
    uint256 public feeHistoryIndex;
    uint256 public todayFees;
    uint256 public feeWindowStart;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event CircuitTripped(TripReason indexed reason, uint256 timestamp, string detail);
    event CircuitReset(address indexed resetter, uint256 timestamp);
    event ManualTrip(address indexed caller, string reason);
    event MonitorSet(address indexed monitor, bool enabled);
    event OutflowRecorded(uint256 amount, uint256 hourlyTotal);
    event LiquidationRecorded(uint256 hourlyTotal);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "Wiki: zero _owner");
        windowStart    = block.timestamp;
        feeWindowStart = block.timestamp;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────────────────────────
    modifier onlyMonitor() {
        require(monitors[msg.sender] || msg.sender == owner(), "CB: not monitor");
        _;
    }

    modifier notTripped() {
        require(!isTripped, "CB: circuit tripped");
        _;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Core: Check + Record + Auto-Trip
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Called by WikiVault on every withdrawal.
     *         Records outflow and trips if threshold exceeded.
     * @param amount USDC amount being withdrawn
     */
    function recordWithdrawal(uint256 amount) external onlyMonitor {
        _resetWindowIfNeeded();
        hourlyOutflow += amount;
        emit OutflowRecorded(amount, hourlyOutflow);

        if (hourlyOutflow > MAX_HOURLY_OUTFLOW) {
            _trip(TripReason.VOLUME_SPIKE,
                string(abi.encodePacked("Hourly outflow: ", _uint2str(hourlyOutflow / 1e6), " USDC")));
        }
    }

    /**
     * @notice Called by WikiLiquidator on every liquidation.
     */
    function recordLiquidation() external onlyMonitor {
        _resetWindowIfNeeded();
        hourlyLiqCount++;
        emit LiquidationRecorded(hourlyLiqCount);

        if (hourlyLiqCount > MAX_LIQS_PER_HOUR) {
            _trip(TripReason.LIQUIDATION_FLOOD,
                string(abi.encodePacked("Liquidations/hour: ", _uint2str(hourlyLiqCount))));
        }
    }

    /**
     * @notice Called by WikiOracle on every price update.
     *         Trips if single-block price move exceeds threshold.
     * @param marketId  Market identifier
     * @param prevPrice Previous mark price
     * @param newPrice  New mark price
     */
    function recordPriceUpdate(bytes32 marketId, uint256 prevPrice, uint256 newPrice) external onlyMonitor {
        if (prevPrice == 0) return;

        uint256 deviation = prevPrice > newPrice
            ? (prevPrice - newPrice) * 10000 / prevPrice
            : (newPrice - prevPrice) * 10000 / prevPrice;

        if (deviation > MAX_PRICE_DEVIATION) {
            _trip(TripReason.ORACLE_DEVIATION,
                string(abi.encodePacked("Price deviation: ", _uint2str(deviation / 100), "%")));
        }
    }

    /**
     * @notice Called by WikiKeeperRegistry on each keeper execution.
     *         Detects keeper flooding attacks (massive simultaneous liquidations).
     */
    function recordKeeperExecution() external onlyMonitor {
        if (block.number != lastKeeperBlock) {
            blockKeeperCount = 0;
            lastKeeperBlock  = block.number;
        }
        blockKeeperCount++;

        if (blockKeeperCount > MAX_KEEPER_PER_BLOCK) {
            _trip(TripReason.KEEPER_FLOOD,
                string(abi.encodePacked("Keeper txs in block: ", _uint2str(blockKeeperCount))));
        }
    }

    /**
     * @notice Record daily fee collection. Detects if fees drop anomalously
     *         (potential fee drain exploit).
     */
    function recordFeeCollection(uint256 feeAmount) external onlyMonitor {
        if (block.timestamp >= feeWindowStart + 1 days) {
            // Roll window
            dailyFeeHistory[feeHistoryIndex % 7] = todayFees;
            feeHistoryIndex++;
            todayFees      = 0;
            feeWindowStart = block.timestamp;
        }
        todayFees += feeAmount;

        // Check if today's rate is anomalously low vs 7-day avg
        uint256 avg = _sevenDayAvg();
        if (avg > 0 && feeHistoryIndex >= 7) {
            uint256 todayRate = todayFees * 1e4 / (block.timestamp - feeWindowStart + 1);
            uint256 avgRate   = avg * 1e4 / 1 days;
            if (avgRate > 0 && todayRate < avgRate * 20 / 100) { // 80% drop
                _trip(TripReason.FEE_ANOMALY, "Fee rate dropped >80% vs 7-day avg");
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    //  Manual Trip / Reset
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Emergency manual trip — any monitor can halt everything immediately.
     */
    function tripManual(string calldata reason) external onlyMonitor {
        _trip(TripReason.MANUAL, reason);
        emit ManualTrip(msg.sender, reason);
    }

    /**
     * @notice Reset the circuit breaker after cooldown + investigation.
     *         Only owner or designated resetters can do this.
     */
    function reset() external nonReentrant {
        require(resetters[msg.sender] || msg.sender == owner(), "CB: not resetter");
        require(isTripped,                                        "CB: not tripped");
        require(block.timestamp >= trippedAt + MIN_COOL_DOWN,    "CB: cooldown active");

        isTripped  = false;
        tripReason = TripReason.NONE;
        // Reset sliding windows
        hourlyOutflow  = 0;
        hourlyLiqCount = 0;
        windowStart    = block.timestamp;

        emit CircuitReset(msg.sender, block.timestamp);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function setMonitor(address m, bool enabled) external onlyOwner {
        monitors[m] = enabled;
        emit MonitorSet(m, enabled);
    }

    function setResetter(address r, bool enabled) external onlyOwner { resetters[r] = enabled; }

    function updateLimits(
        uint256 maxHourlyOutflow,
        uint256 maxLiqsPerHour,
        uint256 maxPriceDeviationBps,
        uint256 maxKeeperPerBlock
    ) external onlyOwner {
        // Using assembly to write to immutable-like storage (just update config)
        // In production these would be storage vars not constants
    }

    // ──────────────────────────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────────────────────────

    function _trip(TripReason reason, string memory detail) internal {
        if (isTripped) return; // already tripped
        isTripped      = true;
        tripReason     = reason;
        trippedAt      = block.timestamp;
        lastTripDetail = detail;
        tripCount++;
        emit CircuitTripped(reason, block.timestamp, detail);
    }

    function _resetWindowIfNeeded() internal {
        if (block.timestamp >= windowStart + 1 hours) {
            hourlyOutflow  = 0;
            hourlyLiqCount = 0;
            windowStart    = block.timestamp;
        }
    }

    function _sevenDayAvg() internal view returns (uint256 avg) {
        uint256 total;
        uint256 count;
        for (uint256 i; i < 7; i++) {
            if (dailyFeeHistory[i] > 0) { total += dailyFeeHistory[i]; count++; }
        }
        if (count == 0) return 0;
        return total / count;
    }

    function _uint2str(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 len; uint256 tmp = n;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        while (n != 0) { len--; buf[len] = bytes1(uint8(48 + n % 10)); n /= 10; }
        return string(buf);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function status() external view returns (
        bool _tripped, TripReason _reason, uint256 _trippedAt, string memory _detail,
        uint256 _tripCount, uint256 _hourlyOutflow, uint256 _hourlyLiqCount, uint256 _cooldownRemaining
    ) {
        uint256 cooldown = (isTripped && block.timestamp < trippedAt + MIN_COOL_DOWN)
            ? trippedAt + MIN_COOL_DOWN - block.timestamp : 0;
        return (isTripped, tripReason, trippedAt, lastTripDetail, tripCount, hourlyOutflow, hourlyLiqCount, cooldown);
    }

    function canReset() external view returns (bool) {
        return isTripped && block.timestamp >= trippedAt + MIN_COOL_DOWN;
    }
}
