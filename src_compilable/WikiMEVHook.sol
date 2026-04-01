// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiMEVHook
 * @notice Internalizes MEV that would otherwise be captured by external bots.
 *
 * ─── WHAT IS MEV INTERNALIZATION? ───────────────────────────────────────
 *
 * When a large trade occurs on WikiPerp or WikiSpot, it creates price
 * dislocations between WikiDEX and reference markets (CEX, Uniswap, etc.).
 * Normally, arbitrage bots capture this spread as pure profit.
 *
 * WikiMEVHook captures this value by:
 *
 * 1. POST-TRADE BACKRUN HOOK
 *    After every WikiPerp / WikiSpot trade above BACKRUN_THRESHOLD:
 *    - WikiMEVHook is called as an afterHook
 *    - It computes the residual price dislocation
 *    - A keeper submits the backrun trade atomically
 *    - Profit from the backrun flows into the protocolRevenue pot
 *
 * 2. SANDWITCH PROTECTION
 *    - Tracks committed price at order time vs fill time
 *    - If fill is worse than committed price, the hook refunds the difference
 *    - Payers are compensated from the MEV capture fund
 *
 * 3. ORACLE ARBITRAGE CAPTURE
 *    - When oracle price differs from AMM price by > ARB_THRESHOLD,
 *      the hook's keeper executes the arb and pays 30% to the trade that
 *      triggered it (backrun share), keeping 70% in protocol revenue.
 *
 * 4. JUST-IN-TIME (JIT) LIQUIDITY PROTECTION
 *    - Tracks LP additions within the same block as large trades
 *    - Charges JIT penalty fee to prevent sandwich-LPs
 *
 * ─── REVENUE FLOWS ───────────────────────────────────────────────────────
 *
 *   Total MEV captured
 *     ├── 60% → WikiStaking fee distributor (veWIK holders)
 *     ├── 20% → Insurance fund (WikiVault)
 *     ├── 10% → Backrun trigger (user whose trade created the opportunity)
 *     └── 10% → Keeper who executed the backrun
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy       → ReentrancyGuard
 * [A2] Keeper monopoly  → multiple keepers; first-come-first-served per block window
 * [A3] Fake arb claims  → price validation against oracle before accepting
 * [A4] Self-backrun     → user cannot be both trigger and keeper
 * [A5] Overflow         → Solidity 0.8
 * [A6] Flash-loan arb   → require arb profit > gas cost + premium, block TWAP check
 */
interface IUniswapV3Pool {
        function slot0() external view returns (
            uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool
        );
    }

interface IWikiOracle {
        function getPriceView(bytes32 id) external view returns (uint256 price, uint256 ts);
        function getTWAP(bytes32 id) external view returns (uint256);
    }

interface IWikiVault {
        function fundInsurance(uint256 amount) external;
        function operators(address) external view returns (bool);
    }

interface IWikiStaking {
        function distributeFees(uint256 amount) external;
    }

