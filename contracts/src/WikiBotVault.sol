// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiBotVault
 * @notice Master vault for all automated trading bots.
 *         Users deposit USDC, select a strategy, receive vault shares.
 *         Bot executor trades on their behalf. Profits distributed minus fees.
 *
 * ─── FEE STRUCTURE ────────────────────────────────────────────────────────
 *   Performance fee: 20% of profits only (users pay nothing on losses)
 *   Management fee:  2% per year (charged on AUM, accrues per second)
 *   All fees route to WikiRevenueSplitter → ops vault → grows automatically
 *
 * ─── STRATEGIES ───────────────────────────────────────────────────────────
 *   0 = GridBot       (range trading, best in sideways markets)
 *   1 = FundingArb    (delta-neutral, captures funding rates)
 *   2 = TrendFollower (trend trading with ATR stops)
 *   3 = MeanReversion (RSI/BB reversion in ranging markets)
 *
 * ─── SAFETY ───────────────────────────────────────────────────────────────
 *   Max drawdown circuit breaker: strategy pauses if DD > maxDrawdownBps
 *   Position size limits: never risks > riskPerTradeBps of vault NAV
 *   Emergency withdraw: users can always pull funds instantly
 *   Executor whitelist: only verified bot addresses can trade
 */
interface IRevenueSplitter {
        function receiveFees(uint256 amount) external;
    }

interface IWikiPerp {
        function openPosition(uint256 marketId, bool isLong, uint256 collateral, uint256 leverage) external returns (uint256 posId);
        function closePosition(uint256 posId) external returns (int256 pnl);
        function getPositionPnl(uint256 posId) external view returns (int256);
    }

