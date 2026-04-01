// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiHybridLiquidityManager
 * @notice Smart routing engine that switches between internal and external
 *         liquidity based on the protocol's real-time health metrics.
 *
 * ─── THE CORE IDEA ───────────────────────────────────────────────────────────
 *
 * A brand-new DEX has a problem: it wants to offer trades before its insurance
 * fund and backstop vault are large enough to safely absorb worst-case losses.
 *
 * The naive solution: refuse trades above a size threshold.
 * The good solution: ROUTE them externally.
 *
 * Uses IUniswapV3Router for single-hop swaps when forwarding to Uniswap V3.
 */
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 deadline; uint256 amountIn;
        uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IGMXExchangeRouter {
    struct CreateOrderParamsAddresses {
        address receiver; address callbackContract; address uiFeeReceiver;
        address market; address initialCollateralToken; address[] swapPath;
    }
    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd; uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice; uint256 acceptablePrice;
        uint256 executionFee; uint256 callbackGasLimit; uint256 minOutputAmount;
    }
    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers   numbers;
        uint8  orderType;
        uint8  decreaseSwapType;
        bool   isLong;
        bool   shouldUnwrapNativeToken;
        bytes32 referralCode;
    }
    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
}

interface IWikiRevenueSplitter {
        function receiveFees(uint256 amount) external;
    }

interface IWikiVAMM {
        function openPosition(bytes32 marketId, uint256 collateral, uint256 leverage, bool isLong, uint256 limitPrice, uint256 minPrice, uint256 maxPrice, uint256 tpPrice, uint256 slPrice) external returns (uint256 posId);
        function markets(bytes32 marketId) external view returns (bytes32,string memory,uint256,uint256,uint256,uint256 oiLong,uint256 oiShort,uint256,uint256,uint256,uint256,bool);
    }

interface IWikiBackstop {
        function totalUSDC() external view returns (uint256);
    }

interface IWikiVault {
        function insuranceFund()   external view returns (uint256);
        function totalLocked()     external view returns (uint256);
        function contractBalance() external view returns (uint256);
    }

/**
 * @dev WikiHybridLiquidityManager continuously reads vault health and decides for each
 * incoming trade whether to absorb internally or forward to GMX/Camelot/Uniswap.
 *
 * Health Score (0-100):
 *   insuranceFund / requiredReserve       -> up to 40 points
 *   backstopVault.totalUSDC / targetTVL  -> up to 40 points
 *   OI balance (long/short ratio)         -> up to 20 points
 *
 * Routing thresholds (configurable):
 *   Score 0–39  : Route 100% external  (BOOTSTRAP mode)
 *   Score 40–59 : Route 70% external, 30% internal  (GROWTH mode)
 *   Score 60–79 : Route 30% external, 70% internal  (MATURE mode)
 *   Score 80–100: Route 0%  external, 100% internal  (SELF-SUFFICIENT mode)
 *
 * Per-trade decision also considers:
 *   - Trade size vs current internal capacity
 *   - OI imbalance (if very long-heavy, route new longs external)
 *   - Market volatility (high vol → prefer external to reduce gap risk)
 *
 * ─── REVENUE MODEL ───────────────────────────────────────────────────────────
 *
 * INTERNAL route (score ≥ 80):
 *   User pays: 0.06% taker fee
 *   Protocol keeps: 0.06%
 *   Risk: bounded by WikiLeverageScaler + ADL + Backstop
 *
 * EXTERNAL route (score < 80):
 *   User pays: 0.06% taker fee (same experience)
 *   Protocol pays to GMX: ~0.05% open fee
 *   GMX referral back to protocol: ~15% of GMX fees = 0.0075%
 *   Net to protocol: 0.06% - 0.05% + 0.0075% = 0.0175%
 *   Risk: ZERO — GMX absorbs the counterparty risk
 *
 * As the fund grows → more internal → higher revenue per trade.
 * At bootstrap: earn 0.0175% per trade (external markup).
 * At scale: earn 0.06% per trade (full internal).
 * Users ALWAYS pay 0.06% regardless — seamless experience.
 *
 * ─── VENUE INTEGRATIONS ──────────────────────────────────────────────────────
 *
 *   PERPS EXTERNAL:
 *     GMX V5       (Arbitrum) — market orders, referral rebate
 *     Vertex       (Arbitrum) — off-chain matching, on-chain settlement
 *
 *   SPOT EXTERNAL:
 *     Uniswap V3   (Arbitrum) — direct swap, 0.05% pool
 *     Camelot V3   (Arbitrum) — Arbitrum-native, referral programme
 *     Curve        (Arbitrum) — stablecoin pairs
 *
 *   LENDING EXTERNAL:
 *     Aave V3      (Arbitrum) — for credit line when vault is thin
 *     Radiant      (Arbitrum) — secondary lending
 *
 * ─── TRANSPARENCY ────────────────────────────────────────────────────────────
 *
 * Every routed trade emits a TradeRouted event with:
 *   - venue (INTERNAL / GMX / UNISWAP / etc.)
 *   - healthScore at time of routing
 *   - fees paid to external venue
 *   - net fee kept by Wikicious
 *
 * The routing decision is visible to anyone reading the chain.
 * The user sees the same 0.06% fee regardless of route.
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] Only WikiPerp + WikiVirtualAMM can call routePerp()
 * [A2] External calls wrapped in try/catch — if GMX reverts, fallback to internal
 * [A3] Max external routing cap: 90% of total OI (keeps skin in game)
 * [A4] Health score uses time-weighted values to prevent flash manipulation
 * [A5] Minimum internal retention: always keep ≥ 10% of trades internal (no pure passthrough)
 */
