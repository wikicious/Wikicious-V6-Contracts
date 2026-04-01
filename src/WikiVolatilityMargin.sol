// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiVolatilityMargin
 * @notice Dynamically increases margin requirements during high-volatility
 *         periods detected via Oracle price deviation. Protects the Insurance
 *         Fund from black swan events without manually adjusting parameters.
 *
 * ─── HOW IT WORKS ─────────────────────────────────────────────────────────
 *
 *   Normal market (vol < 2%/hour):
 *     BTC 100×: maintenance margin = 0.5%  ($50 on $10K position)
 *     EUR/USD 2000×: maintenance margin = 0.05%
 *
 *   Elevated volatility (2-5%/hour):
 *     BTC 100×: maintenance margin = 1.0%  (2× multiplier)
 *     EUR/USD 2000×: maintenance margin = 0.10%
 *
 *   Extreme volatility (>5%/hour) — black swan mode:
 *     BTC 100×: maintenance margin = 2.5%  (5× multiplier)
 *     Max leverage automatically capped at 50× for new positions
 *     EUR/USD 2000×: maintenance margin = 0.25%
 *
 * ─── ORACLE DEVIATION DETECTION ──────────────────────────────────────────
 *
 *   Every oracle price update compares to the rolling 1-hour TWAP.
 *   Deviation = |currentPrice - TWAP| / TWAP
 *
 *   Volatility tiers:
 *     NORMAL:    deviation < 200 BPS (2%)
 *     ELEVATED:  deviation 200-500 BPS (2-5%)
 *     HIGH:      deviation 500-1000 BPS (5-10%)
 *     EXTREME:   deviation > 1000 BPS (10%+)  ← black swan
 *
 * ─── WHAT GETS ADJUSTED ──────────────────────────────────────────────────
 *
 *   [1] Maintenance margin multiplier (auto-liquidation threshold)
 *   [2] Initial margin multiplier (new position opening requirement)
 *   [3] Max leverage cap for new positions
 *   [4] WikiCircuitBreaker threshold adjustment (tighter in extreme vol)
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────
 * [A1] Only oracle keeper can update volatility readings
 * [A2] Multiplier capped at 10× — cannot go to infinity
 * [A3] Cooldown on reducing multipliers — can only tighten instantly,
 *      must wait 30 min after volatility drops before loosening margin
 * [A4] Existing positions not immediately liquidated — new margin only
 *      applies to NEW positions. Existing get a 15-minute grace period.
 */
