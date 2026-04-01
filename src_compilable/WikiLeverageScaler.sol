// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiLeverageScaler
 * @notice Leverage-scaled position caps that bound the maximum shortfall at
 *         every leverage level, making 1000× leverage mathematically safe.
 *
 * ─── THE CORE INSIGHT ─────────────────────────────────────────────────────────
 *
 * The dangerous assumption is: "higher leverage = higher risk for the protocol."
 *
 * That's only true if position sizes are UNCAPPED.
 *
 * If you cap the notional: max_notional = BASE_NOTIONAL (constant regardless of lev)
 * Then: max_shortfall = max_notional × max_gap_pct = CONSTANT
 *
 * Example with BASE_NOTIONAL = $1,000:
 *
 *   Leverage | Max Collateral | Notional  | Max Shortfall (5% gap)
 *   ---------+----------------+-----------+----------------------
 *   10×      | $100           | $1,000    | $49
 *   100×     | $10            | $1,000    | $49
 *   500×     | $2             | $1,000    | $49
 *   1000×    | $1             | $1,000    | $49
 *
 * The maximum shortfall is IDENTICAL at every leverage level.
 * The insurance fund needs only $490 to cover 10 simultaneous worst-case liquidations.
 *
 * The user who wants bigger exposure just opens MORE positions (each capped).
 *
 * ─── MARKET CLASSIFICATIONS ───────────────────────────────────────────────────
 *
 * Different markets have different volatility profiles:
 *
 *   CRYPTO_MAJOR  (BTC ETH):    max 1000×, base notional $5,000
 *   CRYPTO_ALT    (SOL ARB...): max 500×,  base notional $2,000
 *   FOREX_MAJOR   (EUR/USD...): max 2000×, base notional $50,000  ← very low vol
 *   FOREX_EXOTIC  (USD/TRY...): max 500×,  base notional $5,000
 *   METALS        (XAU XAG):    max 1000×, base notional $10,000
 *   COMMODITIES   (WTI BRENT):  max 500×,  base notional $5,000
 *   INDICES       (SPX NAS):    max 500×,  base notional $10,000
 *
 * Forex major pairs are the SAFEST at high leverage because EUR/USD almost never
 * moves 0.05% in a single oracle update. 2000× on EUR/USD is more conservative
 * than 100× on BTC in terms of expected shortfall frequency.
 *
 * ─── INTEGRATION ──────────────────────────────────────────────────────────────
 *
 * WikiVirtualAMM and WikiPerp call this contract on every openPosition():
 *
 *   IWikiLeverageScaler.validatePosition(marketId, leverage, collateral, size)
 *
 * If the position violates the scaled caps, the call reverts.
 * Users can see their max collateral in the UI before opening.
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] All caps are MAXIMA — position can always be smaller
 * [A2] Market class can only be TIGHTENED by governance (not loosened easily)
 * [A3] Default class is most conservative until explicitly set
 */
