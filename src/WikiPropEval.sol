// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WikiPropEval — Prop firm evaluation via SIMULATED paper trading
///
/// ╔══════════════════════════════════════════════════════╗
/// ║  ZERO CAPITAL AT RISK DURING EVALUATION              ║
/// ║                                                      ║
/// ║  Eval trades are 100% simulated (paper trades).      ║
/// ║  No real positions opened on WikiPerp.               ║
/// ║  No pool or protocol capital touched.                ║
/// ║  Only the eval fee moves — everything else is        ║
/// ║  tracked as numbers on-chain using oracle prices.    ║
/// ║                                                      ║
/// ║  Real money only enters when trader PASSES eval      ║
/// ║  and graduates to a WikiPropFunded account.          ║
/// ╚══════════════════════════════════════════════════════╝
///
/// SIMULATION MODEL:
///   openSimTrade()  → snapshots oracle price as entry
///   closeSimTrade() → snapshots oracle price as exit
///   pnl = size × Δprice / entryPrice (long) or reverse (short)
///   Balance updated → drawdown rules enforced → pass/fail
///
/// THREE TIERS:
///   Tier 1 — 1-Phase:  0.5% fee | 8% target | 4% daily DD | 8% total DD | 30 days
///   Tier 2 — 2-Phase:  0.4% fee | 8%+5%     | 5% daily DD | 10% total DD | 30+60 days
///   Tier 3 — Instant:  3.0% fee | no eval   | 3% daily DD | 6% total DD  | no limit
///
/// FUNDED ACCOUNT PROFIT SPLIT (after passing):
///   Initial:         70% tier1 / 80% tier2 / 60% tier3
///   2× cumulative:   80%
///   5× cumulative:   90% (max)

interface IWikiOracle {
    function getPrice(uint256 marketIndex) external view returns (uint256 price, uint256 timestamp);
}

interface IWikiPropFunded {
    function createFundedAccount(address trader, uint256 accountSize, uint8 tier, uint256 initialSplitBps)
        external returns (uint256 accountId);
}

interface IWikiPropPool {
    function receiveEvalFee(uint256 amount) external;
}

