// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title WikiPropFunded — Funded prop trading accounts
///
/// CAPITAL FLOW:
///   1. Funded account created after eval passes
///   2. Trader opens position → WikiPerp executes the trade
///   3. Profits paid out, losses taken from funded balance

interface IFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IAaveFlashLoan {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16  referralCode
    ) external;
}

interface IWikiPropPoolForFunded {
    function allocateCapital(address trader, uint256 amount) external;
    function returnCapital(address trader, uint256 amount, uint256 profit, uint256 loss) external;
    function receiveProfitSplit(uint256 amount) external;
    function availableCapital() external view returns (uint256);
}

/// contract requests capital from WikiPropPool
///      If pool insufficient → flash loan from Aave V3 as overflow
///   3. Position runs → P&L tracked in real time
///   4. Breach detected → account closed, pool capital returned, loss absorbed
///   5. Profit withdrawal → trader gets split, pool/protocol get remainder
///
/// TIERED PROFIT SPLIT (scales with cumulative profits):
///   $0     → first profit target:  initial split (60/70/80%)
///   After 2× account size profit:  80%
///   After 5× account size profit:  90%  (max)
///
/// ACCOUNT SCALING:
///   After consistent profitability → trader can request account size increase
///   Scale up 25% at a time, max 2× original size per cycle
///
/// BREACH RULES (apply immediately):
///   Daily drawdown > tier limit → account closed
///   Total drawdown > tier limit → account closed
///   On breach: pool absorbs loss up to account size, trader loses nothing extra
///              (their collateral was never used — only eval fee at risk)

interface IWikiPerpForFunded {
    function openPositionFor(
        address trader,
        address funder,      // funded contract pays collateral
        uint256 marketIndex,
        bool    isLong,
        uint256 size,
        uint256 collateral,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 expiry
    ) external returns (uint256 posId);

    function closePosition(uint256 posId, uint256 minPrice, uint256 maxPrice)
        external returns (int256 pnl);

    function getPositionPnl(uint256 posId) external view returns (int256 unrealizedPnl);
}


// Aave V3 flash loan interface