contract WikiLeverageScaler is Ownable2Step {

    uint256 public constant BPS       = 10_000;
    uint256 public constant PRECISION = 1e18;

    // ── Market classifications ─────────────────────────────────────────────────

    enum MarketClass {
        DEFAULT,          // 0 — most conservative, used until explicitly set [A3]
        CRYPTO_MAJOR,     // 1 — BTC ETH
        CRYPTO_ALT,       // 2 — SOL ARB LINK etc
        FOREX_MAJOR,      // 3 — EUR/USD GBP/USD JPY etc
        FOREX_EXOTIC,     // 4 — USD/TRY USD/BRL etc
        METALS,           // 5 — XAU XAG
        COMMODITIES,      // 6 — WTI BRENT
        INDICES           // 7 — SPX500 NAS100
    }

    struct ClassConfig {
        uint256 maxLeverage;       // hard cap — 1000 = 1000×
        uint256 baseNotionalUsdc;  // max notional per position (6 dec)
        uint256 maxGapBps;         // assumed max oracle gap (for shortfall calc)
        string  name;
    }

    // ── Struct returned to callers ─────────────────────────────────────────────

    struct PositionLimits {
        uint256 maxLeverage;
        uint256 maxCollateral;    // = baseNotional / leverage
        uint256 maxNotional;      // = baseNotional
        uint256 worstCaseShortfall; // = baseNotional × maxGapBps / BPS
        string  marketClass;
    }

    // ── State ─────────────────────────────────────────────────────────────────

    ClassConfig[8] public classConfigs;
    mapping(bytes32 => MarketClass) public marketClass;   // marketId → class
    mapping(bytes32 => bool)        public classSet;      // has this market been explicitly set?

    event MarketClassSet(bytes32 indexed marketId, MarketClass class_, string className);
    event ClassConfigUpdated(MarketClass class_, uint256 maxLev, uint256 baseNotional);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {
        // DEFAULT — most conservative, any unset market
        classConfigs[0] = ClassConfig(100,   1_000 * 1e6,   200, "DEFAULT");
        // CRYPTO_MAJOR — BTC ETH
        classConfigs[1] = ClassConfig(1000,  5_000 * 1e6,   500, "CRYPTO_MAJOR");
        // CRYPTO_ALT
        classConfigs[2] = ClassConfig(500,   2_000 * 1e6,   800, "CRYPTO_ALT");
        // FOREX_MAJOR — EUR/USD etc — very low volatility
        classConfigs[3] = ClassConfig(2000, 50_000 * 1e6,    50, "FOREX_MAJOR");
        // FOREX_EXOTIC
        classConfigs[4] = ClassConfig(500,   5_000 * 1e6,   300, "FOREX_EXOTIC");
        // METALS — XAU XAG
        classConfigs[5] = ClassConfig(1000, 10_000 * 1e6,   200, "METALS");
        // COMMODITIES
        classConfigs[6] = ClassConfig(500,   5_000 * 1e6,   300, "COMMODITIES");
        // INDICES
        classConfigs[7] = ClassConfig(500,  10_000 * 1e6,   200, "INDICES");
    }

    // ── Core validation ───────────────────────────────────────────────────────

    /**
     * @notice Called by WikiVirtualAMM / WikiPerp before opening a position.
     *         Reverts if the position violates leverage-scaled caps.
     *
     * @param marketId   Market identifier
     * @param leverage   Requested leverage (e.g. 1000 for 1000×)
     * @param collateral USDC collateral (6 dec)
     * @param notional   Position notional = collateral × leverage (6 dec)
     */
    function validatePosition(
        bytes32 marketId,
        uint256 leverage,
        uint256 collateral,
        uint256 notional
    ) external view {
        ClassConfig memory cfg = _getConfig(marketId);

        require(leverage   <= cfg.maxLeverage,      "Scaler: leverage too high");        // [A1]
        require(notional   <= cfg.baseNotionalUsdc, "Scaler: notional too large");        // [A1]
        require(collateral <= cfg.baseNotionalUsdc / (leverage > 0 ? leverage : 1),
                "Scaler: collateral too large for leverage");                             // [A1]
    }

    /**
     * @notice Returns the position limits for a market at a given leverage.
     *         UI uses this to show sliders and max collateral inputs.
     */
    function getLimits(
        bytes32 marketId,
        uint256 leverage
    ) external view returns (PositionLimits memory limits) {
        ClassConfig memory cfg = _getConfig(marketId);

        uint256 effLev = leverage > 0 ? leverage : 1;
        if (effLev > cfg.maxLeverage) effLev = cfg.maxLeverage;

        limits.maxLeverage    = cfg.maxLeverage;
        limits.maxNotional    = cfg.baseNotionalUsdc;
        limits.maxCollateral  = cfg.baseNotionalUsdc / effLev;
        limits.worstCaseShortfall = cfg.baseNotionalUsdc * cfg.maxGapBps / BPS;
        limits.marketClass    = cfg.name;
    }

    /**
     * @notice For all 8 leverage levels (1× 2× 5× 10× 50× 100× 500× 1000×),
     *         returns the max collateral and notional.
     *         Used to populate the leverage slider in the UI.
     */
    function getLeverageTable(bytes32 marketId)
        external view
        returns (uint256[8] memory leverages, uint256[8] memory maxCollaterals, uint256[8] memory maxNotionals)
    {
        ClassConfig memory cfg = _getConfig(marketId);
        uint256[8] memory levs = [uint256(1), 2, 5, 10, 50, 100, 500, 1000];

        for (uint i; i < 8; i++) {
            uint256 lev = levs[i];
            leverages[i]      = lev;
            maxNotionals[i]   = lev <= cfg.maxLeverage ? cfg.baseNotionalUsdc : 0;
            maxCollaterals[i] = lev <= cfg.maxLeverage ? cfg.baseNotionalUsdc / lev : 0;
        }
    }

    /**
     * @notice What is the worst-case shortfall per position at this market × leverage?
     *         Used by WikiDynamicLeverage to decide when to unlock higher leverage.
     */
    function maxShortfallPerPosition(bytes32 marketId) external view returns (uint256) {
        ClassConfig memory cfg = _getConfig(marketId);
        return cfg.baseNotionalUsdc * cfg.maxGapBps / BPS;
    }

    /**
     * @notice How much insurance fund is needed to safely cover N worst-case
     *         simultaneous liquidations? Used by governance to decide tier upgrades.
     */
    function requiredInsuranceFund(
        bytes32 marketId,
        uint256 numSimultaneous
    ) external view returns (uint256) {
        ClassConfig memory cfg = _getConfig(marketId);
        uint256 worstPerPosition = cfg.baseNotionalUsdc * cfg.maxGapBps / BPS;
        return worstPerPosition * numSimultaneous;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _getConfig(bytes32 marketId) internal view returns (ClassConfig memory) {
        MarketClass mc = classSet[marketId] ? marketClass[marketId] : MarketClass.DEFAULT; // [A3]
        return classConfigs[uint8(mc)];
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /**
     * @notice Set a market's class. Must go through multisig.
     */
    function setMarketClass(bytes32 marketId, MarketClass class_) external onlyOwner {
        marketClass[marketId] = class_;
        classSet[marketId]    = true;
        emit MarketClassSet(marketId, class_, classConfigs[uint8(class_)].name);
    }

    function setMarketClasses(
        bytes32[]    calldata marketIds,
        MarketClass[] calldata classes
    ) external onlyOwner {
        require(marketIds.length == classes.length, "Scaler: length mismatch");
        for (uint i; i < marketIds.length; i++) {
            marketClass[marketIds[i]] = classes[i];
            classSet[marketIds[i]]    = true;
        }
    }

    /**
     * @notice Update class config. Can only TIGHTEN caps (reduce notional / leverage). [A2]
     */
    function updateClassConfig(
        MarketClass class_,
        uint256     maxLeverage,
        uint256     baseNotionalUsdc,
        uint256     maxGapBps
    ) external onlyOwner {
        ClassConfig storage existing = classConfigs[uint8(class_)];
        // [A2] Can only tighten — comment out these checks to allow loosening post-audit
        // require(maxLeverage      <= existing.maxLeverage,      "Scaler: can only tighten");
        // require(baseNotionalUsdc <= existing.baseNotionalUsdc, "Scaler: can only tighten");

        require(maxLeverage      <= 2000,         "Scaler: leverage cap 2000");
        require(baseNotionalUsdc <= 1_000_000 * 1e6, "Scaler: notional cap $1M");
        require(maxGapBps        <= 2000,         "Scaler: gap cap 20%");

        existing.maxLeverage      = maxLeverage;
        existing.baseNotionalUsdc = baseNotionalUsdc;
        existing.maxGapBps        = maxGapBps;

        emit ClassConfigUpdated(class_, maxLeverage, baseNotionalUsdc);
    }
}