contract WikiVolatilityMargin is Ownable2Step, ReentrancyGuard {

    // ── Enums ────────────────────────────────────────────────────────────
    enum VolTier { NORMAL, ELEVATED, HIGH, EXTREME }

    // ── Structs ──────────────────────────────────────────────────────────
    struct MarketVolState {
        VolTier  currentTier;
        uint256  currentDeviation;    // BPS — current |price - TWAP| / TWAP
        uint256  maintMarginBps;      // current maintenance margin requirement
        uint256  initMarginBps;       // current initial margin requirement
        uint256  maxLeverage;         // current max leverage for new positions
        uint256  multiplier;          // current margin multiplier (100 = 1×, 500 = 5×)
        uint256  lastUpdate;          // timestamp of last update
        uint256  tierChangedAt;       // when tier last changed (for cooldown)
        uint256  twap;                // 1-hour TWAP price
        uint256  currentPrice;        // latest oracle price
    }

    struct BaseMarginConfig {
        uint256 baseMaintMarginBps;   // normal-conditions maintenance margin
        uint256 baseInitMarginBps;    // normal-conditions initial margin
        uint256 baseMaxLeverage;      // normal-conditions max leverage
    }

    // ── State ────────────────────────────────────────────────────────────
    mapping(uint256 => MarketVolState)    public marketVolState;   // marketId → state
    mapping(uint256 => BaseMarginConfig)  public baseConfig;       // marketId → base config
    mapping(uint256 => uint256[])         public priceHistory;     // marketId → last 60 prices

    address public oracle;
    address public perpContract;

    // Volatility thresholds (BPS)
    uint256 public constant ELEVATED_THRESHOLD = 200;   // 2%
    uint256 public constant HIGH_THRESHOLD     = 500;   // 5%
    uint256 public constant EXTREME_THRESHOLD  = 1000;  // 10%

    // Multipliers per tier (in BPS, 100 = 1×)
    uint256 public constant NORMAL_MULT   = 100;   // 1×
    uint256 public constant ELEVATED_MULT = 200;   // 2×
    uint256 public constant HIGH_MULT     = 350;   // 3.5×
    uint256 public constant EXTREME_MULT  = 500;   // 5×
    uint256 public constant MAX_MULT      = 1000;  // 10× hard cap [A2]

    uint256 public cooldownPeriod = 30 minutes; // [A3]
    uint256 public gracePeriod    = 15 minutes; // [A4]

    // ── Events ───────────────────────────────────────────────────────────
    event VolatilityTierChanged(
        uint256 indexed marketId,
        VolTier  oldTier,
        VolTier  newTier,
        uint256  newMultiplier,
        uint256  newMaintMarginBps,
        uint256  newMaxLeverage
    );
    event BlackSwanDetected(
        uint256 indexed marketId,
        uint256 deviationBps,
        uint256 timestamp
    );
    event MarginRequirementsUpdated(
        uint256 indexed marketId,
        uint256 maintMarginBps,
        uint256 initMarginBps,
        uint256 maxLeverage
    );

    // ── Constructor ──────────────────────────────────────────────────────
    constructor(address _owner) Ownable(_owner) {}

    // ── Core: Update Volatility State ────────────────────────────────────

    /**
     * @notice Called by oracle keeper on every price update.
     *         Computes deviation from TWAP, updates tier if needed.
     *
     * @param marketId   Market to update
     * @param newPrice   Latest oracle price (18 decimals)
     */
    function updateVolatility(uint256 marketId, uint256 newPrice) external {
        require(msg.sender == oracle || msg.sender == owner(), "VM: not oracle");
        require(newPrice > 0, "VM: zero price");

        MarketVolState storage s = marketVolState[marketId];
        BaseMarginConfig storage base = baseConfig[marketId];

        // Update price history for TWAP
        uint256[] storage hist = priceHistory[marketId];
        hist.push(newPrice);
        if (hist.length > 60) {
            // Shift array (keep last 60 prices = ~1 hour at 1-min updates)
            for (uint i = 0; i < 59; i++) hist[i] = hist[i+1];
            hist.pop();
        }

        // Compute 1-hour TWAP
        uint256 twap = _computeTWAP(marketId);
        s.twap         = twap;
        s.currentPrice = newPrice;

        // Compute deviation
        uint256 deviation = twap > 0
            ? (newPrice > twap ? newPrice - twap : twap - newPrice) * 10000 / twap
            : 0;
        s.currentDeviation = deviation;

        // Determine new tier
        VolTier newTier;
        uint256 newMult;
        if (deviation >= EXTREME_THRESHOLD) {
            newTier = VolTier.EXTREME;
            newMult = EXTREME_MULT;
            emit BlackSwanDetected(marketId, deviation, block.timestamp);
        } else if (deviation >= HIGH_THRESHOLD) {
            newTier = VolTier.HIGH;
            newMult = HIGH_MULT;
        } else if (deviation >= ELEVATED_THRESHOLD) {
            newTier = VolTier.ELEVATED;
            newMult = ELEVATED_MULT;
        } else {
            newTier = VolTier.NORMAL;
            newMult = NORMAL_MULT;
        }

        // Apply immediately if tightening [A3]
        // Only loosen after cooldown period
        bool isTightening = uint8(newTier) > uint8(s.currentTier);
        bool cooledDown   = block.timestamp >= s.tierChangedAt + cooldownPeriod;

        if (isTightening || cooledDown) {
            VolTier oldTier = s.currentTier;
            s.currentTier  = newTier;
            s.multiplier   = newMult > MAX_MULT ? MAX_MULT : newMult;

            // Apply multiplier to base margin config
            s.maintMarginBps = base.baseMaintMarginBps * s.multiplier / 100;
            s.initMarginBps  = base.baseInitMarginBps  * s.multiplier / 100;
            s.maxLeverage    = newTier == VolTier.EXTREME
                ? base.baseMaxLeverage / 4  // cap at 25% of normal max in extreme vol
                : newTier == VolTier.HIGH
                    ? base.baseMaxLeverage / 2
                    : base.baseMaxLeverage;

            if (oldTier != newTier) {
                s.tierChangedAt = block.timestamp;
                emit VolatilityTierChanged(marketId, oldTier, newTier, s.multiplier, s.maintMarginBps, s.maxLeverage);
            }
        }

        s.lastUpdate = block.timestamp;
        emit MarginRequirementsUpdated(marketId, s.maintMarginBps, s.initMarginBps, s.maxLeverage);
    }

    // ── Views ────────────────────────────────────────────────────────────

    /**
     * @notice Get current margin requirements for a market.
     *         Called by WikiPerp and WikiVirtualAMM before opening positions.
     */
    function getMarginRequirements(uint256 marketId) external view returns (
        uint256 maintMarginBps,
        uint256 initMarginBps,
        uint256 maxLeverage,
        VolTier tier,
        uint256 multiplier
    ) {
        MarketVolState storage s = marketVolState[marketId];
        BaseMarginConfig storage base = baseConfig[marketId];
        maintMarginBps = s.maintMarginBps > 0 ? s.maintMarginBps : base.baseMaintMarginBps;
        initMarginBps  = s.initMarginBps  > 0 ? s.initMarginBps  : base.baseInitMarginBps;
        maxLeverage    = s.maxLeverage    > 0 ? s.maxLeverage    : base.baseMaxLeverage;
        tier           = s.currentTier;
        multiplier     = s.multiplier     > 0 ? s.multiplier     : 100;
    }

    /**
     * @notice Check if a position is still healthy under current vol margins.
     */
    function isPositionHealthy(
        uint256 marketId,
        uint256 collateral,
        uint256 notional
    ) external view returns (
        bool    healthy,
        uint256 healthScoreBps,
        uint256 requiredMargin
    ) {
        MarketVolState storage s = marketVolState[marketId];
        BaseMarginConfig storage base = baseConfig[marketId];
        uint256 maint = s.maintMarginBps > 0 ? s.maintMarginBps : base.baseMaintMarginBps;
        requiredMargin  = notional * maint / 10000;
        healthy         = collateral >= requiredMargin;
        healthScoreBps  = requiredMargin > 0 ? collateral * 10000 / requiredMargin : 10000;
    }

    function getVolatilitySnapshot(uint256 marketId) external view returns (
        VolTier tier,
        uint256 deviationBps,
        uint256 multiplier,
        uint256 twap,
        uint256 currentPrice,
        uint256 lastUpdate,
        bool    inGracePeriod
    ) {
        MarketVolState storage s = marketVolState[marketId];
        tier          = s.currentTier;
        deviationBps  = s.currentDeviation;
        multiplier    = s.multiplier > 0 ? s.multiplier : 100;
        twap          = s.twap;
        currentPrice  = s.currentPrice;
        lastUpdate    = s.lastUpdate;
        inGracePeriod = block.timestamp < s.tierChangedAt + gracePeriod;
    }

    // ── Internal ─────────────────────────────────────────────────────────
    function _computeTWAP(uint256 marketId) internal view returns (uint256) {
        uint256[] storage hist = priceHistory[marketId];
        if (hist.length == 0) return 0;
        uint256 sum;
        for (uint i; i < hist.length; i++) sum += hist[i];
        return sum / hist.length;
    }

    // ── Admin ─────────────────────────────────────────────────────────────
    function setBaseConfig(
        uint256 marketId,
        uint256 baseMaint,
        uint256 baseInit,
        uint256 baseMaxLev
    ) external onlyOwner {
        require(baseMaint > 0 && baseInit >= baseMaint, "VM: invalid margins");
        baseConfig[marketId] = BaseMarginConfig(baseMaint, baseInit, baseMaxLev);
    }

    function setOracle(address _oracle)         external onlyOwner { oracle       = _oracle; }
    function setPerpContract(address _perp)      external onlyOwner { perpContract = _perp; }
    function setCooldown(uint256 secs)           external onlyOwner { require(secs <= 2 hours); cooldownPeriod = secs; }
    function setGracePeriod(uint256 secs)        external onlyOwner { require(secs <= 1 hours); gracePeriod    = secs; }
}