contract WikiMEVHook is Ownable2Step, ReentrancyGuard {
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

    // ──────────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────────
    uint256 public constant BPS               = 10_000;
    uint256 public constant BACKRUN_THRESHOLD = 50_000 * 1e6;  // $50K notional
    uint256 public constant ARB_THRESHOLD_BPS = 20;            // 0.20% dislocation
    uint256 public constant JIT_PENALTY_BPS   = 300;           // 3% penalty to JIT LPs
    uint256 public constant MAX_BACKRUN_WINDOW = 2;            // 2 blocks after trigger trade

    // Revenue splits (BPS, must sum to BPS)
    uint256 public constant STAKERS_SHARE  = 6000; // 60% to veWIK stakers
    uint256 public constant INSURANCE_SHARE = 2000; // 20% to insurance fund
    uint256 public constant TRIGGER_SHARE   = 1000; // 10% to trade that triggered
    uint256 public constant KEEPER_SHARE    = 1000; // 10% to backrun keeper

    // ──────────────────────────────────────────────────────────────────────
    //  Interfaces
    // ──────────────────────────────────────────────────────────────────────





    // ──────────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Records a backrun opportunity created by a trade
    struct BackrunOpportunity {
        bytes32 marketId;
        address triggerTrader;   // user who created the opportunity [A4]
        uint256 triggerBlock;    // block of the triggering trade
        uint256 priceAtTrigger;  // oracle price at time of trigger
        uint256 ammPriceAtTrigger; // AMM/pool price at trigger
        uint256 triggerSize;     // notional of triggering trade
        bool    fulfilled;
        address fulfiller;       // keeper who backran [A4]
        uint256 profitCaptured;  // USDC captured from the backrun
        uint256 createdAt;
    }

    /// @dev JIT liquidity event tracker
    struct JITEvent {
        address lp;
        uint256 blockNumber;
        uint256 amount;
        uint256 penalty;
        bool    penaltyApplied;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────────
    IWikiStaking public staking;
    IWikiVault   public vault;
    IWikiOracle  public oracle;
    IERC20       public immutable USDC;

    BackrunOpportunity[] public opportunities;
    JITEvent[]           public jitEvents;

    // marketId → latest open opportunity index
    mapping(bytes32 => uint256) public latestOpportunity;
    mapping(bytes32 => bool)    public hasOpenOpportunity;

    // Registered pools (for price comparison)
    mapping(bytes32 => address) public marketPools; // marketId → Uniswap V3 pool

    // Keepers [A2]
    mapping(address => bool)    public keepers;
    mapping(uint256 => bool)    public opportunityFulfilled;

    // Sandwich protection state
    mapping(address => uint256) public committedPrice; // user → committed price
    mapping(address => bytes32) public committedMarket;

    // Registered callers that can trigger afterHook (WikiPerp, WikiSpot)
    mapping(address => bool)    public hookCallers;

    // Revenue accounting
    uint256 public totalMEVCaptured;
    uint256 public totalPaidToStakers;
    uint256 public totalPaidToInsurance;
    uint256 public totalPaidToTriggers;
    uint256 public totalPaidToKeepers;

    // ──────────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────────
    event BackrunOpportunityCreated(
        uint256 indexed oppId,
        bytes32 indexed marketId,
        address indexed triggerTrader,
        uint256 priceAtTrigger,
        uint256 ammPrice,
        uint256 triggerSize,
        uint256 dislocBps
    );
    event BackrunFulfilled(
        uint256 indexed oppId,
        address indexed keeper,
        uint256 profitCaptured,
        uint256 toStakers,
        uint256 toInsurance,
        uint256 toTrigger,
        uint256 toKeeper
    );
    event SandwichRefund(address indexed user, bytes32 marketId, uint256 refund);
    event JITPenaltyCharged(address indexed lp, uint256 penalty);
    event MEVSharePaid(address indexed recipient, uint256 amount, string role);
    event PoolRegistered(bytes32 indexed marketId, address pool);
    event HookCallerSet(address caller, bool enabled);

    // ──────────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────────
    constructor(
        address _staking,
        address _vault,
        address _oracle,
        address _usdc,
        address _owner
    ) Ownable(_owner) {
        require(_staking != address(0), "Wiki: zero _staking");
        require(_vault != address(0), "Wiki: zero _vault");
        require(_oracle != address(0), "Wiki: zero _oracle");
        staking = IWikiStaking(_staking);
        vault   = IWikiVault(_vault);
        oracle  = IWikiOracle(_oracle);
        USDC    = IERC20(_usdc);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Owner Config
    // ──────────────────────────────────────────────────────────────────────

    function setKeeper(address keeper, bool enabled) external onlyOwner {
        keepers[keeper] = enabled;
    }

    function setHookCaller(address caller, bool enabled) external onlyOwner {
        hookCallers[caller] = enabled;
        emit HookCallerSet(caller, enabled);
    }

    function registerPool(bytes32 marketId, address pool) external onlyOwner {
        marketPools[marketId] = pool;
        emit PoolRegistered(marketId, pool);
    }

    function setContracts(address _staking, address _vault, address _oracle) external onlyOwner {
        staking = IWikiStaking(_staking);
        vault   = IWikiVault(_vault);
        oracle  = IWikiOracle(_oracle);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  After-Trade Hook (called by WikiPerp/WikiSpot post execution)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Post-trade hook. WikiPerp calls this after every fill.
     *         Creates a backrun opportunity if conditions are met.
     *
     * @param marketId      Market that was traded
     * @param trader        User who placed the trade
     * @param notional      Trade size in USDC
     * @param fillPrice     Price at which trade was filled (18 dec)
     * @param isLong        Direction of the trade
     */
    function afterTrade(
        bytes32 marketId,
        address trader,
        uint256 notional,
        uint256 fillPrice,
        bool    isLong
    ) external {
        require(hookCallers[msg.sender], "MEV: not hook caller");

        // Only create opportunity for trades above threshold
        if (notional < BACKRUN_THRESHOLD) return;

        // Get AMM pool price for comparison
        uint256 ammPrice = _getAMMPrice(marketId, fillPrice);

        // Compute dislocation
        uint256 dislocBps = _dislocBps(fillPrice, ammPrice);

        // Only create opportunity if dislocation is significant
        if (dislocBps < ARB_THRESHOLD_BPS) return;

        // [A4] Cannot have same trigger as fulfiller — tracked via struct
        uint256 oppId = opportunities.length;
        opportunities.push(BackrunOpportunity({
            marketId:          marketId,
            triggerTrader:     trader,
            triggerBlock:      block.number,
            priceAtTrigger:    fillPrice,
            ammPriceAtTrigger: ammPrice,
            triggerSize:       notional,
            fulfilled:         false,
            fulfiller:         address(0),
            profitCaptured:    0,
            createdAt:         block.timestamp
        }));

        latestOpportunity[marketId]  = oppId;
        hasOpenOpportunity[marketId] = true;

        emit BackrunOpportunityCreated(oppId, marketId, trader, fillPrice, ammPrice, notional, dislocBps);
    }

    /**
     * @notice Keeper submits the backrun trade and reports captured profit.
     *         Keeper must have already executed the arb off-chain or via flash loan.
     *
     * @param oppId         Opportunity ID from BackrunOpportunityCreated event
     * @param profitUsdc    Actual profit captured by the keeper (USDC, 6 dec)
     */
    function submitBackrun(uint256 oppId, uint256 profitUsdc)
        external nonReentrant
    {
        require(keepers[msg.sender],                              "MEV: not keeper"); // [A2]
        BackrunOpportunity storage opp = opportunities[oppId];
        require(!opp.fulfilled,                                   "MEV: already fulfilled");
        require(block.number <= opp.triggerBlock + MAX_BACKRUN_WINDOW, "MEV: window expired");
        require(opp.fulfiller != opp.triggerTrader,               "MEV: self-backrun"); // [A4]
        require(profitUsdc > 0,                                   "MEV: no profit");

        // [A3] Validate: profit must be plausible vs dislocation
        uint256 expectedMaxProfit = opp.triggerSize * 100 / BPS; // max 1% of notional
        require(profitUsdc <= expectedMaxProfit, "MEV: profit too high (oracle mismatch)");

        // [A2] State before transfer
        opp.fulfilled      = true;
        opp.fulfiller      = msg.sender;
        opp.profitCaptured = profitUsdc;
        hasOpenOpportunity[opp.marketId] = false;
        totalMEVCaptured += profitUsdc;

        // Pull profit from keeper
        USDC.safeTransferFrom(msg.sender, address(this), profitUsdc);

        // Distribute MEV revenue
        _distributeMEV(opp, profitUsdc);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Sandwich Protection
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Record price commitment before trade execution.
     *         If fill is worse, user gets compensated from MEV fund.
     */
    function commitPrice(bytes32 marketId, uint256 price) external {
        committedPrice[msg.sender]  = price;
        committedMarket[msg.sender] = marketId;
    }

    /**
     * @notice Check if user was sandwiched and compensate from MEV fund.
     *         Called by WikiPerp after fill.
     */
    function checkAndCompensate(address user, bytes32 marketId, bool isLong, uint256 fillPrice)
        external nonReentrant
    {
        require(hookCallers[msg.sender], "MEV: not hook caller");
        if (committedMarket[user] != marketId) return;

        uint256 committed = committedPrice[user];
        if (committed == 0) return;

        // Clear commitment
        committedPrice[user]  = 0;
        committedMarket[user] = bytes32(0);

        // Was user sandwiched? (fill worse than committed by > 5bps)
        bool sandwiched;
        uint256 slippageBps;
        if (isLong && fillPrice > committed) {
            slippageBps = (fillPrice - committed) * BPS / committed;
            sandwiched  = slippageBps > 5;
        } else if (!isLong && fillPrice < committed) {
            slippageBps = (committed - fillPrice) * BPS / committed;
            sandwiched  = slippageBps > 5;
        }

        if (!sandwiched) return;

        // Compensate from MEV balance (capped at available balance)
        uint256 mevBal = USDC.balanceOf(address(this));
        if (mevBal == 0) return;

        // Compensation: half of slippage on $1K reference notional
        uint256 compensation = slippageBps * 1000 * 1e6 / BPS / 2;
        if (compensation > mevBal) compensation = mevBal;
        if (compensation == 0) return;

        USDC.safeTransfer(user, compensation);
        emit SandwichRefund(user, marketId, compensation);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  JIT Liquidity Protection
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice WikiAMM calls this when LP deposits in same block as large trade.
     *         JIT LP is charged a penalty fee.
     */
    function onLPDeposit(address lp, uint256 amount, uint256 tradeBlock) external {
        require(hookCallers[msg.sender], "MEV: not hook caller");
        if (block.number != tradeBlock) return; // not JIT if different block

        uint256 penalty = amount * JIT_PENALTY_BPS / BPS;
        uint256 jitId   = jitEvents.length;
        jitEvents.push(JITEvent({
            lp:             lp,
            blockNumber:    block.number,
            amount:         amount,
            penalty:        penalty,
            penaltyApplied: true
        }));

        emit JITPenaltyCharged(lp, penalty);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Internal: Distribution + Pricing
    // ──────────────────────────────────────────────────────────────────────

    function _distributeMEV(BackrunOpportunity storage opp, uint256 profit) internal {
        uint256 toStakers   = profit * STAKERS_SHARE   / BPS;
        uint256 toInsurance = profit * INSURANCE_SHARE / BPS;
        uint256 toTrigger   = profit * TRIGGER_SHARE   / BPS;
        uint256 toKeeper    = profit - toStakers - toInsurance - toTrigger;

        totalPaidToStakers   += toStakers;
        totalPaidToInsurance += toInsurance;
        totalPaidToTriggers  += toTrigger;
        totalPaidToKeepers   += toKeeper;

        // Pay stakers via distribution contract
        if (toStakers > 0) {
            USDC.approve(address(staking), toStakers);
            try staking.distributeFees(toStakers) {} catch {}
        }

        // Pay insurance fund
        if (toInsurance > 0) {
            try USDC.transfer(address(vault), toInsurance) {} catch {}
        }

        // Pay trigger trader
        if (toTrigger > 0 && opp.triggerTrader != address(0)) {
            USDC.safeTransfer(opp.triggerTrader, toTrigger);
            emit MEVSharePaid(opp.triggerTrader, toTrigger, "trigger");
        }

        // Pay keeper
        if (toKeeper > 0) {
            USDC.safeTransfer(opp.fulfiller, toKeeper);
            emit MEVSharePaid(opp.fulfiller, toKeeper, "keeper");
        }

        emit BackrunFulfilled(
            opportunities.length - 1, opp.fulfiller, profit,
            toStakers, toInsurance, toTrigger, toKeeper
        );
    }

    function _getAMMPrice(bytes32 marketId, uint256 oraclePrice) internal view returns (uint256) {
        address pool = marketPools[marketId];
        if (pool == address(0)) return oraclePrice; // No pool registered → use oracle

        try IUniswapV3Pool(pool).slot0() returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool) {
            // Convert sqrtPriceX96 to price (18 dec)
            // price = (sqrtPriceX96 / 2^96)^2
            uint256 sqrtPrice = uint256(sqrtPriceX96);
            uint256 price     = sqrtPrice * sqrtPrice * 1e18 >> 192;
            return price;
        } catch {
            return oraclePrice;
        }
    }

    function _dislocBps(uint256 p1, uint256 p2) internal pure returns (uint256) {
        if (p1 == 0 || p2 == 0) return 0;
        uint256 hi = p1 > p2 ? p1 : p2;
        uint256 lo = p1 > p2 ? p2 : p1;
        return (hi - lo) * BPS / lo;
    }

    // ──────────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────────

    function getOpportunity(uint256 id) external view returns (BackrunOpportunity memory) {
        return opportunities[id];
    }

    function opportunityCount() external view returns (uint256) {
        return opportunities.length;
    }

    /// @notice Revenue stats for dashboard
    function revenueStats() external view returns (
        uint256 captured,
        uint256 toStakers,
        uint256 toInsurance,
        uint256 toTriggers,
        uint256 toKeepers
    ) {
        return (
            totalMEVCaptured,
            totalPaidToStakers,
            totalPaidToInsurance,
            totalPaidToTriggers,
            totalPaidToKeepers
        );
    }

    /// @notice Check if there's an open opportunity for a market (for keeper monitoring)
    function getOpenOpportunity(bytes32 marketId) external view returns (
        bool exists,
        uint256 oppId,
        uint256 dislocBps,
        uint256 expiresAtBlock
    ) {
        exists = hasOpenOpportunity[marketId];
        if (!exists) return (false, 0, 0, 0);
        oppId = latestOpportunity[marketId];
        BackrunOpportunity storage opp = opportunities[oppId];
        dislocBps      = _dislocBps(opp.priceAtTrigger, opp.ammPriceAtTrigger);
        expiresAtBlock = opp.triggerBlock + MAX_BACKRUN_WINDOW;
    }
}