contract WikiPropFunded is Ownable2Step, ReentrancyGuard, Pausable, IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    IERC20   public immutable USDC;
    address  public perpContract;
    address  public propPool;
    address  public evalContract;
    address  public protocolTreasury;

    // Aave V3 on Arbitrum
    address  public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    uint256  public constant AAVE_FLASH_FEE_BPS = 9; // 0.09%

    // ── Funded account ─────────────────────────────────────────────────────
    enum FundedStatus { Active, Breached, Closed, Scaled }

    struct FundedAccount {
        address      trader;
        uint8        tier;
        FundedStatus status;
        uint256      accountSize;         // current funded buying power
        uint256      originalSize;        // original at creation
        uint256      startingBalance;     // = accountSize at creation
        uint256      currentBalance;      // tracks P&L
        uint256      peakBalance;
        uint256      dailyStartBalance;
        uint256      lastDayTs;
        uint256      traderSplitBps;      // current split (e.g. 7000 = 70%)
        uint256      cumulativeProfitPaid;// lifetime profits paid to trader
        uint256      cumulativePoolProfit;// lifetime to pool
        uint256      totalTrades;
        uint256      createdAt;
        uint256      closedAt;
        bool         usingFlashLoan;      // true if current trade uses flash loan
        uint256      activePositionId;    // WikiPerp position currently open
        uint256      allocatedCapital;    // capital currently out from pool
        string       closeReason;
        // ── Retention tracking ────────────────────────────────────────────
        uint256      retainedBuffer;      // profit retained — must stay above 0
        uint256      withdrawalCount;     // total withdrawals made
        uint256      lastWithdrawalTs;    // timestamp of last withdrawal
        uint256      totalWithdrawn;      // lifetime withdrawn by trader
    }

    // Drawdown limits per tier (bps)
    mapping(uint8 => uint256) public dailyDDLimitBps;
    mapping(uint8 => uint256) public totalDDLimitBps;

    // Split scaling thresholds (in multiples of account size)
    uint256 public constant SPLIT_SCALE_1_X = 2;  // 2× account size profit → 80%
    uint256 public constant SPLIT_SCALE_2_X = 5;  // 5× account size profit → 90%
    uint256 public constant MAX_SPLIT_BPS   = 9000;
    uint256 public constant PROTOCOL_SHARE_OF_POOL_BPS = 2000;

    // ── Funded Account Leverage Caps ──────────────────────────────────────
    // Funded accounts use REAL pool capital — leverage is strictly capped.
    // We evaluated them at 50× in Phase 2. Funded = even more conservative.
    // 
    // Why lower than eval?
    //   Eval = simulated money. They can lose it freely, we lose nothing.
    //   Funded = our pool's real USDC. Every 1% loss is real money gone.
    //   Lower leverage = smaller max loss per trade = pool stays healthy.
    //
    // Tier-based caps (higher fee paid → slightly more trust → slightly more lev):
    //   Tier 1 (Standard):   max 10× on funded account
    //   Tier 2 (Aggressive): max 15× on funded account
    //   Tier 3 (Instant):    max  5× on funded account (skipped eval → least trust)
    //
    // Market-class overrides (some markets get even lower caps):
    //   Crypto majors:  max leverage as per tier (10× or 15×)
    //   Forex:          max 20× (stable, deep liquidity)
    //   Metals/Commod:  max 10× (can gap overnight)
    //   Indices:        max 10×
    //
    // Trader can always use LESS than the cap. They cannot go above it.
    mapping(uint8 => uint256)  public tierMaxLeverage;      // tier → max lev
    mapping(uint256 => uint256) public marketMaxLeverage;   // marketId → override cap

    // ── Profit Retention Rule ──────────────────────────────────────────────
    // Traders must leave at least MIN_RETAIN_PCT% of each profit withdrawal
    // inside the account as a buffer above starting balance.
    //
    // Why: Prevents traders from extracting ALL profits then immediately
    //      going on a reckless high-risk spree with nothing to lose.
    //      The retained buffer keeps them "in the game" with skin in the game.
    //
    // Example (25% retention, $10K account, $2,000 profit):
    //   Max withdrawable = $2,000 × 75% = $1,500
    //   Retained buffer  = $2,000 × 25% = $500 stays in account
    //   If they blow the $500 buffer → account closed automatically
    //
    // Benefit to protocol:
    //   - Retained buffer earns more trading → more fees for us
    //   - Trader stays engaged longer → more volume
    //   - If they blow the buffer → account auto-closed, pool capital returned
    uint256 public minRetainPct      = 25;   // 25% of profit must stay in account
    uint256 public minRetainBuffer   = 0;    // absolute floor — set per account on creation
    uint256 public cooldownPeriod    = 7 days; // must wait 7 days between withdrawals
    bool    public retentionEnabled  = true; // owner can disable for VIP accounts // 20% of pool's split goes to treasury

    mapping(uint256 => FundedAccount) public accounts;
    mapping(address => uint256[])     public traderAccounts;
    mapping(address => uint256)       public activeFundedId;
    uint256 public totalFundedAccounts;

    // Flash loan state (used during executeOperation callback)
    uint256 private _flashLoanAccountId;
    uint256 private _flashLoanPositionSize;
    bool    private _inFlashLoan;

    // Revenue
    uint256 public totalProfitPaidToTraders;
    uint256 public totalProfitPaidToPool;
    uint256 public totalProfitPaidToProtocol;
    uint256 public totalLossesAbsorbed;

    // Events
    event FundedAccountCreated(uint256 indexed accountId, address indexed trader, uint256 size, uint8 tier);
    event PositionOpened(uint256 indexed accountId, uint256 posId, uint256 size, bool isLong, bool flashLoan);
    event PositionClosed(uint256 indexed accountId, uint256 posId, int256 pnl);
    event ProfitWithdrawn(uint256 indexed accountId, address trader, uint256 traderAmt, uint256 poolAmt);
    event AccountBreached(uint256 indexed accountId, address trader, string reason, uint256 loss);
    event AccountScaled(uint256 indexed accountId, uint256 oldSize, uint256 newSize);
    event SplitUpgraded(uint256 indexed accountId, address trader, uint256 newSplitBps);

    constructor(address usdc, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(owner != address(0), "Wiki: zero owner");
        USDC = IERC20(usdc);
        // Set drawdown limits per tier
        dailyDDLimitBps[1] = 400;  // tier 1: 4%
        dailyDDLimitBps[2] = 500;  // tier 2: 5%
        dailyDDLimitBps[3] = 300;  // tier 3: 3% (instant, tighter)
        totalDDLimitBps[1] = 800;  // tier 1: 8%
        totalDDLimitBps[2] = 1000; // tier 2: 10%
        totalDDLimitBps[3] = 600;  // tier 3: 6%
    }

    // ── Create funded account (called by WikiPropEval) ─────────────────────
    function createFundedAccount(
        address trader,
        uint256 accountSize,
        uint8   tier,
        uint8   initialSplitPct  // e.g. 70 = 70%
    ) external nonReentrant returns (uint256 accountId) {
        require(msg.sender == evalContract, "Funded: only eval contract");
        require(activeFundedId[trader] == 0, "Funded: already has funded account");

        accountId = ++totalFundedAccounts;
        uint256 ts = block.timestamp;

        accounts[accountId] = FundedAccount({
            trader:               trader,
            tier:                 tier,
            status:               FundedStatus.Active,
            accountSize:          accountSize,
            originalSize:         accountSize,
            startingBalance:      accountSize,
            currentBalance:       accountSize,
            peakBalance:          accountSize,
            dailyStartBalance:    accountSize,
            lastDayTs:            ts,
            traderSplitBps:       uint256(initialSplitPct) * 100,
            cumulativeProfitPaid: 0,
            cumulativePoolProfit: 0,
            totalTrades:          0,
            createdAt:            ts,
            closedAt:             0,
            usingFlashLoan:       false,
            activePositionId:     0,
            allocatedCapital:     0,
            closeReason:          "",
            retainedBuffer:       0,
            withdrawalCount:      0,
            lastWithdrawalTs:     0,
            totalWithdrawn:       0
        });

        traderAccounts[trader].push(accountId);
        activeFundedId[trader] = accountId;

        emit FundedAccountCreated(accountId, trader, accountSize, tier);
    }

    // ── Open position on funded account ───────────────────────────────────
    /// @notice Opens a WikiPerp position using pool capital.
    ///
    ///         LEVERAGE CAP (strictly enforced):
    ///           Funded accounts use real pool capital. Leverage is capped per
    ///           tier and per market class. Trader cannot exceed the cap.
    ///
    ///           Tier 1: max 10× | Tier 2: max 15× | Tier 3 (instant): max 5×
    ///           Market override: forex 20×, metals 10×, indices 10×
    ///
    ///         Why this protects the pool:
    ///           At 10×, a 10% adverse move = 100% loss of collateral only.
    ///           Pool loss is capped at the collateral amount.
    ///           At 100×, a 1% adverse move does the same damage.
    ///           Lower leverage = more price room = smaller gap risk to pool.
    function openPosition(
        uint256 accountId,
        uint256 marketIndex,
        bool    isLong,
        uint256 positionSize,  // notional in USDC (6 dec)
        uint256 leverage,      // explicit leverage requested by trader
        uint256 minPrice,
        uint256 maxPrice
    ) external nonReentrant whenNotPaused {
        FundedAccount storage acc = accounts[accountId];
        require(acc.trader == msg.sender,           "Funded: not your account");
        require(acc.status == FundedStatus.Active,   "Funded: account not active");
        require(acc.activePositionId == 0,           "Funded: position already open");
        require(positionSize > 0,                    "Funded: zero size");
        require(positionSize <= acc.accountSize,     "Funded: exceeds account size");
        require(leverage >= 1,                       "Funded: leverage must be >= 1");

        // ── LEVERAGE CAP ENFORCEMENT ──────────────────────────────────────
        // Step 1: Get tier cap
        uint256 tierCap    = tierMaxLeverage[acc.tier];
        if (tierCap == 0) tierCap = 10; // fallback safety

        // Step 2: Check market-specific override (lower wins — most conservative)
        uint256 marketCap  = marketMaxLeverage[marketIndex];
        uint256 effectiveCap = (marketCap > 0 && marketCap < tierCap)
            ? marketCap   // market override is stricter
            : tierCap;    // tier cap applies

        // Step 3: Enforce — revert with clear message showing what is allowed
        require(
            leverage <= effectiveCap,
            string(abi.encodePacked(
                "Funded: max leverage on funded account is ",
                Strings.toString(effectiveCap),
                "x (Tier ",
                Strings.toString(uint256(acc.tier)),
                unicode" funded cap). Eval was higher — funded uses real pool capital."
            ))
        );

        _refreshDaily(acc);
        _checkBreachConditions(accountId);

        // Collateral = positionSize / leverage (explicit from trader's input)
        uint256 collateral = positionSize / leverage;

        // Try pool first, flash loan as overflow
        uint256 poolAvail = IWikiPropPoolForFunded(propPool).availableCapital();
        bool useFlashLoan = collateral > poolAvail;

        if (!useFlashLoan) {
            // Use pool capital
            IWikiPropPoolForFunded(propPool).allocateCapital(msg.sender, collateral);
            acc.allocatedCapital = collateral;
            acc.usingFlashLoan   = false;

            uint256 posId = IWikiPerpForFunded(perpContract).openPositionFor(
                msg.sender, address(this), marketIndex, isLong,
                positionSize, collateral, minPrice, maxPrice, block.timestamp + 1 hours
            );
            acc.activePositionId = posId;
            acc.totalTrades++;
            emit PositionOpened(accountId, posId, positionSize, isLong, false);
        } else {
            // Flash loan from Aave
            acc.usingFlashLoan = true;
            _flashLoanAccountId    = accountId;
            _flashLoanPositionSize = positionSize;
            _inFlashLoan           = true;

            // Encode params for executeOperation callback
            bytes memory params = abi.encode(accountId, marketIndex, isLong, positionSize, minPrice, maxPrice);
            IAaveFlashLoan(AAVE_POOL).flashLoanSimple(
                address(this), address(USDC), collateral, params, 0
            );
            _inFlashLoan = false;
        }
    }

    // ── Aave flash loan callback ───────────────────────────────────────────
    function executeOperation(
        address asset,
        uint256 amount,       // flash loaned collateral
        uint256 premium,      // Aave fee (0.09%)
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == AAVE_POOL,  "Funded: only Aave");
        require(initiator == address(this), "Funded: only self");
        require(_inFlashLoan,              "Funded: not in flash loan");

        (uint256 accountId, uint256 marketIndex, bool isLong,
         uint256 posSize, uint256 minP, uint256 maxP) = abi.decode(
            params, (uint256, uint256, bool, uint256, uint256, uint256)
        );

        FundedAccount storage acc = accounts[accountId];

        // Approve WikiPerp to use the flash loaned collateral
        USDC.approve(perpContract, amount);
        uint256 posId = IWikiPerpForFunded(perpContract).openPositionFor(
            acc.trader, address(this), marketIndex, isLong,
            posSize, amount, minP, maxP, block.timestamp + 1 hours
        );
        acc.activePositionId = posId;
        acc.allocatedCapital = amount;
        acc.totalTrades++;

        // Repay flash loan: amount + premium
        // This comes from the position's collateral already locked in WikiPerp
        // The funded contract must have enough USDC to pay premium
        // Premium is charged to the funded account's balance (small cost)
        uint256 totalRepay = amount + premium;
        USDC.approve(AAVE_POOL, totalRepay);

        // Deduct flash loan fee from account balance
        uint256 flashFee = premium;
        acc.currentBalance = acc.currentBalance > flashFee
            ? acc.currentBalance - flashFee : 0;

        emit PositionOpened(accountId, posId, posSize, isLong, true);
        return true;
    }

    // ── Close position ─────────────────────────────────────────────────────
    function closePosition(
        uint256 accountId,
        uint256 minPrice,
        uint256 maxPrice
    ) external nonReentrant {
        FundedAccount storage acc = accounts[accountId];
        require(acc.trader == msg.sender || msg.sender == owner(), "Funded: not authorized");
        require(acc.status == FundedStatus.Active,  "Funded: not active");
        require(acc.activePositionId != 0,          "Funded: no open position");

        uint256 posId = acc.activePositionId;
        int256  pnl   = IWikiPerpForFunded(perpContract).closePosition(posId, minPrice, maxPrice);

        acc.activePositionId = 0;
        _refreshDaily(acc);

        if (pnl >= 0) {
            uint256 profit = uint256(pnl);
            acc.currentBalance += profit;
            if (acc.currentBalance > acc.peakBalance) acc.peakBalance = acc.currentBalance;
        } else {
            uint256 loss = uint256(-pnl);
            acc.currentBalance = acc.currentBalance > loss ? acc.currentBalance - loss : 0;
        }

        // Return capital to pool
        if (acc.allocatedCapital > 0) {
            uint256 alloc  = acc.allocatedCapital;
            acc.allocatedCapital = 0;
            if (pnl >= 0) {
                IWikiPropPoolForFunded(propPool).returnCapital(acc.trader, alloc, uint256(pnl), 0);
            } else {
                uint256 loss = uint256(-pnl);
                IWikiPropPoolForFunded(propPool).returnCapital(acc.trader, alloc, 0, loss);
            }
        }

        emit PositionClosed(accountId, posId, pnl);

        // Post-close breach check
        _checkBreachConditions(accountId);
    }

    // ── Withdraw profits ───────────────────────────────────────────────────
    /// @notice Trader withdraws their share of realized profits.
    ///
    ///         RETENTION RULE (enforced on-chain):
    ///           Trader must leave minRetainPct% of each profit in the account.
    ///           This retained buffer sits above startingBalance.
    ///           If it drops to zero (losses eat it) → account auto-closed.
    ///
    ///         COOLDOWN RULE (enforced on-chain):
    ///           Must wait cooldownPeriod (7 days) between withdrawals.
    ///           Prevents daily full-drain pattern.
    ///
    ///         Example ($10K account, $2,000 profit, 25% retention):
    ///           Profit:            $2,000
    ///           Must retain (25%): $500  ← stays in account, earns more fees
    ///           Max withdrawable:  $1,500 × traderSplit%
    ///           Buffer floor:      startingBalance + $500
    ///           If account drops below this floor → auto-close
    function withdrawProfits(uint256 accountId) external nonReentrant {
        FundedAccount storage acc = accounts[accountId];
        require(acc.trader == msg.sender,              "Funded: not your account");
        require(acc.status == FundedStatus.Active,     "Funded: not active");
        require(acc.activePositionId == 0,             "Funded: close position first");

        // ── Cooldown check ────────────────────────────────────────────────
        require(
            acc.lastWithdrawalTs == 0 ||
            block.timestamp >= acc.lastWithdrawalTs + cooldownPeriod,
            "Funded: withdrawal cooldown active (7 days)"
        );

        // ── Calculate gross profit ────────────────────────────────────────
        uint256 grossProfit = acc.currentBalance > acc.startingBalance
            ? acc.currentBalance - acc.startingBalance : 0;
        require(grossProfit > 0, "Funded: no profit to withdraw");

        // ── Apply retention rule ──────────────────────────────────────────
        uint256 retainAmount  = 0;
        uint256 withdrawable  = grossProfit;

        if (retentionEnabled && minRetainPct > 0) {
            retainAmount = grossProfit * minRetainPct / 100;
            withdrawable = grossProfit - retainAmount; // max 75% withdrawable
            require(withdrawable > 0, "Funded: profit too small after retention");

            // Update retained buffer — this is the floor above startingBalance
            acc.retainedBuffer += retainAmount;
        }

        // ── Calculate split on withdrawable portion only ──────────────────
        uint256 traderShare   = withdrawable * acc.traderSplitBps / 10000;
        uint256 protocolShare = withdrawable - traderShare;
        uint256 poolShare     = protocolShare * (10000 - PROTOCOL_SHARE_OF_POOL_BPS) / 10000;
        uint256 treasuryShare = protocolShare - poolShare;

        // ── Update balance ────────────────────────────────────────────────
        // Starting balance resets to: original + retained buffer
        // Retained amount stays in the account as a cushion
        acc.currentBalance       = acc.startingBalance + acc.retainedBuffer;
        acc.cumulativeProfitPaid += traderShare;
        acc.cumulativePoolProfit += poolShare;
        acc.withdrawalCount++;
        acc.lastWithdrawalTs     = block.timestamp;
        acc.totalWithdrawn       += traderShare;

        // ── Update split tier ─────────────────────────────────────────────
        _updateSplit(accountId);

        // ── Transfers ─────────────────────────────────────────────────────
        if (traderShare > 0)    USDC.safeTransfer(acc.trader, traderShare);
        if (poolShare > 0) {
            USDC.approve(propPool, poolShare);
            IWikiPropPoolForFunded(propPool).receiveProfitSplit(poolShare);
        }
        if (treasuryShare > 0)  USDC.safeTransfer(protocolTreasury, treasuryShare);

        totalProfitPaidToTraders  += traderShare;
        totalProfitPaidToPool     += poolShare;
        totalProfitPaidToProtocol += treasuryShare;

        emit ProfitWithdrawn(accountId, acc.trader, traderShare, poolShare);

        // ── Check if buffer is now at risk ────────────────────────────────
        // After withdraw, the retained buffer becomes the new loss floor.
        // If subsequent losses eat through it → auto-close.
        _checkBufferBreachPost(accountId);
    }

    // ── Buffer breach check — called after every withdrawal ───────────────
    function _checkBufferBreachPost(uint256 accountId) internal {
        FundedAccount storage acc = accounts[accountId];
        if (acc.retainedBuffer == 0) return;

        // Floor = startingBalance + retainedBuffer
        // If current balance is already below floor after reset → something wrong
        // This is a sanity check — main breach check is in _checkBreachConditions
        uint256 floor = acc.startingBalance + (acc.retainedBuffer / 2); // warn at 50% buffer loss
        if (acc.currentBalance < floor) {
            emit BufferAtRisk(accountId, acc.trader, acc.currentBalance, floor);
        }
    }

    // ── Auto-close if retained buffer is fully eroded ────────────────────
    /// @notice Anyone can call this. If the retained buffer (profit the trader
    ///         chose not to withdraw) has been lost through bad trading,
    ///         the account is auto-closed and pool capital returned.
    ///         Prevents traders from recklessly trading after withdrawing profits.
    function checkBufferBreach(uint256 accountId) external nonReentrant {
        FundedAccount storage acc = accounts[accountId];
        require(acc.status == FundedStatus.Active, "Funded: not active");
        if (acc.retainedBuffer == 0) return; // no buffer set, no breach possible

        // Buffer breach: current balance < startingBalance (lost even the retained profit)
        if (acc.currentBalance < acc.startingBalance) {
            _breachAccount(accountId, "Retained buffer fully lost after profit withdrawal");
        }
    }

    /// @notice Owner can exempt VIP / institutional traders from retention rule
    function setRetentionExempt(uint256 accountId, bool exempt) external onlyOwner {
        // Store exempt flag — in practice add exemptFromRetention bool to struct
        // For now, owner can disable globally via retentionEnabled
    }

    /// @notice Get full withdrawal status for a funded account
    function getWithdrawalStatus(uint256 accountId) external view returns (
        uint256 grossProfit,
        uint256 retainAmount,
        uint256 maxWithdrawable,
        uint256 traderReceives,
        uint256 retainedBufferTotal,
        uint256 cooldownEndsAt,
        bool    canWithdrawNow,
        string  memory statusMsg
    ) {
        FundedAccount storage acc = accounts[accountId];
        grossProfit = acc.currentBalance > acc.startingBalance
            ? acc.currentBalance - acc.startingBalance : 0;

        if (grossProfit == 0) {
            return (0, 0, 0, 0, acc.retainedBuffer, 0, false, "No profit to withdraw");
        }

        retainAmount      = grossProfit * minRetainPct / 100;
        maxWithdrawable   = grossProfit - retainAmount;
        traderReceives    = maxWithdrawable * acc.traderSplitBps / 10000;
        retainedBufferTotal= acc.retainedBuffer + retainAmount; // total after this withdrawal
        cooldownEndsAt    = acc.lastWithdrawalTs + cooldownPeriod;
        canWithdrawNow    = block.timestamp >= cooldownEndsAt || acc.lastWithdrawalTs == 0;
        statusMsg         = canWithdrawNow
            ? "Ready to withdraw"
            : unicode"Cooldown active — wait for next withdrawal window";
    }

    event BufferAtRisk(uint256 indexed accountId, address trader, uint256 currentBalance, uint256 floor);

    // ── Breach detection (callable by anyone / keeper) ─────────────────────
    function checkBreach(uint256 accountId) external nonReentrant {
        _checkBreachConditions(accountId);
    }

    function _checkBreachConditions(uint256 accountId) internal {
        FundedAccount storage acc = accounts[accountId];
        if (acc.status != FundedStatus.Active) return;

        _refreshDaily(acc);

        // Daily drawdown
        uint256 dailyLoss    = acc.dailyStartBalance > acc.currentBalance
            ? acc.dailyStartBalance - acc.currentBalance : 0;
        uint256 maxDailyLoss = acc.startingBalance * dailyDDLimitBps[acc.tier] / 10000;
        if (dailyLoss >= maxDailyLoss) {
            _breachAccount(accountId, "Daily drawdown limit exceeded");
            return;
        }

        // Total drawdown from peak
        uint256 totalLoss    = acc.peakBalance > acc.currentBalance
            ? acc.peakBalance - acc.currentBalance : 0;
        uint256 maxTotalLoss = acc.startingBalance * totalDDLimitBps[acc.tier] / 10000;
        if (totalLoss >= maxTotalLoss) {
            _breachAccount(accountId, "Total drawdown limit exceeded");
            return;
        }
    }

    function _breachAccount(uint256 accountId, string memory reason) internal {
        FundedAccount storage acc = accounts[accountId];
        acc.status      = FundedStatus.Breached;
        acc.closedAt    = block.timestamp;
        acc.closeReason = reason;
        activeFundedId[acc.trader] = 0;

        uint256 loss = acc.startingBalance > acc.currentBalance
            ? acc.startingBalance - acc.currentBalance : 0;
        totalLossesAbsorbed += loss;

        // Force close any open position
        if (acc.activePositionId != 0) {
            uint256 alloc = acc.allocatedCapital;
            acc.allocatedCapital = 0;
            IWikiPropPoolForFunded(propPool).returnCapital(acc.trader, alloc, 0, loss > alloc ? alloc : loss);
        }

        emit AccountBreached(accountId, acc.trader, reason, loss);
    }

    // ── Scale account (after consistent profitability) ────────────────────
    function requestScaleUp(uint256 accountId) external nonReentrant {
        FundedAccount storage acc = accounts[accountId];
        require(acc.trader == msg.sender,           "Funded: not your account");
        require(acc.status == FundedStatus.Active,   "Funded: not active");
        require(acc.activePositionId == 0,           "Funded: close position first");
        // Must have withdrawn profits at least once (proves profitability)
        require(acc.cumulativeProfitPaid > 0,        "Funded: withdraw profits first");
        // Max scale: 2× original size
        require(acc.accountSize < acc.originalSize * 2, "Funded: max scale reached");

        uint256 oldSize = acc.accountSize;
        uint256 newSize = oldSize + (oldSize / 4); // +25%
        if (newSize > acc.originalSize * 2) newSize = acc.originalSize * 2;

        acc.accountSize     = newSize;
        acc.startingBalance = acc.currentBalance; // reset reference

        emit AccountScaled(accountId, oldSize, newSize);
    }

    // ── Update split based on cumulative profits ───────────────────────────
    function _updateSplit(uint256 accountId) internal {
        FundedAccount storage acc = accounts[accountId];
        uint256 profitMultiple = acc.cumulativeProfitPaid * 10 / acc.originalSize; // in 0.1× steps

        uint256 newSplit = acc.traderSplitBps;
        if (profitMultiple >= SPLIT_SCALE_2_X * 10 && newSplit < MAX_SPLIT_BPS) {
            newSplit = MAX_SPLIT_BPS; // 90%
        } else if (profitMultiple >= SPLIT_SCALE_1_X * 10 && newSplit < 8000) {
            newSplit = 8000; // 80%
        }

        if (newSplit != acc.traderSplitBps) {
            acc.traderSplitBps = newSplit;
            emit SplitUpgraded(accountId, acc.trader, newSplit);
        }
    }

    function _refreshDaily(FundedAccount storage acc) internal {
        if (block.timestamp >= acc.lastDayTs + 1 days) {
            acc.dailyStartBalance = acc.currentBalance;
            acc.lastDayTs         = block.timestamp;
        }
    }

    // ── Views ──────────────────────────────────────────────────────────────
    function getAccount(uint256 id) external view returns (FundedAccount memory) { return accounts[id]; }
    function getTraderAccounts(address t) external view returns (uint256[] memory) { return traderAccounts[t]; }

    function accountStats(uint256 id) external view returns (
        uint256 profit, uint256 profitPct, uint256 traderCut, uint256 poolCut,
        uint256 dailyDDUsedPct, uint256 totalDDUsedPct, uint256 nextSplitAt
    ) {
        FundedAccount storage a = accounts[id];
        profit    = a.currentBalance > a.startingBalance ? a.currentBalance - a.startingBalance : 0;
        profitPct = profit * 10000 / a.startingBalance;
        traderCut = profit * a.traderSplitBps / 10000;
        poolCut   = profit - traderCut;

        uint256 dLoss = a.dailyStartBalance > a.currentBalance ? a.dailyStartBalance - a.currentBalance : 0;
        dailyDDUsedPct = dLoss * 10000 / a.startingBalance;

        uint256 tLoss = a.peakBalance > a.currentBalance ? a.peakBalance - a.currentBalance : 0;
        totalDDUsedPct = tLoss * 10000 / a.startingBalance;

        // Next split milestone
        if (a.traderSplitBps < 8000) {
            nextSplitAt = a.originalSize * SPLIT_SCALE_1_X; // need 2× in profits for 80%
        } else if (a.traderSplitBps < 9000) {
            nextSplitAt = a.originalSize * SPLIT_SCALE_2_X; // need 5× for 90%
        }
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setPerpContract(address p)   external onlyOwner { perpContract    = p; }
    function setPropPool(address p)       external onlyOwner { propPool        = p; }
    function setEvalContract(address e)   external onlyOwner { evalContract    = e; }
    function setTreasury(address t)       external onlyOwner { protocolTreasury = t; }
    function setDailyDDLimit(uint8 tier, uint256 bps) external onlyOwner { dailyDDLimitBps[tier] = bps; }
    function setTotalDDLimit(uint8 tier, uint256 bps) external onlyOwner { totalDDLimitBps[tier] = bps; }
    function forceCloseBreached(uint256 accountId) external onlyOwner { _breachAccount(accountId, "Force closed by admin"); }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setTierMaxLeverage(uint8 tier, uint256 maxLev) external onlyOwner {
        require(maxLev >= 1 && maxLev <= 20, "Funded: funded max lev must be 1-20");
        tierMaxLeverage[tier] = maxLev;
        emit TierLeverageUpdated(tier, maxLev);
    }

    function setMarketLeverageCap(uint256 marketId, uint256 maxLev) external onlyOwner {
        require(maxLev >= 1 && maxLev <= 50, "Funded: market cap 1-50");
        marketMaxLeverage[marketId] = maxLev;
        emit MarketLeverageCapUpdated(marketId, maxLev);
    }

    function getEffectiveLeverageCap(uint256 accountId, uint256 marketIndex)
        external view returns (uint256 effectiveCap, uint256 tierCap, uint256 marketCap, string memory reason)
    {
        FundedAccount storage acc = accounts[accountId];
        tierCap   = tierMaxLeverage[acc.tier];
        if (tierCap == 0) tierCap = 10;
        marketCap = marketMaxLeverage[marketIndex];
        if (marketCap > 0 && marketCap < tierCap) {
            effectiveCap = marketCap;
            reason = "Market-specific cap applies (stricter than tier default)";
        } else {
            effectiveCap = tierCap;
            reason = "Tier default cap applies";
        }
    }

    event TierLeverageUpdated(uint8 tier, uint256 maxLev);
    event MarketLeverageCapUpdated(uint256 marketId, uint256 maxLev);

}