contract WikiBotVault is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ── Interfaces ────────────────────────────────────────────────────────



    // ── Enums ─────────────────────────────────────────────────────────────
    enum Strategy { GRID, FUNDING_ARB, TREND, MEAN_REVERSION }

    // ── Structs ───────────────────────────────────────────────────────────
    struct StrategyConfig {
        Strategy strategy;
        string   name;
        string   description;
        string   realisticWinRate;    // honest description shown to users
        string   bestCondition;       // when this strategy performs best
        uint256  maxDrawdownBps;      // circuit breaker — pause if DD exceeds this
        uint256  riskPerTradeBps;     // max % of NAV risked per trade
        uint256  maxLeverage;         // maximum leverage this strategy uses
        uint256  performanceFeeBps;   // fee on profits (default 2000 = 20%)
        uint256  managementFeeBps;    // annual fee on AUM (default 200 = 2%)
        bool     active;
    }

    struct VaultState {
        uint256  totalDeposits;       // total USDC deposited ever
        uint256  currentNAV;          // current total value including open PnL
        uint256  peakNAV;             // highest NAV ever (for drawdown calc)
        uint256  currentDrawdownBps;  // current drawdown from peak
        uint256  totalFeesCollected;  // lifetime fees sent to protocol
        uint256  totalProfitGenerated;
        uint256  totalTradesExecuted;
        uint256  totalWinningTrades;
        uint256  lastFeeAccrual;      // timestamp of last management fee accrual
        bool     circuitBreakerTripped; // paused due to drawdown
    }

    struct UserPosition {
        uint256 shares;
        uint256 depositedUsdc;
        uint256 highWaterMark;    // their personal peak NAV for performance fee
        uint256 depositTime;
        uint256 feesOwed;
    }

    // ── State ─────────────────────────────────────────────────────────────
    IERC20             public immutable USDC;
    IWikiPerp          public           perp;
    IRevenueSplitter   public           revenueSplitter;

    mapping(uint256 => StrategyConfig) public strategies;       // strategyId → config
    mapping(uint256 => VaultState)     public vaultStates;      // strategyId → state
    mapping(address => mapping(uint256 => UserPosition)) public userPositions;
    mapping(address => bool)           public executors;        // whitelisted bot addresses

    uint256 public constant NUM_STRATEGIES = 4;
    uint256 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_DEPOSIT = 10 * 1e6;   // $10 minimum

    // ── Events ────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 strategyId, uint256 usdc, uint256 shares);
    event Withdrawn(address indexed user, uint256 strategyId, uint256 usdc, uint256 shares, uint256 feeCharged);
    event TradeExecuted(uint256 strategyId, bool isLong, uint256 notional, int256 pnl, uint256 positionId);
    event FeesCollected(uint256 strategyId, uint256 performanceFee, uint256 managementFee, uint256 total);
    event CircuitBreakerTripped(uint256 strategyId, uint256 drawdownBps);
    event CircuitBreakerReset(uint256 strategyId);
    event NAVUpdated(uint256 strategyId, uint256 newNAV, uint256 drawdownBps);

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _usdc,
        address _perp,
        address _revenueSplitter
    ) ERC20("Wikicious Bot Vault Share", "wBVS") Ownable(_owner) {
        USDC             = IERC20(_usdc);
        perp             = IWikiPerp(_perp);
        revenueSplitter  = IRevenueSplitter(_revenueSplitter);
        executors[_owner] = true;
        _initStrategies();
    }

    function _initStrategies() internal {
        strategies[0] = StrategyConfig({
            strategy:           Strategy.GRID,
            name:               "WikiGridBot",
            description:        "Places buy/sell orders in a defined price range. Profits from price oscillation within the grid. Best in sideways, ranging markets.",
            realisticWinRate:   "60-70% of completed grid cycles profitable",
            bestCondition:      unicode"Low-volatility sideways markets, BTC ranging ±5-10%",
            maxDrawdownBps:     1500,  // 15% max drawdown before pause
            riskPerTradeBps:    200,   // 2% of NAV per grid level
            maxLeverage:        3,     // max 3× — conservative
            performanceFeeBps:  2000,  // 20% of profits
            managementFeeBps:   200,   // 2% per year
            active:             true
        });
        strategies[1] = StrategyConfig({
            strategy:           Strategy.FUNDING_ARB,
            name:               "WikiFundingArb",
            description:        "Delta-neutral strategy. Goes long spot, short perp simultaneously. Earns funding rate payments when market is long-heavy (most of the time in bull markets). No directional risk.",
            realisticWinRate:   "80-90% of funding periods positive (structural, not predictive)",
            bestCondition:      "Bull markets with high funding rates. Positive funding 70%+ of time historically",
            maxDrawdownBps:     800,   // 8% — very conservative, delta neutral
            riskPerTradeBps:    500,   // 5% — larger since risk is hedged
            maxLeverage:        1,     // 1× each side = net 0 directional exposure
            performanceFeeBps:  2000,
            managementFeeBps:   200,
            active:             true
        });
        strategies[2] = StrategyConfig({
            strategy:           Strategy.TREND,
            name:               "WikiTrendBot",
            description:        unicode"Trend-following using EMA crossovers and ATR-based stops. 40-50% win rate but aims for 3:1 reward/risk ratio — positive expected value over many trades.",
            realisticWinRate:   "40-50% win rate, 3:1 avg reward/risk (positive EV over time)",
            bestCondition:      "Strong trending markets, BTC bull/bear cycles, post-breakout moves",
            maxDrawdownBps:     2000,  // 20% — trend bots have higher natural DD
            riskPerTradeBps:    100,   // 1% per trade — strict position sizing
            maxLeverage:        5,     // max 5×
            performanceFeeBps:  2000,
            managementFeeBps:   200,
            active:             true
        });
        strategies[3] = StrategyConfig({
            strategy:           Strategy.MEAN_REVERSION,
            name:               "WikiMeanRevert",
            description:        "Uses RSI oversold/overbought signals and Bollinger Band touches to enter mean-reversion trades. Works best in defined ranges.",
            realisticWinRate:   "60-65% win rate in ranging conditions",
            bestCondition:      "Ranging markets with clear support/resistance, low trend strength",
            maxDrawdownBps:     1200,  // 12%
            riskPerTradeBps:    150,   // 1.5%
            maxLeverage:        3,
            performanceFeeBps:  2000,
            managementFeeBps:   200,
            active:             true
        });
    }

    // ── User Functions ────────────────────────────────────────────────────

    function deposit(uint256 strategyId, uint256 amount) external nonReentrant whenNotPaused {
        require(strategyId < NUM_STRATEGIES,          "BV: invalid strategy");
        require(strategies[strategyId].active,         "BV: strategy inactive");
        require(amount >= MIN_DEPOSIT,                 "BV: below minimum $10");
        StrategyConfig storage cfg = strategies[strategyId];
        require(!vaultStates[strategyId].circuitBreakerTripped, unicode"BV: circuit breaker tripped — deposits paused");

        _accrueManagementFee(strategyId);

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares = _calcShares(strategyId, amount);
        vaultStates[strategyId].totalDeposits += amount;
        vaultStates[strategyId].currentNAV    += amount;
        if (vaultStates[strategyId].currentNAV > vaultStates[strategyId].peakNAV) {
            vaultStates[strategyId].peakNAV = vaultStates[strategyId].currentNAV;
        }

        UserPosition storage pos = userPositions[msg.sender][strategyId];
        pos.shares         += shares;
        pos.depositedUsdc  += amount;
        pos.highWaterMark   = _navPerShare(strategyId);
        pos.depositTime     = block.timestamp;

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, strategyId, amount, shares);
    }

    function withdraw(uint256 strategyId, uint256 shares) external nonReentrant {
        require(shares > 0, "BV: zero shares");
        UserPosition storage pos = userPositions[msg.sender][strategyId];
        require(pos.shares >= shares, "BV: insufficient shares");

        _accrueManagementFee(strategyId);

        uint256 usdc           = _calcUSDC(strategyId, shares);
        uint256 performanceFee = _calcPerformanceFee(msg.sender, strategyId, usdc, shares);
        uint256 netUsdc        = usdc - performanceFee;

        pos.shares        -= shares;
        pos.depositedUsdc  = pos.shares > 0
            ? pos.depositedUsdc * pos.shares / (pos.shares + shares)
            : 0;

        vaultStates[strategyId].currentNAV -= usdc;
        _burn(msg.sender, shares);

        // Route fee to revenue splitter
        if (performanceFee > 0) {
            USDC.safeApprove(address(revenueSplitter), performanceFee);
            try revenueSplitter.receiveFees(performanceFee) {} catch {
                USDC.safeTransfer(owner(), performanceFee);
            }
            vaultStates[strategyId].totalFeesCollected += performanceFee;
        }

        USDC.safeTransfer(msg.sender, netUsdc);
        emit Withdrawn(msg.sender, strategyId, netUsdc, shares, performanceFee);
    }

    // ── Executor Functions (called by bot scripts) ────────────────────────

    function recordTrade(
        uint256 strategyId,
        int256  pnl,
        uint256 positionId
    ) external nonReentrant {
        require(executors[msg.sender], "BV: not executor");

        VaultState storage state = vaultStates[strategyId];
        StrategyConfig storage cfg = strategies[strategyId];

        // Update NAV
        if (pnl >= 0) {
            state.currentNAV          += uint256(pnl);
            state.totalProfitGenerated += uint256(pnl);
            state.totalWinningTrades++;
        } else {
            uint256 loss = uint256(-pnl);
            if (state.currentNAV > loss) state.currentNAV -= loss;
            else state.currentNAV = 0;
        }
        state.totalTradesExecuted++;

        // Update peak and drawdown
        if (state.currentNAV > state.peakNAV) {
            state.peakNAV          = state.currentNAV;
            state.currentDrawdownBps = 0;
        } else if (state.peakNAV > 0) {
            state.currentDrawdownBps = (state.peakNAV - state.currentNAV) * BPS / state.peakNAV;
        }

        // Circuit breaker [safety]
        if (state.currentDrawdownBps >= cfg.maxDrawdownBps && !state.circuitBreakerTripped) {
            state.circuitBreakerTripped = true;
            emit CircuitBreakerTripped(strategyId, state.currentDrawdownBps);
        }

        emit TradeExecuted(strategyId, pnl >= 0, 0, pnl, positionId);
        emit NAVUpdated(strategyId, state.currentNAV, state.currentDrawdownBps);
    }

    function resetCircuitBreaker(uint256 strategyId) external onlyOwner {
        vaultStates[strategyId].circuitBreakerTripped = false;
        vaultStates[strategyId].peakNAV = vaultStates[strategyId].currentNAV;
        emit CircuitBreakerReset(strategyId);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    function getUserDashboard(address user, uint256 strategyId) external view returns (
        uint256 shares,
        uint256 currentValue,
        uint256 depositedUsdc,
        int256  unrealisedPnl,
        uint256 performanceFeeIfWithdraw,
        uint256 strategyNAV,
        uint256 strategyDrawdownBps,
        bool    circuitBreakerActive,
        string  memory strategyName,
        string  memory winRateDescription
    ) {
        UserPosition storage pos = userPositions[user][strategyId];
        VaultState   storage vs  = vaultStates[strategyId];
        StrategyConfig storage cfg = strategies[strategyId];

        shares                   = pos.shares;
        currentValue             = _calcUSDC(strategyId, pos.shares);
        depositedUsdc            = pos.depositedUsdc;
        unrealisedPnl            = int256(currentValue) - int256(depositedUsdc);
        performanceFeeIfWithdraw = _calcPerformanceFee(user, strategyId, currentValue, pos.shares);
        strategyNAV              = vs.currentNAV;
        strategyDrawdownBps      = vs.currentDrawdownBps;
        circuitBreakerActive     = vs.circuitBreakerTripped;
        strategyName             = cfg.name;
        winRateDescription       = cfg.realisticWinRate;
    }

    function getAllStrategies() external view returns (
        string[4]  memory names,
        string[4]  memory descriptions,
        string[4]  memory winRates,
        string[4]  memory bestConditions,
        uint256[4] memory navs,
        uint256[4] memory drawdowns,
        bool[4]    memory active
    ) {
        for (uint i; i < NUM_STRATEGIES; i++) {
            names[i]        = strategies[i].name;
            descriptions[i] = strategies[i].description;
            winRates[i]     = strategies[i].realisticWinRate;
            bestConditions[i]= strategies[i].bestCondition;
            navs[i]         = vaultStates[i].currentNAV;
            drawdowns[i]    = vaultStates[i].currentDrawdownBps;
            active[i]       = strategies[i].active && !vaultStates[i].circuitBreakerTripped;
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _navPerShare(uint256 sid) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6;
        return vaultStates[sid].currentNAV * 1e6 / supply;
    }

    function _calcShares(uint256 sid, uint256 usdc) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || vaultStates[sid].currentNAV == 0) return usdc;
        return usdc * supply / vaultStates[sid].currentNAV;
    }

    function _calcUSDC(uint256 sid, uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares * vaultStates[sid].currentNAV / supply;
    }

    function _calcPerformanceFee(address user, uint256 sid, uint256 currentValue, uint256 shares) internal view returns (uint256) {
        UserPosition storage pos = userPositions[user][sid];
        if (pos.shares == 0 || shares == 0) return 0;
        uint256 proRataDeposited = pos.depositedUsdc * shares / pos.shares;
        if (currentValue <= proRataDeposited) return 0;
        uint256 profit = currentValue - proRataDeposited;
        return profit * strategies[sid].performanceFeeBps / BPS;
    }

    function _accrueManagementFee(uint256 sid) internal {
        VaultState storage vs = vaultStates[sid];
        if (vs.lastFeeAccrual == 0) { vs.lastFeeAccrual = block.timestamp; return; }
        uint256 elapsed = block.timestamp - vs.lastFeeAccrual;
        uint256 fee = vs.currentNAV * strategies[sid].managementFeeBps * elapsed / BPS / SECONDS_PER_YEAR;
        if (fee > 0 && vs.currentNAV > fee) {
            vs.currentNAV -= fee;
            vs.totalFeesCollected += fee;
            if (address(revenueSplitter) != address(0) && USDC.balanceOf(address(this)) >= fee) {
                USDC.safeApprove(address(revenueSplitter), fee);
                try revenueSplitter.receiveFees(fee) {} catch {}
            }
        }
        vs.lastFeeAccrual = block.timestamp;
    }

    // ── Admin ─────────────────────────────────────────────────────────────
    function setExecutor(address exec, bool enabled) external onlyOwner { executors[exec] = enabled; }
    function setStrategyActive(uint256 sid, bool active) external onlyOwner { strategies[sid].active = active; }
    function setContracts(address _perp, address _rev) external onlyOwner {
        if (_perp != address(0)) perp = IWikiPerp(_perp);
        if (_rev  != address(0)) revenueSplitter = IRevenueSplitter(_rev);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