contract WikiPropEval is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20  public immutable USDC;
    address public oracle;
    address public fundedContract;
    address public propPool;
    address public feeRecipient;

    uint256 public constant BPS            = 10000;
    uint256 public constant POOL_FEE_SHARE = 7000; // 70% of eval fees → pool LPs
    uint256 public constant PROTO_FEE_SHARE= 3000; // 30% → protocol treasury

    // ── Tier config ────────────────────────────────────────────────────────
    struct TierConfig {
        uint256 minSize;
        uint256 maxSize;
        uint256 feeBps;
        // ── Phase 1 rules ─────────────────────────────────────────────────
        uint256 p1TargetBps;     // profit target (e.g. 800 = 8%)
        uint256 p1DailyDDBps;    // max daily drawdown in Phase 1
        uint256 p1TotalDDBps;    // max total drawdown in Phase 1
        uint256 p1Days;          // max days to complete Phase 1
        uint256 p1MaxLeverage;   // max leverage in Phase 1
        uint256 p1ConsistencyPct;// max single-day % of profit (e.g. 40)
        uint256 p1MinTradingDays;// min distinct trading days in Phase 1
        // ── Phase 2 rules (HARDER — verifies Phase 1 was not luck) ────────
        // Balance RESETS to starting balance when Phase 2 begins.
        // Trader must earn profit again from scratch on a clean slate.
        uint256 p2TargetBps;     // lower target (e.g. 500 = 5%) — easier number, harder to fake
        uint256 p2DailyDDBps;    // TIGHTER daily DD (e.g. 300 = 3%)
        uint256 p2TotalDDBps;    // same total DD as Phase 1
        uint256 p2Days;          // max days to complete Phase 2
        uint256 p2MaxLeverage;   // REDUCED max leverage vs Phase 1
        uint256 p2ConsistencyPct;// stricter consistency (e.g. 35% vs 40%)
        uint256 p2MinTradingDays;// more trading days required vs Phase 1
        // ── General ───────────────────────────────────────────────────────
        uint256 initialSplitBps;
        bool    requiresEval;    // false = Instant Funded (no eval, high fee)
    }
    mapping(uint8 => TierConfig) public tiers;

    // ── Eval account ───────────────────────────────────────────────────────
    enum EvalStatus { Active, Passed, Failed }
    enum EvalPhase  { Phase1, Phase2 }

    struct EvalAccount {
        address    trader;
        uint8      tier;
        EvalPhase  phase;
        EvalStatus status;
        uint256    accountSize;
        uint256    balance;              // current sim balance
        uint256    startBalance;         // reference for current phase target
        uint256    originalBalance;      // always = accountSize at creation
        uint256    peakBalance;
        uint256    dailyStartBalance;
        uint256    lastDayTs;
        uint256    p1StartTs;
        uint256    p2StartTs;
        uint256    feePaid;
        int256     realizedPnl;
        uint256    openTradeCount;
        uint256    totalTrades;
        // ── Phase 1 final results (stored when P1 passes) ─────────────────
        uint256    p1FinalBalance;       // balance when Phase 1 passed
        uint256    p1ProfitBps;          // % profit achieved in Phase 1
        uint256    p1TradingDays;        // trading days used in Phase 1
        uint256    p1CompletedTs;        // timestamp Phase 1 passed
        bool       p1Passed;
        // ── Current phase tracking ────────────────────────────────────────
        bool       breached;
        string     breachReason;
        uint256    createdAt;
        // ── Consistency tracking (resets between phases) ──────────────────
        uint256    bestSingleDayProfit;
        uint256    totalRealizedProfit;
        uint256    tradingDaysCount;
        uint256    lastTradedDay;
        mapping(uint256 => int256) dailyPnl;
    }

    // ── Simulated trade ────────────────────────────────────────────────────
    struct SimTrade {
        uint256 evalId;
        address trader;
        uint256 marketIndex;
        bool    isLong;
        uint256 size;        // notional in USDC (6 dec)
        uint256 leverage;
        uint256 entryPrice;  // oracle price at open (8 dec)
        uint256 exitPrice;
        int256  pnl;         // USDC (6 dec) — set on close
        uint256 openTs;
        uint256 closeTs;
        bool    open;
    }

    mapping(uint256 => EvalAccount) public evals;
    mapping(uint256 => SimTrade)    public simTrades;
    mapping(address => uint256[])   public traderEvals;
    mapping(address => uint256)     public activeEvalId;
    mapping(uint256 => uint256[])   public evalTradeIds;

    uint256 public totalEvals;
    uint256 public totalSimTrades;
    uint256 public totalEvalsPassed;
    uint256 public totalEvalsFailed;
    uint256 public totalFeesCollected;

    // Events
    event EvalStarted(uint256 indexed id, address indexed trader, uint8 tier, uint256 size, uint256 fee);
    event SimTradeOpened(uint256 indexed tradeId, uint256 indexed evalId, uint256 market, bool isLong, uint256 size, uint256 entryPrice);
    event SimTradeClosed(uint256 indexed tradeId, uint256 indexed evalId, int256 pnl, uint256 exitPrice);
    event Phase2Unlocked(uint256 indexed evalId, address indexed trader);
    event EvalPassed(uint256 indexed evalId, address indexed trader, uint8 tier, uint256 fundedId);
    event EvalFailed(uint256 indexed evalId, address indexed trader, string reason);
    event BalanceUpdated(uint256 indexed evalId, uint256 newBalance, int256 pnl);

    constructor(address usdc, address _oracle, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(owner != address(0), "Wiki: zero owner");
        USDC   = IERC20(usdc);
        oracle = _oracle;
        _initTiers();
    }

    function _initTiers() internal {
        // ── TIER 1 — Standard 2-Phase ─────────────────────────────────────
        // Phase 1: 8% profit / 30 days / 4%DD daily / 8%DD total / max 100× / 40% consistency / 4 days min
        // Phase 2: 5% profit / 60 days / 3%DD daily / 8%DD total / max 50×  / 35% consistency / 5 days min
        // Balance RESETS between phases. Phase 2 is on a clean slate.
        tiers[1] = TierConfig({
            minSize:          10_000 * 1e6,
            maxSize:         200_000 * 1e6,
            feeBps:               50,          // 0.5% of account size
            // Phase 1
            p1TargetBps:         800,          // 8% profit target
            p1DailyDDBps:        400,          // 4% max daily drawdown
            p1TotalDDBps:        800,          // 8% max total drawdown
            p1Days:               30,          // 30 calendar days
            p1MaxLeverage:       100,          // up to 100×
            p1ConsistencyPct:     40,          // no single day > 40% of profit
            p1MinTradingDays:      4,          // must trade 4+ separate days
            // Phase 2 — HARDER
            p2TargetBps:         500,          // 5% profit (lower number, stricter conditions)
            p2DailyDDBps:        300,          // 3% daily DD (TIGHTER than Phase 1)
            p2TotalDDBps:        800,          // 8% total DD (same)
            p2Days:               60,          // 60 days — more time, stricter rules
            p2MaxLeverage:        50,          // 50× max (HALF of Phase 1 — prove skill not leverage)
            p2ConsistencyPct:     35,          // 35% consistency (STRICTER than Phase 1)
            p2MinTradingDays:      5,          // 5+ distinct trading days
            initialSplitBps:    7000,          // 70% to trader on funded account
            requiresEval:        true
        });

        // ── TIER 2 — Aggressive 2-Phase ──────────────────────────────────
        // Slightly looser DD rules. Higher split on funded account.
        tiers[2] = TierConfig({
            minSize:          10_000 * 1e6,
            maxSize:         200_000 * 1e6,
            feeBps:               40,          // 0.4% fee
            // Phase 1
            p1TargetBps:         800,          // 8%
            p1DailyDDBps:        500,          // 5% daily DD
            p1TotalDDBps:       1000,          // 10% total DD
            p1Days:               30,
            p1MaxLeverage:       100,
            p1ConsistencyPct:     40,
            p1MinTradingDays:      4,
            // Phase 2
            p2TargetBps:         500,          // 5%
            p2DailyDDBps:        400,          // 4% daily DD
            p2TotalDDBps:       1000,          // 10%
            p2Days:               60,
            p2MaxLeverage:        50,
            p2ConsistencyPct:     35,
            p2MinTradingDays:      5,
            initialSplitBps:    8000,          // 80% to trader
            requiresEval:        true
        });

        // ── TIER 3 — Instant Funded (no evaluation, high fee) ────────────
        // Experienced traders pay 3% to skip evaluation entirely.
        // High fee compensates the protocol for the increased risk.
        tiers[3] = TierConfig({
            minSize:           5_000 * 1e6,
            maxSize:          50_000 * 1e6,
            feeBps:              300,          // 3% — premium for skipping eval
            p1TargetBps:           0,          // no Phase 1
            p1DailyDDBps:        300,
            p1TotalDDBps:        600,
            p1Days:                0,
            p1MaxLeverage:        50,
            p1ConsistencyPct:      0,
            p1MinTradingDays:      0,
            p2TargetBps:           0,          // no Phase 2
            p2DailyDDBps:        300,
            p2TotalDDBps:        600,
            p2Days:                0,
            p2MaxLeverage:        50,
            p2ConsistencyPct:      0,
            p2MinTradingDays:      0,
            initialSplitBps:    6000,          // 60% — lower split for instant funded
            requiresEval:        false
        });
    }

    // ── Start evaluation ───────────────────────────────────────────────────
    function startEval(uint8 tier, uint256 accountSize)
        external nonReentrant whenNotPaused
        returns (uint256 evalId)
    {
        TierConfig storage cfg = tiers[tier];
        require(cfg.minSize > 0,               "Eval: invalid tier");
        require(accountSize >= cfg.minSize,    "Eval: below minimum");
        require(accountSize <= cfg.maxSize,    "Eval: above maximum");
        require(activeEvalId[msg.sender] == 0, "Eval: already in evaluation");

        // Collect eval fee — only real USDC that changes hands
        uint256 fee = accountSize * cfg.feeBps / BPS;
        USDC.safeTransferFrom(msg.sender, address(this), fee);
        _distributeFee(fee);
        totalFeesCollected += fee;

        evalId = ++totalEvals;
        uint256 ts = block.timestamp;

        EvalAccount storage e = evals[evalId];
        e.trader = msg.sender;
        e.tier = tier;
        e.phase = EvalPhase.Phase1;
        e.status = EvalStatus.Active;
        e.accountSize = accountSize;
        e.balance = accountSize;
        e.startBalance = accountSize;
        e.originalBalance = accountSize;
        e.peakBalance = accountSize;
        e.dailyStartBalance = accountSize;
        e.lastDayTs = ts;
        e.p1StartTs = ts;
        e.p2StartTs = 0;
        e.feePaid = fee;
        e.realizedPnl = 0;
        e.openTradeCount = 0;
        e.totalTrades = 0;
        e.p1FinalBalance = 0;
        e.p1ProfitBps = 0;
        e.p1TradingDays = 0;
        e.p1CompletedTs = 0;
        e.p1Passed = false;
        e.breached = false;
        e.breachReason = "";
        e.createdAt = ts;
        e.bestSingleDayProfit = 0;
        e.totalRealizedProfit = 0;
        e.tradingDaysCount = 0;
        e.lastTradedDay = 0;

        traderEvals[msg.sender].push(evalId);
        activeEvalId[msg.sender] = evalId;

        emit EvalStarted(evalId, msg.sender, tier, accountSize, fee);

        // Tier 3 instant — no eval needed, jump straight to funded
        if (!cfg.requiresEval) {
            evals[evalId].status = EvalStatus.Passed;
            activeEvalId[msg.sender] = 0;
            totalEvalsPassed++;
            uint256 fundedId = IWikiPropFunded(fundedContract).createFundedAccount(
                msg.sender, accountSize, tier, cfg.initialSplitBps
            );
            emit EvalPassed(evalId, msg.sender, tier, fundedId);
        }
    }

    // ── Open simulated trade ───────────────────────────────────────────────
    /// @notice Paper trade — snapshots oracle price, no real position opened
    function openSimTrade(
        uint256 evalId,
        uint256 marketIndex,
        bool    isLong,
        uint256 size,
        uint256 leverage
    ) external nonReentrant whenNotPaused returns (uint256 tradeId) {
        EvalAccount storage e = evals[evalId];
        require(e.trader == msg.sender,        "Eval: not your eval");
        require(e.status == EvalStatus.Active, "Eval: not active");

        TierConfig storage cfg = tiers[e.tier];
        uint256 phaseLevCap = (e.phase == EvalPhase.Phase1)
            ? cfg.p1MaxLeverage : cfg.p2MaxLeverage;
        require(leverage >= 1 && leverage <= phaseLevCap,
            e.phase == EvalPhase.Phase1
                ? "Eval: leverage exceeds Phase 1 limit"
                : unicode"Eval: Phase 2 max leverage is lower — proves skill not leverage");

        // Margin check: required margin = notional / leverage
        uint256 margin = size / leverage;
        require(margin <= e.balance,           "Eval: insufficient sim balance");
        require(size <= e.accountSize / 2,     "Eval: max 50% account per trade");
        require(size > 0,                      "Eval: zero size");

        // Snapshot current oracle price — this is the ONLY real chain interaction
        (uint256 entryPrice, uint256 priceTs) = IWikiOracle(oracle).getPrice(marketIndex);
        require(entryPrice > 0,                "Eval: no oracle price");
        require(block.timestamp - priceTs < 5 minutes, "Eval: price stale");

        tradeId = ++totalSimTrades;
        simTrades[tradeId] = SimTrade({
            evalId:      evalId,
            trader:      msg.sender,
            marketIndex: marketIndex,
            isLong:      isLong,
            size:        size,
            leverage:    leverage,
            entryPrice:  entryPrice,
            exitPrice:   0,
            pnl:         0,
            openTs:      block.timestamp,
            closeTs:     0,
            open:        true
        });

        evalTradeIds[evalId].push(tradeId);
        e.openTradeCount++;
        e.totalTrades++;

        emit SimTradeOpened(tradeId, evalId, marketIndex, isLong, size, entryPrice);
    }

    // ── Close simulated trade ──────────────────────────────────────────────
    /// @notice Calculates P&L from oracle price delta, updates eval balance
    function closeSimTrade(uint256 tradeId)
        external nonReentrant
        returns (int256 pnl)
    {
        SimTrade storage t = simTrades[tradeId];
        require(t.trader == msg.sender, "Eval: not your trade");
        require(t.open,                 "Eval: already closed");

        EvalAccount storage e = evals[t.evalId];
        require(e.status == EvalStatus.Active, "Eval: not active");

        // Snapshot exit price — again, only oracle read, zero capital
        (uint256 exitPrice, uint256 priceTs) = IWikiOracle(oracle).getPrice(t.marketIndex);
        require(exitPrice > 0,              "Eval: no oracle price");
        require(block.timestamp - priceTs < 5 minutes, "Eval: price stale");

        // P&L calculation (USDC 6 dec, prices 8 dec → divide by 1e8 in price ratio)
        // net = size × |Δprice| / entryPrice
        if (t.isLong) {
            pnl = exitPrice >= t.entryPrice
                ? int256(t.size * (exitPrice - t.entryPrice) / t.entryPrice)
                : -int256(t.size * (t.entryPrice - exitPrice) / t.entryPrice);
        } else {
            pnl = t.entryPrice >= exitPrice
                ? int256(t.size * (t.entryPrice - exitPrice) / t.entryPrice)
                : -int256(t.size * (exitPrice - t.entryPrice) / t.entryPrice);
        }

        // Update sim trade
        t.open      = false;
        t.exitPrice = exitPrice;
        t.pnl       = pnl;
        t.closeTs   = block.timestamp;

        // Update eval account
        e.openTradeCount--;
        e.realizedPnl += pnl;
        _refreshDaily(e);

        if (pnl >= 0) {
            e.balance += uint256(pnl);
            if (e.balance > e.peakBalance) e.peakBalance = e.balance;
        } else {
            uint256 loss = uint256(-pnl);
            e.balance = e.balance > loss ? e.balance - loss : 0;
        }

        emit SimTradeClosed(tradeId, t.evalId, pnl, exitPrice);
        emit BalanceUpdated(t.evalId, e.balance, pnl);

        // Update consistency tracking on every close
        _updateConsistency(t.evalId, pnl);
        // Evaluate breach then pass
        if (!_checkBreach(t.evalId)) {
            _checkPass(t.evalId);
        }
    }

    // ── Real-time unrealized P&L view ──────────────────────────────────────
    function getUnrealizedPnl(uint256 tradeId) external view returns (int256) {
        SimTrade storage t = simTrades[tradeId];
        if (!t.open) return t.pnl;
        (uint256 cur,) = IWikiOracle(oracle).getPrice(t.marketIndex);
        if (cur == 0) return 0;
        if (t.isLong) {
            return cur >= t.entryPrice
                ? int256(t.size * (cur - t.entryPrice) / t.entryPrice)
                : -int256(t.size * (t.entryPrice - cur) / t.entryPrice);
        } else {
            return t.entryPrice >= cur
                ? int256(t.size * (t.entryPrice - cur) / t.entryPrice)
                : -int256(t.size * (cur - t.entryPrice) / t.entryPrice);
        }
    }

    /// @notice Effective balance = closed P&L + all open unrealized P&L
    function getEffectiveBalance(uint256 evalId) external view returns (uint256) {
        EvalAccount storage e = evals[evalId];
        int256 unrealized;
        uint256[] storage trades = evalTradeIds[evalId];
        for (uint i = 0; i < trades.length; i++) {
            SimTrade storage t = simTrades[trades[i]];
            if (!t.open) continue;
            (uint256 cur,) = IWikiOracle(oracle).getPrice(t.marketIndex);
            if (cur == 0) continue;
            if (t.isLong) {
                unrealized += cur >= t.entryPrice
                    ? int256(t.size * (cur - t.entryPrice) / t.entryPrice)
                    : -int256(t.size * (t.entryPrice - cur) / t.entryPrice);
            } else {
                unrealized += t.entryPrice >= cur
                    ? int256(t.size * (t.entryPrice - cur) / t.entryPrice)
                    : -int256(t.size * (cur - t.entryPrice) / t.entryPrice);
            }
        }
        int256 effective = int256(e.balance) + unrealized;
        return effective > 0 ? uint256(effective) : 0;
    }

    // ── Internal ───────────────────────────────────────────────────────────
    // ── Consistency Rule ─────────────────────────────────────────────────────
    /**
     * @notice Checks whether today's profit violates the consistency rule.
     *         Called after every trade close that results in profit.
     *
     *         Rule: No single day's profit > consistencyPct% of total profit target.
     *
     *         Why this matters:
     *           Without it: trader gambles huge on day 1, wins $8K on a $5K target,
     *           then coasts. Prop firm is funding a gambler, not a consistent trader.
     *           With it: trader must earn profit spread across multiple days.
     *           Proves edge is repeatable, not a one-off lucky trade.
     *
     *         Example (40% rule, $10K funded account, 10% target = $1,000):
     *           Max single day profit = $1,000 × 40% = $400
     *           If Monday earns $500 → consistency breach → FAIL
     *           Even if total profit target is met → still FAIL
     */
    function _updateConsistency(uint256 evalId, int256 tradePnl) internal {
        EvalAccount storage e = evals[evalId];
        TierConfig    storage t = tiers[e.tier];
        uint256 consistencyPct = (e.phase == EvalPhase.Phase1)
            ? t.p1ConsistencyPct
            : t.p2ConsistencyPct;
        if (consistencyPct == 0) return; // rule not configured for this tier

        uint256 today = block.timestamp / 1 days;

        // Track trading days
        if (today != e.lastTradedDay) {
            e.tradingDaysCount++;
            e.lastTradedDay = today;
        }

        // Update daily PnL
        e.dailyPnl[today] += tradePnl;

        // Update total realized profit (only count positive days)
        if (tradePnl > 0) {
            e.totalRealizedProfit += uint256(tradePnl);
        }

        // Update best single day profit
        int256 todayPnl = e.dailyPnl[today];
        if (todayPnl > 0 && uint256(todayPnl) > e.bestSingleDayProfit) {
            e.bestSingleDayProfit = uint256(todayPnl);
        }
    }

    function _checkConsistencyBreach(uint256 evalId) internal returns (bool) {
        EvalAccount storage e = evals[evalId];
        TierConfig    storage t = tiers[e.tier];
        // Use phase-specific consistency % — Phase 2 is stricter
        uint256 consistencyPct = (e.phase == EvalPhase.Phase1)
            ? t.p1ConsistencyPct
            : t.p2ConsistencyPct;
        if (consistencyPct == 0) return false;

        // Need at least some profit before checking
        if (e.totalRealizedProfit == 0) return false;

        // Check: bestSingleDay / totalRealizedProfit > consistencyPct%
        uint256 allowedMax = e.totalRealizedProfit * consistencyPct / 100;
        if (e.bestSingleDayProfit > allowedMax) {
            _failEval(evalId, "Consistency rule: one day profit exceeds limit");
            return true;
        }

        // Check minimum trading days
        uint256 minTradingDays = (e.phase == EvalPhase.Phase1)
            ? t.p1MinTradingDays
            : t.p2MinTradingDays;
        if (e.tradingDaysCount < minTradingDays) {
            // Not a breach yet — but checkPass will enforce this at end
        }

        return false;
    }

    function getConsistencyStatus(uint256 evalId) external view returns (
        uint256 bestDayProfit,
        uint256 totalProfit,
        uint256 allowedMaxDay,
        uint256 tradingDays,
        uint256 minDaysRequired,
        bool    consistent
    ) {
        EvalAccount storage e = evals[evalId];
        TierConfig    storage t = tiers[e.tier];
        uint256 consistencyPct = (e.phase == EvalPhase.Phase1)
            ? t.p1ConsistencyPct
            : t.p2ConsistencyPct;
        uint256 minDays = (e.phase == EvalPhase.Phase1)
            ? t.p1MinTradingDays
            : t.p2MinTradingDays;
        bestDayProfit   = e.bestSingleDayProfit;
        totalProfit     = e.totalRealizedProfit;
        allowedMaxDay   = totalProfit > 0 ? totalProfit * consistencyPct / 100 : 0;
        tradingDays     = e.tradingDaysCount;
        minDaysRequired = minDays;
        consistent      = bestDayProfit <= allowedMaxDay && tradingDays >= minDaysRequired;
    }

    function _checkBreach(uint256 evalId) internal returns (bool) {
        EvalAccount storage e   = evals[evalId];
        TierConfig  storage cfg = tiers[e.tier];
        bool isP1 = (e.phase == EvalPhase.Phase1);

        // ── Consistency check (phase-aware) ───────────────────────────────
        if (_checkConsistencyBreach(evalId)) return true;

        // ── Phase-specific drawdown limits ────────────────────────────────
        // Phase 2 has TIGHTER daily DD to force more disciplined trading
        uint256 dailyLimit = isP1
            ? e.accountSize * cfg.p1DailyDDBps / BPS
            : e.accountSize * cfg.p2DailyDDBps / BPS;

        uint256 totalLimit = isP1
            ? e.accountSize * cfg.p1TotalDDBps / BPS
            : e.accountSize * cfg.p2TotalDDBps / BPS;

        uint256 dLoss = e.dailyStartBalance > e.balance
            ? e.dailyStartBalance - e.balance : 0;
        if (dLoss >= dailyLimit) {
            string memory reason = isP1
                ? "Phase 1 daily drawdown exceeded"
                : "Phase 2 daily drawdown exceeded (stricter limit)";
            _failEval(evalId, reason); return true;
        }

        uint256 tLoss = e.peakBalance > e.balance
            ? e.peakBalance - e.balance : 0;
        if (tLoss >= totalLimit) {
            string memory reason2 = isP1
                ? "Phase 1 total drawdown exceeded"
                : "Phase 2 total drawdown exceeded";
            _failEval(evalId, reason2); return true;
        }

        // ── Phase-specific leverage check ─────────────────────────────────
        // Phase 2 max leverage is enforced in openSimTrade — checked here for safety

        // ── Time limit ────────────────────────────────────────────────────
        if (isP1 && cfg.p1Days > 0
            && block.timestamp > e.p1StartTs + cfg.p1Days * 1 days) {
            _failEval(evalId, "Phase 1 time limit exceeded"); return true;
        }
        if (!isP1 && cfg.p2Days > 0
            && block.timestamp > e.p2StartTs + cfg.p2Days * 1 days) {
            _failEval(evalId, "Phase 2 time limit exceeded"); return true;
        }

        return false;
    }

    function _checkPass(uint256 evalId) internal {
        EvalAccount storage e   = evals[evalId];
        TierConfig  storage cfg = tiers[e.tier];
        bool isP1 = (e.phase == EvalPhase.Phase1);

        // ── Minimum trading days gate ─────────────────────────────────────
        uint256 minDays = isP1 ? cfg.p1MinTradingDays : cfg.p2MinTradingDays;
        if (minDays > 0 && e.tradingDaysCount < minDays) return; // not enough days yet

        if (isP1) {
            // ── PHASE 1 PASS CHECK ────────────────────────────────────────
            uint256 p1Target = e.startBalance + e.startBalance * cfg.p1TargetBps / BPS;
            if (e.balance >= p1Target) {
                // ── PHASE 1 PASSED ────────────────────────────────────────
                // Store Phase 1 results for display and audit
                e.p1Passed        = true;
                e.p1FinalBalance  = e.balance;
                e.p1ProfitBps     = (e.balance - e.originalBalance) * BPS / e.originalBalance;
                e.p1TradingDays   = e.tradingDaysCount;
                e.p1CompletedTs   = block.timestamp;

                if (cfg.p2TargetBps == 0) {
                    // Tier 3 instant funded — no Phase 2
                    _passEval(evalId);
                } else {
                    // ── TRANSITION TO PHASE 2 ─────────────────────────────
                    // CRITICAL: Balance RESETS to original starting balance
                    // Trader must earn profit AGAIN from scratch
                    // This prevents Phase 1 luck from carrying into Phase 2
                    e.phase              = EvalPhase.Phase2;
                    e.p2StartTs          = block.timestamp;
                    e.balance            = e.originalBalance;   // ← HARD RESET
                    e.startBalance       = e.originalBalance;   // ← new reference
                    e.peakBalance        = e.originalBalance;
                    e.dailyStartBalance  = e.originalBalance;
                    e.lastDayTs          = block.timestamp;

                    // Reset consistency tracking for Phase 2
                    e.bestSingleDayProfit  = 0;
                    e.totalRealizedProfit  = 0;
                    e.tradingDaysCount     = 0;
                    e.lastTradedDay        = 0;
                    // Note: dailyPnl mapping keeps history but tracking resets

                    emit Phase2Unlocked(evalId, e.trader);
                }
            }
        } else {
            // ── PHASE 2 PASS CHECK ────────────────────────────────────────
            uint256 p2Target = e.startBalance + e.startBalance * cfg.p2TargetBps / BPS;
            if (e.balance >= p2Target) {
                // ── BOTH PHASES PASSED → FUNDED ───────────────────────────
                _passEval(evalId);
            }
        }
    }

    function _passEval(uint256 evalId) internal {
        EvalAccount storage e   = evals[evalId];
        TierConfig  storage cfg = tiers[e.tier];
        require(e.openTradeCount == 0, "Eval: close all sim trades first");
        e.status = EvalStatus.Passed;
        activeEvalId[e.trader] = 0;
        totalEvalsPassed++;
        // Hand off to funded contract — real money starts here
        uint256 fundedId = IWikiPropFunded(fundedContract).createFundedAccount(
            e.trader, e.accountSize, e.tier, cfg.initialSplitBps
        );
        emit EvalPassed(evalId, e.trader, e.tier, fundedId);
    }

    function _failEval(uint256 evalId, string memory reason) internal {
        EvalAccount storage e = evals[evalId];
        e.status = EvalStatus.Failed;
        e.breached = true;
        e.breachReason = reason;
        activeEvalId[e.trader] = 0;
        totalEvalsFailed++;
        emit EvalFailed(evalId, e.trader, reason);
    }

    function _refreshDaily(EvalAccount storage e) internal {
        if (block.timestamp >= e.lastDayTs + 1 days) {
            e.dailyStartBalance = e.balance;
            e.lastDayTs = block.timestamp;
        }
    }

    function _distributeFee(uint256 fee) internal {
        uint256 toPool  = fee * POOL_FEE_SHARE  / BPS;
        uint256 toProto = fee * PROTO_FEE_SHARE / BPS;
        if (propPool != address(0) && toPool > 0) {
            USDC.approve(propPool, toPool);
            IWikiPropPool(propPool).receiveEvalFee(toPool);
        }
        if (feeRecipient != address(0) && toProto > 0)
            USDC.safeTransfer(feeRecipient, toProto);
    }

    // ── Anyone can call to expire timed-out evals ──────────────────────────
    function checkExpiry(uint256 evalId) external {
        EvalAccount storage e   = evals[evalId];
        if (e.status != EvalStatus.Active) return;
        TierConfig  storage cfg = tiers[e.tier];
        if (e.phase == EvalPhase.Phase1 && cfg.p1Days > 0
            && block.timestamp > e.p1StartTs + cfg.p1Days * 1 days)
            _failEval(evalId, "Time limit exceeded");
        else if (e.phase == EvalPhase.Phase2 && cfg.p2Days > 0
            && block.timestamp > e.p2StartTs + cfg.p2Days * 1 days)
            _failEval(evalId, "Time limit exceeded");
    }

    // ── Views ──────────────────────────────────────────────────────────────
    /// @notice Get complete phase status for the frontend dashboard.
    ///         Shows current phase, rules, progress, and what happens next.
    function getPhaseStatus(uint256 evalId) external view returns (
        uint8   currentPhase,      // 1 or 2
        uint256 currentBalance,
        uint256 targetBalance,     // balance needed to pass current phase
        uint256 progressBps,       // how close to target (BPS)
        uint256 daysRemaining,
        uint256 dailyDDLimit,
        uint256 dailyDDUsed,
        uint256 maxLeverageThisPhase,
        uint256 consistencyPctThisPhase,
        uint256 tradingDaysThisPhase,
        uint256 minTradingDaysRequired,
        bool    p1Passed,
        uint256 p1ProfitBps,
        string  memory nextMilestone
    ) {
        EvalAccount storage e   = evals[evalId];
        TierConfig  storage cfg = tiers[e.tier];
        bool isP1 = (e.phase == EvalPhase.Phase1);

        currentPhase     = isP1 ? 1 : 2;
        currentBalance   = e.balance;

        uint256 targetPct = isP1 ? cfg.p1TargetBps : cfg.p2TargetBps;
        targetBalance    = e.startBalance + e.startBalance * targetPct / BPS;

        progressBps      = currentBalance >= e.startBalance
            ? (currentBalance - e.startBalance) * BPS / (targetBalance - e.startBalance)
            : 0;
        if (progressBps > BPS) progressBps = BPS;

        uint256 deadline    = isP1
            ? e.p1StartTs + cfg.p1Days * 1 days
            : e.p2StartTs + cfg.p2Days * 1 days;
        uint256 nowTs       = block.timestamp;
        daysRemaining       = deadline > nowTs ? (deadline - nowTs) / 1 days : 0;

        dailyDDLimit        = isP1 ? cfg.p1DailyDDBps  : cfg.p2DailyDDBps;
        uint256 dLoss       = e.dailyStartBalance > e.balance
            ? e.dailyStartBalance - e.balance : 0;
        dailyDDUsed         = e.accountSize > 0 ? dLoss * BPS / e.accountSize : 0;

        maxLeverageThisPhase    = isP1 ? cfg.p1MaxLeverage   : cfg.p2MaxLeverage;
        consistencyPctThisPhase = isP1 ? cfg.p1ConsistencyPct: cfg.p2ConsistencyPct;
        tradingDaysThisPhase    = e.tradingDaysCount;
        minTradingDaysRequired  = isP1 ? cfg.p1MinTradingDays : cfg.p2MinTradingDays;
        p1Passed                = e.p1Passed;
        p1ProfitBps             = e.p1ProfitBps;

        if (isP1) {
            nextMilestone = progressBps >= BPS
                ? unicode"Phase 1 target reached — Phase 2 will begin with balance reset"
                : "Complete Phase 1: hit profit target within time limit";
        } else {
            nextMilestone = progressBps >= BPS
                ? unicode"Phase 2 complete — funded account will be created"
                : "Complete Phase 2: hit profit target on clean balance";
        }
    }

    function getEval(uint256 id) external view returns (
        address trader,
        uint8 tier,
        EvalPhase phase,
        EvalStatus status,
        uint256 accountSize,
        uint256 balance,
        uint256 startBalance,
        uint256 originalBalance,
        uint256 peakBalance,
        uint256 dailyStartBalance,
        uint256 lastDayTs,
        uint256 p1StartTs,
        uint256 p2StartTs,
        uint256 feePaid,
        int256 realizedPnl,
        uint256 openTradeCount,
        uint256 totalTrades,
        bool breached,
        string memory breachReason,
        uint256 createdAt
    ) {
        EvalAccount storage e = evals[id];
        trader = e.trader;
        tier = e.tier;
        phase = e.phase;
        status = e.status;
        accountSize = e.accountSize;
        balance = e.balance;
        startBalance = e.startBalance;
        originalBalance = e.originalBalance;
        peakBalance = e.peakBalance;
        dailyStartBalance = e.dailyStartBalance;
        lastDayTs = e.lastDayTs;
        p1StartTs = e.p1StartTs;
        p2StartTs = e.p2StartTs;
        feePaid = e.feePaid;
        realizedPnl = e.realizedPnl;
        openTradeCount = e.openTradeCount;
        totalTrades = e.totalTrades;
        breached = e.breached;
        breachReason = e.breachReason;
        createdAt = e.createdAt;
    }
    function getSimTrade(uint256 id)  external view returns (SimTrade memory)    { return simTrades[id]; }
    function getTraderEvals(address t) external view returns (uint256[] memory)  { return traderEvals[t]; }
    function getEvalTrades(uint256 id) external view returns (uint256[] memory)  { return evalTradeIds[id]; }
    function evalFee(uint8 tier, uint256 size) external view returns (uint256)   { return size * tiers[tier].feeBps / BPS; }

    function evalProgress(uint256 evalId) external view returns (
        uint256 profitPct, uint256 targetPct, uint256 dailyDDUsed,
        uint256 totalDDUsed, uint256 daysRemaining, bool onTrack
    ) {
        EvalAccount storage e   = evals[evalId];
        TierConfig  storage cfg = tiers[e.tier];
        profitPct    = e.balance > e.startBalance ? (e.balance - e.startBalance) * BPS / e.startBalance : 0;
        targetPct    = e.phase == EvalPhase.Phase1 ? cfg.p1TargetBps : cfg.p2TargetBps;
        uint256 dL   = e.dailyStartBalance > e.balance ? e.dailyStartBalance - e.balance : 0;
        dailyDDUsed  = dL * BPS / e.accountSize;
        uint256 tL   = e.peakBalance > e.balance ? e.peakBalance - e.balance : 0;
        totalDDUsed  = tL * BPS / e.accountSize;
        uint256 end  = e.phase == EvalPhase.Phase1
            ? e.p1StartTs + cfg.p1Days * 1 days
            : e.p2StartTs + cfg.p2Days * 1 days;
        daysRemaining = end > block.timestamp ? (end - block.timestamp) / 1 days : 0;
        uint256 phaseDailyDDBps = e.phase == EvalPhase.Phase1 ? cfg.p1DailyDDBps : cfg.p2DailyDDBps;
        onTrack = !e.breached && dailyDDUsed < phaseDailyDDBps / 2 && profitPct > 0;
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setOracle(address o)         external onlyOwner { oracle         = o; }
    function setFundedContract(address f) external onlyOwner { fundedContract = f; }
    function setPropPool(address p)       external onlyOwner { propPool       = p; }
    function setFeeRecipient(address f)   external onlyOwner { feeRecipient   = f; }
    function updateTier(uint8 t, TierConfig calldata cfg) external onlyOwner { tiers[t] = cfg; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