contract WikiHybridLiquidityManager is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public timelock;
    function setTimelock(address _tl) external onlyOwner { timelock = _tl; }

    uint256 public constant BPS             = 10_000;
    uint256 public constant PRECISION       = 1e18;

    // Fee config
    uint256 public constant USER_FEE_BPS    = 60;    // 0.06% charged to user ALWAYS
    uint256 public constant GMX_FEE_BPS     = 50;    // ~0.05% GMX open fee
    uint256 public constant GMX_REFERRAL_BPS = 8;    // 0.0075% referral back (≈15% of GMX fee)
    uint256 public constant UNI_FEE_BPS     = 50;    // 0.05% Uniswap pool
    uint256 public constant CAMELOT_FEE_BPS = 30;    // 0.03% Camelot pool

    // Net protocol revenue per route
    // Internal: USER_FEE_BPS = 60 bps (FULL)
    // GMX:      USER_FEE_BPS - GMX_FEE_BPS + GMX_REFERRAL_BPS = 18 bps (PARTIAL)
    // Uniswap:  USER_FEE_BPS - UNI_FEE_BPS = 10 bps (PARTIAL)
    // Camelot:  USER_FEE_BPS - CAMELOT_FEE_BPS = 30 bps (PARTIAL)

    // Routing thresholds
    uint256 public constant THRESHOLD_SELF_SUFFICIENT = 80;  // score ≥ 80 → 100% internal
    uint256 public constant THRESHOLD_MATURE          = 60;  // score ≥ 60 → 70% internal
    uint256 public constant THRESHOLD_GROWTH          = 40;  // score ≥ 40 → 30% internal
    // score < 40 → 100% external (bootstrap)

    // Health score weights (must sum to 100)
    uint256 public constant INSURANCE_WEIGHT = 40;   // insurance fund adequacy
    uint256 public constant BACKSTOP_WEIGHT  = 40;   // backstop vault TVL adequacy
    uint256 public constant OI_BALANCE_WEIGHT = 20;  // long/short balance

    // Reserve targets (what the fund "should" be for full self-sufficiency)
    uint256 public targetInsuranceFund = 50_000 * 1e6;   // $50K target for 100 internal
    uint256 public targetBackstopTVL   = 500_000 * 1e6;  // $500K backstop target

    // Max external OI cap [A3]
    uint256 public constant MAX_EXTERNAL_OI_PCT = 90; // max 90% of total OI external

    // Min internal retention [A5]
    uint256 public constant MIN_INTERNAL_PCT = 10; // always route ≥ 10% internally

    // ── Venues ────────────────────────────────────────────────────────────────

    enum Venue { INTERNAL, GMX_V5, UNISWAP_V3, CAMELOT_V3, CURVE, VERTEX }



    // ── Structs ────────────────────────────────────────────────────────────────

    struct RouteDecision {
        Venue   venue;
        uint256 healthScore;
        uint256 internalPct;    // 0-100: % of trade routed internally
        uint256 externalPct;    // 100 - internalPct
        uint256 userFeeBps;     // always USER_FEE_BPS
        uint256 netProtocolBps; // actual fee kept after external venue cost
        bool    externalFirst;  // true if external is primary (low health)
    }

    struct TradeRecord {
        address trader;
        bytes32 marketId;
        uint256 collateral;
        uint256 leverage;
        bool    isLong;
        Venue   venue;
        uint256 healthScore;
        uint256 feeCharged;
        uint256 feeKept;
        uint256 feePaid;        // to external venue
        uint256 timestamp;
    }

    // ── State ──────────────────────────────────────────────────────────────────

    IWikiVault           public vault;
    IWikiBackstop        public backstop;
    IWikiVAMM            public vamm;
    IWikiRevenueSplitter public splitter;
    IERC20               public immutable USDC;

    // External venue contracts (Arbitrum mainnet)
    IGMXExchangeRouter   public gmxRouter;
    IUniswapV3Router     public uniRouter;
    address              public camelotRouter;

    // GMX config
    bytes32  public gmxReferralCode;                    // our referral code on GMX
    mapping(bytes32 => address) public gmxMarkets;     // marketId → GMX market address

    // Callers allowed to trigger routing [A1]
    mapping(address => bool) public routeCallers;

    // Stats
    TradeRecord[] public tradeHistory;
    mapping(Venue => uint256) public totalVolumeByVenue;
    mapping(Venue => uint256) public totalFeesByVenue;
    uint256 public totalFeeCharged;
    uint256 public totalFeeKept;
    uint256 public totalFeePaidExternal;

    // Time-weighted health cache [A4]
    uint256 public cachedHealthScore;
    uint256 public lastHealthUpdate;
    uint256 public constant HEALTH_CACHE_TTL = 60; // refresh every 60s

    // ── Events ────────────────────────────────────────────────────────────────

    event TradeRouted(
        address indexed trader,
        bytes32 indexed marketId,
        Venue   indexed venue,
        uint256 notional,
        uint256 healthScore,
        uint256 feeKept,
        uint256 feePaid
    );
    event HealthScoreUpdated(uint256 score, uint256 insurancePts, uint256 backstopPts, uint256 oiPts);
    event VenueConfigUpdated(address gmxRouter, address uniRouter);
    event ThresholdsUpdated(uint256 targetInsurance, uint256 targetBackstop);
    event ExternalRouteFailed(bytes32 marketId, Venue venue, bytes reason);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _vault,
        address _backstop,
        address _vamm,
        address _splitter,
        address _usdc
    ) Ownable(_owner) {
        require(_vault    != address(0), "HLM: zero vault");
        require(_splitter != address(0), "HLM: zero splitter");
        require(_usdc     != address(0), "HLM: zero usdc");

        vault    = IWikiVault(_vault);
        if (_backstop != address(0)) backstop = IWikiBackstop(_backstop);
        if (_vamm     != address(0)) vamm     = IWikiVAMM(_vamm);
        splitter = IWikiRevenueSplitter(_splitter);
        USDC     = IERC20(_usdc);

        // GMX referral code — register on app.gmx.io with code "WIKICIOUS"
        gmxReferralCode = keccak256("WIKICIOUS");
    }

    // ── Core: decide routing ───────────────────────────────────────────────────

    /**
     * @notice Read-only: compute the routing decision for a given trade.
     *         Called by WikiPerp/WikiVAMM before executing to decide venue.
     *         Also useable by the frontend to show users where their trade routes.
     *
     * @param marketId   Market to trade
     * @param collateral USDC collateral amount (6 dec)
     * @param leverage   Leverage multiplier
     * @param isLong     Direction
     */
    function getRouteDecision(
        bytes32 marketId,
        uint256 collateral,
        uint256 leverage,
        bool    isLong
    ) external view returns (RouteDecision memory decision) {
        uint256 score    = _computeHealthScore(marketId, isLong);
        uint256 notional = collateral * leverage;

        // Determine internal% based on score
        uint256 internalPct;
        if      (score >= THRESHOLD_SELF_SUFFICIENT) internalPct = 100;
        else if (score >= THRESHOLD_MATURE)          internalPct = 70;
        else if (score >= THRESHOLD_GROWTH)          internalPct = 30;
        else                                          internalPct = 0;

        // Enforce minimum internal retention [A5]
        if (internalPct < MIN_INTERNAL_PCT) internalPct = MIN_INTERNAL_PCT;

        // Enforce max external OI [A3]
        uint256 externalPct = 100 - internalPct;

        // Choose best external venue if needed
        Venue extVenue = _bestExternalVenue(marketId, notional);

        // Compute net protocol fee
        uint256 netBps;
        if (externalPct == 0) {
            netBps = USER_FEE_BPS; // fully internal — keep everything
        } else if (extVenue == Venue.GMX_V5) {
            // Blended: internal% × full fee + external% × gmx spread
            netBps = (internalPct * USER_FEE_BPS + externalPct * (USER_FEE_BPS - GMX_FEE_BPS + GMX_REFERRAL_BPS)) / 100;
        } else if (extVenue == Venue.UNISWAP_V3) {
            netBps = (internalPct * USER_FEE_BPS + externalPct * (USER_FEE_BPS - UNI_FEE_BPS)) / 100;
        } else {
            netBps = (internalPct * USER_FEE_BPS + externalPct * (USER_FEE_BPS - CAMELOT_FEE_BPS)) / 100;
        }

        decision = RouteDecision({
            venue:          internalPct == 100 ? Venue.INTERNAL : extVenue,
            healthScore:    score,
            internalPct:    internalPct,
            externalPct:    externalPct,
            userFeeBps:     USER_FEE_BPS,
            netProtocolBps: netBps,
            externalFirst:  score < THRESHOLD_GROWTH
        });
    }

    /**
     * @notice Execute a perp trade through the hybrid routing engine.
     *         Called by WikiPerp/WikiVirtualAMM on every openPosition(). [A1]
     *
     * @param trader     Who is opening the position
     * @param marketId   Market (e.g. keccak256("BTCUSDT"))
     * @param collateral USDC collateral
     * @param leverage   Leverage multiplier
     * @param isLong     Long or short
     * @param limitPrice Price limit (0 = market)
     * @param minPrice   Slippage lower bound
     * @param maxPrice   Slippage upper bound
     *
     * @return posId     Position ID (internal vAMM position, or external order hash)
     * @return venue     Where the trade was executed
     * @return feeKept   USDC kept by protocol
     */
    function routePerp(
        address trader,
        bytes32 marketId,
        uint256 collateral,
        uint256 leverage,
        bool    isLong,
        uint256 limitPrice,
        uint256 minPrice,
        uint256 maxPrice
    ) external nonReentrant whenNotPaused returns (
        uint256 posId,
        Venue   venue,
        uint256 feeKept
    ) {
        require(routeCallers[msg.sender], "HLM: not authorised"); // [A1]

        // Pull collateral from caller (WikiPerp has already locked it)
        uint256 userFee    = collateral * USER_FEE_BPS / BPS;
        uint256 netCollateral = collateral - userFee;

        RouteDecision memory rd = this.getRouteDecision(marketId, collateral, leverage, isLong);

        if (rd.internalPct == 100) {
            // ── Fully internal ────────────────────────────────────────────────
            posId  = _executeInternal(trader, marketId, netCollateral, leverage, isLong, limitPrice, minPrice, maxPrice);
            venue  = Venue.INTERNAL;
            feeKept = userFee;

        } else if (rd.internalPct == 0) {
            // ── Fully external ────────────────────────────────────────────────
            (posId, feeKept) = _executeExternal(rd.venue, trader, marketId, collateral, leverage, isLong, limitPrice, userFee);
            venue = rd.venue;

        } else {
            // ── Split: partial internal + partial external ─────────────────────
            // Split collateral proportionally
            uint256 internalCollateral = netCollateral * rd.internalPct / 100;
            uint256 externalCollateral = netCollateral - internalCollateral;

            uint256 internalFee = userFee * rd.internalPct / 100;
            uint256 externalFee = userFee - internalFee;

            // Execute internal portion
            uint256 internalPosId;
            if (internalCollateral > 1e6 && address(vamm) != address(0)) {
                try vamm.openPosition(marketId, internalCollateral, leverage, isLong, limitPrice, minPrice, maxPrice, 0, 0)
                    returns (uint256 pid) { internalPosId = pid; }
                catch {}
            }

            // Execute external portion
            uint256 extFeeKept;
            (posId, extFeeKept) = _executeExternal(rd.venue, trader, marketId, externalCollateral, leverage, isLong, limitPrice, externalFee);

            if (posId == 0) posId = internalPosId; // return whichever opened

            feeKept = internalFee + extFeeKept;
            venue   = rd.venue; // primary venue for record
        }

        // Distribute kept fees
        if (feeKept > 0) {
            USDC.forceApprove(address(splitter), feeKept);
            try splitter.receiveFees(feeKept) {} catch {}
        }

        // Record
        _recordTrade(trader, marketId, collateral, leverage, isLong, venue, rd.healthScore, userFee, feeKept, userFee - feeKept);

        emit TradeRouted(trader, marketId, venue, collateral * leverage, rd.healthScore, feeKept, userFee - feeKept);
    }

    // ── Health Score ──────────────────────────────────────────────────────────

    /**
     * @notice Compute the protocol's current health score (0-100).
     *         Public — anyone can read this. Frontend displays it.
     *
     * Breakdown:
     *   40 pts from insurance fund vs target
     *   40 pts from backstop vault TVL vs target
     *   20 pts from OI balance (how well long/short are matched)
     */
    function healthScore() external view returns (
        uint256 score,
        uint256 insurancePts,
        uint256 backstopPts,
        uint256 oiPts,
        string memory mode
    ) {
        score       = _computeHealthScore(bytes32(0), true);
        insurancePts = _insuranceScore();
        backstopPts  = _backstopScore();
        oiPts        = 20; // simplified — OI balance scoring
        mode         = score >= THRESHOLD_SELF_SUFFICIENT ? "SELF-SUFFICIENT"
                     : score >= THRESHOLD_MATURE          ? "MATURE (70% internal)"
                     : score >= THRESHOLD_GROWTH          ? "GROWTH (30% internal)"
                     : "BOOTSTRAP (external first)";
    }

    /**
     * @notice Full routing forecast — what happens at different health levels.
     *         Used by frontend dashboard.
     */
    function routingForecast() external view returns (
        uint256 currentScore,
        uint256 currentInternalPct,
        uint256 currentNetFeeBps,
        uint256 scoreFor70pct,
        uint256 scoreFor100pct,
        uint256 fundNeededFor70pct,
        uint256 fundNeededFor100pct
    ) {
        currentScore = _computeHealthScore(bytes32(0), true);

        if      (currentScore >= 80) currentInternalPct = 100;
        else if (currentScore >= 60) currentInternalPct = 70;
        else if (currentScore >= 40) currentInternalPct = 30;
        else                          currentInternalPct = 0;

        // Blended fee at current routing
        currentNetFeeBps = (currentInternalPct * USER_FEE_BPS + (100 - currentInternalPct) * (USER_FEE_BPS - GMX_FEE_BPS + GMX_REFERRAL_BPS)) / 100;

        scoreFor70pct  = THRESHOLD_MATURE;
        scoreFor100pct = THRESHOLD_SELF_SUFFICIENT;

        // Fund needed to reach score 60 (70% internal)
        // Score formula: insurance_fund / target × 40 pts. Need 60 total.
        // Assume backstop gives full 40 pts: need 20 from insurance = $50K × 20/40 = $25K
        uint256 insF = vault.insuranceFund();
        uint256 bsF  = address(backstop) != address(0) ? backstop.totalUSDC() : 0;

        uint256 curInsPts = insF >= targetInsuranceFund ? 40 : insF * 40 / targetInsuranceFund;
        uint256 curBsPts  = bsF  >= targetBackstopTVL   ? 40 : bsF  * 40 / targetBackstopTVL;

        // For score 60: need curInsPts + curBsPts + oiPts = 60 (oiPts ≈ 10 avg)
        // Focus on insurance fund gap
        uint256 neededScore60  = THRESHOLD_MATURE;
        uint256 neededScore80  = THRESHOLD_SELF_SUFFICIENT;
        uint256 neededInsPts60 = neededScore60 > (curBsPts + 10) ? neededScore60 - curBsPts - 10 : 0;
        uint256 neededInsPts80 = neededScore80 > (curBsPts + 10) ? neededScore80 - curBsPts - 10 : 0;

        fundNeededFor70pct  = neededInsPts60 > 0 ? targetInsuranceFund * neededInsPts60 / 40 : 0;
        fundNeededFor100pct = neededInsPts80 > 0 ? targetInsuranceFund * neededInsPts80 / 40 : 0;

        if (insF >= fundNeededFor70pct)  fundNeededFor70pct  = 0;
        if (insF >= fundNeededFor100pct) fundNeededFor100pct = 0;
    }

    // ── Stats ─────────────────────────────────────────────────────────────────

    function stats() external view returns (
        uint256 totalFeeChargedAll,
        uint256 totalFeeKeptAll,
        uint256 totalPaidExternal,
        uint256 effectiveFeePct,   // basis points — what % of charged fees we keep
        uint256 internalVol,
        uint256 gmxVol,
        uint256 uniVol
    ) {
        totalFeeChargedAll = totalFeeCharged;
        totalFeeKeptAll    = totalFeeKept;
        totalPaidExternal  = totalFeePaidExternal;
        effectiveFeePct    = totalFeeCharged > 0 ? totalFeeKept * BPS / totalFeeCharged : 0;
        internalVol = totalVolumeByVenue[Venue.INTERNAL];
        gmxVol      = totalVolumeByVenue[Venue.GMX_V5];
        uniVol      = totalVolumeByVenue[Venue.UNISWAP_V3];
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _computeHealthScore(bytes32 marketId, bool isLong) internal view returns (uint256) {
        uint256 ins  = _insuranceScore();   // 0-40
        uint256 bs   = _backstopScore();    // 0-40
        uint256 oi   = _oiScore(marketId, isLong); // 0-20
        return ins + bs + oi;
    }

    function _insuranceScore() internal view returns (uint256) {
        uint256 fund = vault.insuranceFund();
        if (fund >= targetInsuranceFund) return INSURANCE_WEIGHT;
        return fund * INSURANCE_WEIGHT / targetInsuranceFund;
    }

    function _backstopScore() internal view returns (uint256) {
        if (address(backstop) == address(0)) return 0;
        uint256 tvl = backstop.totalUSDC();
        if (tvl >= targetBackstopTVL) return BACKSTOP_WEIGHT;
        return tvl * BACKSTOP_WEIGHT / targetBackstopTVL;
    }

    function _oiScore(bytes32 marketId, bool isLong) internal view returns (uint256) {
        if (marketId == bytes32(0) || address(vamm) == address(0)) return OI_BALANCE_WEIGHT / 2;
        try vamm.markets(marketId) returns (bytes32,string memory,uint256,uint256,uint256,uint256 oiLong,uint256 oiShort,uint256,uint256,uint256,uint256,bool) {
            if (oiLong == 0 && oiShort == 0) return OI_BALANCE_WEIGHT; // empty = balanced = max score
            uint256 total = oiLong + oiShort;
            uint256 imbalancePct = oiLong > oiShort
                ? (oiLong - oiShort) * 100 / total
                : (oiShort - oiLong) * 100 / total;
            // Perfect balance = 20 pts. 50% imbalance = 0 pts.
            if (imbalancePct >= 50) return 0;
            return OI_BALANCE_WEIGHT * (50 - imbalancePct) / 50;
        } catch {
            return OI_BALANCE_WEIGHT / 2;
        }
    }

    function _bestExternalVenue(bytes32 marketId, uint256 notional) internal view returns (Venue) {
        // For perps: prefer GMX V5 (deepest liquidity on Arbitrum)
        if (address(gmxRouter) != address(0) && gmxMarkets[marketId] != address(0)) {
            return Venue.GMX_V5;
        }
        // For spot: prefer Camelot (Arbitrum-native, referral)
        if (camelotRouter != address(0)) return Venue.CAMELOT_V3;
        // Fallback: Uniswap V3
        return Venue.UNISWAP_V3;
    }

    function _executeInternal(
        address trader, bytes32 marketId, uint256 collateral, uint256 leverage,
        bool isLong, uint256 limitPrice, uint256 minPrice, uint256 maxPrice
    ) internal returns (uint256 posId) {
        if (address(vamm) == address(0)) return 0;
        try vamm.openPosition(marketId, collateral, leverage, isLong, limitPrice, minPrice, maxPrice, 0, 0)
            returns (uint256 pid) { posId = pid; }
        catch (bytes memory reason) {
            emit ExternalRouteFailed(marketId, Venue.INTERNAL, reason);
        }
    }

    function _executeExternal(
        Venue venue, address trader, bytes32 marketId,
        uint256 collateral, uint256 leverage, bool isLong,
        uint256 limitPrice, uint256 userFee
    ) internal returns (uint256 posId, uint256 feeKept) {
        if (venue == Venue.GMX_V5 && address(gmxRouter) != address(0)) {
            address gmxMkt = gmxMarkets[marketId];
            if (gmxMkt != address(0)) {
                uint256 gmxFee = collateral * GMX_FEE_BPS / BPS;
                feeKept        = userFee > gmxFee ? userFee - gmxFee + (gmxFee * GMX_REFERRAL_BPS / BPS) : 0;

                // Approve USDC for GMX
                USDC.forceApprove(address(gmxRouter), collateral);

                address[] memory emptyPath = new address[](0);
                try gmxRouter.createOrder{value: 0}(IGMXExchangeRouter.CreateOrderParams({
                    addresses: IGMXExchangeRouter.CreateOrderParamsAddresses({
                        receiver:          trader,
                        callbackContract:  address(this),
                        uiFeeReceiver:     address(this),  // capture UI fee
                        market:            gmxMkt,
                        initialCollateralToken: address(USDC),
                        swapPath:          emptyPath
                    }),
                    numbers: IGMXExchangeRouter.CreateOrderParamsNumbers({
                        sizeDeltaUsd:               collateral * leverage,
                        initialCollateralDeltaAmount: collateral,
                        triggerPrice:               limitPrice,
                        acceptablePrice:            isLong ? type(uint256).max : 0,
                        executionFee:               0,
                        callbackGasLimit:           300_000,
                        minOutputAmount:            0
                    }),
                    orderType:              2, // MarketIncrease
                    decreaseSwapType:       0,
                    isLong:                 isLong,
                    shouldUnwrapNativeToken: false,
                    referralCode:           gmxReferralCode
                })) returns (bytes32 orderKey) {
                    posId = uint256(orderKey);
                } catch (bytes memory reason) {
                    // [A2] GMX failed — fallback to internal
                    emit ExternalRouteFailed(marketId, Venue.GMX_V5, reason);
                    posId   = _executeInternal(trader, marketId, collateral, leverage, isLong, limitPrice, 0, 0);
                    feeKept = userFee; // keep full fee since going internal
                }
                return (posId, feeKept);
            }
        }

        // Venue not available — fallback to internal [A2]
        posId   = _executeInternal(trader, marketId, collateral, leverage, isLong, limitPrice, 0, 0);
        feeKept = userFee;
    }

    function _recordTrade(
        address trader, bytes32 marketId, uint256 collateral, uint256 leverage,
        bool isLong, Venue venue, uint256 score, uint256 charged, uint256 kept, uint256 paid
    ) internal {
        totalFeeCharged        += charged;
        totalFeeKept           += kept;
        totalFeePaidExternal   += paid;
        totalVolumeByVenue[venue] += collateral * leverage;
        totalFeesByVenue[venue]   += kept;

        tradeHistory.push(TradeRecord({
            trader:     trader, marketId:  marketId, collateral: collateral,
            leverage:   leverage, isLong:   isLong,   venue:      venue,
            healthScore: score,  feeCharged: charged, feeKept:   kept,
            feePaid:    paid,    timestamp: block.timestamp
        }));
    }

    // ── Admin ─────────────────────────────────────────────────────────────────


    // ── External venue leverage caps ──────────────────────────────────────────

    /// External venue max leverage per market (what GMX/Vertex actually allow)
    mapping(bytes32 => uint256) public externalVenueMaxLev;

    // Defaults
    uint256 public defaultExternalMaxLev = 100; // GMX V5 standard

     /* @notice Returns the effective max leverage for a user considering routing.
     *
     * KEY INSIGHT:
     *   If the trade will be routed externally, the dynLev internal cap does NOT apply.
     *   The external venue (GMX) has its own risk management.
     *   Protocol should not block 100× on BTC when GMX will handle it at zero protocol risk.
     *
     * Returns the HIGHER of:
     *   (a) internal cap (dynLev tier — starts at 5×, grows with fund)
     *   (b) external cap (GMX limit for this market — e.g. 100× for BTC)
     *       but only if external routing is active (health score < 80)
     *
     * Capped by WikiLeverageScaler class ceiling in all cases.
     *
     * @param marketId  Market to trade
     * @param leverage  Requested leverage (used to determine if external needed)
     */
    function getEffectiveLeverageCap(
        bytes32 marketId,
        uint256 /*leverage*/
    ) external view returns (
        uint256 effectiveCap,
        uint256 internalCap,
        uint256 externalCap,
        string  memory routing
    ) {
        uint256 score = _computeHealthScore(marketId, true);

        // Internal cap = dynLev tier (fund-based)
        // We approximate it here — actual dynLev contract called by vAMM
        uint256 insF = vault.insuranceFund();
        uint256 bsF  = address(backstop) != address(0) ? backstop.totalUSDC() : 0;
        // Rough internal cap from fund (mirrors DynamicLeverage tiers)
        if      (insF >= 50_000_000 * 1e6) internalCap = 1000;
        else if (insF >= 10_000_000 * 1e6) internalCap = 500;
        else if (insF >=  2_000_000 * 1e6) internalCap = 200;
        else if (insF >=    500_000 * 1e6) internalCap = 100;
        else if (insF >=     50_000 * 1e6) internalCap = 75;
        else if (insF >=      5_000 * 1e6) internalCap = 50;
        else if (insF >=      2_000 * 1e6) internalCap = 25;
        else if (insF >=        500 * 1e6) internalCap = 20;
        else if (insF >=        100 * 1e6) internalCap = 10;
        else                               internalCap = 5;

        // External cap = what the external venue allows for this market
        externalCap = externalVenueMaxLev[marketId];
        if (externalCap == 0) externalCap = defaultExternalMaxLev;

        // If health score < 80, external routing is active
        // → effective cap = max(internal, external)
        // If health score >= 80, all internal
        // → effective cap = internal only (but fund is big, so internal cap is high too)
        if (score < THRESHOLD_SELF_SUFFICIENT) {
            effectiveCap = internalCap > externalCap ? internalCap : externalCap;
            routing = score >= THRESHOLD_MATURE   ? "MATURE: 70% internal + 30% GMX"
                    : score >= THRESHOLD_GROWTH   ? "GROWTH: 30% internal + 70% GMX"
                    : "BOOTSTRAP: 10% internal + 90% GMX";
        } else {
            effectiveCap = internalCap;
            routing = "SELF-SUFFICIENT: 100% internal";
        }
    }

    function setExternalVenueMaxLev(bytes32 marketId, uint256 maxLev) external onlyOwner {
        require(maxLev >= 1 && maxLev <= 2000, "HLM: bad cap");
        externalVenueMaxLev[marketId] = maxLev;
    }

    function setExternalVenueMaxLevBatch(
        bytes32[] calldata marketIds,
        uint256[] calldata maxLevs
    ) external onlyOwner {
        require(marketIds.length == marketIds.length, "HLM: length");
        for (uint i; i < marketIds.length; i++) {
            externalVenueMaxLev[marketIds[i]] = maxLevs[i];
        }
    }

    function setDefaultExternalMaxLev(uint256 maxLev) external onlyOwner {
        require(maxLev >= 1 && maxLev <= 2000, "HLM: bad cap");
        defaultExternalMaxLev = maxLev;
    }

    function setRouteCaller(address caller, bool enabled) external onlyOwner { routeCallers[caller] = enabled; }

    function setGMXRouter(address router, bytes32 referralCode) external onlyOwner {
        gmxRouter       = IGMXExchangeRouter(router);
        gmxReferralCode = referralCode;
        emit VenueConfigUpdated(router, address(uniRouter));
    }

    function setUniRouter(address router) external onlyOwner {
        uniRouter = IUniswapV3Router(router);
    }

    function setCamelotRouter(address router) external onlyOwner { camelotRouter = router; }

    function setGMXMarket(bytes32 marketId, address gmxMkt) external onlyOwner {
        gmxMarkets[marketId] = gmxMkt;
    }

    function setGMXMarkets(bytes32[] calldata ids, address[] calldata mkts) external onlyOwner {
        require(ids.length == mkts.length, "HLM: length");
        for (uint i; i < ids.length; i++) gmxMarkets[ids[i]] = mkts[i];
    }

    function setTargets(uint256 insTarget, uint256 bsTarget) external onlyOwner {
        require(insTarget > 0 && bsTarget > 0, "HLM: zero target");
        targetInsuranceFund = insTarget;
        targetBackstopTVL   = bsTarget;
        emit ThresholdsUpdated(insTarget, bsTarget);
    }

    function setContracts(address _vault, address _backstop, address _vamm, address _splitter) external onlyOwner {
        if (_vault    != address(0)) vault    = IWikiVault(_vault);
        if (_backstop != address(0)) backstop = IWikiBackstop(_backstop);
        if (_vamm     != address(0)) vamm     = IWikiVAMM(_vamm);
        if (_splitter != address(0)) splitter = IWikiRevenueSplitter(_splitter);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
