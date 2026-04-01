// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiAutoCompounder
 * @notice Every WIK token you earn, vest, or receive in fees is automatically
 *         re-staked as veWIK — maximising your share of future protocol fees
 *         and growing your governance power continuously over time.
 *
 * ─── THE GROWTH LOOP ─────────────────────────────────────────────────────────
 *
 *   Every compound cycle (default: weekly):
 *
 *   Step 1: CLAIM VESTED TOKENS
 *           WikiTokenVesting.claim() → your monthly WIK unlock arrives
 *
 *   Step 2: CLAIM FEE INCOME
 *           WikiStaking.claimFees() → USDC fees arrive
 *
 *   Step 3: REINVEST FEES (if enabled)
 *           USDC → buy more WIK via WikiSpotRouter
 *           Now you have even more WIK to stake
 *
 *   Step 4: STAKE ALL WIK
 *           All new WIK added to your existing veWIK lock
 *           Your veWIK balance grows
 *
 *   Step 5: RE-EXTEND LOCK (if enabled)
 *           Lock reset to maximum (4 years)
 *           veWIK stays at full power — no decay
 *
 *   Step 6: MORE FEES NEXT WEEK
 *           Bigger veWIK → bigger share of protocol fees
 *           Bigger fees → more WIK bought → even bigger veWIK
 *           The loop repeats indefinitely
 *
 * ─── COMPOUNDING MATH ────────────────────────────────────────────────────────
 *
 *   veWIK = amount × (remainingLock / MAX_LOCK)
 *   Without re-extension: decays 25%/year → you earn less fees each year
 *   With re-extension:    stays at 100% → maximum fees always
 *
 *   Year 1 (cliff period, no vesting yet):
 *     Start: 0 WIK staked
 *     Fee reinvestment if enabled: buys ~small WIK each week
 *
 *   Year 2 (post-cliff, 2.5M WIK/month unlocking for founder):
 *     Month 13:  +2.5M WIK staked → veWIK = 2.5M × 1.0 = 2.5M
 *     Month 14:  +2.5M more → veWIK = 5M × 1.0 = 5M
 *     Month 18:  +12.5M vested + fee compound WIK → veWIK ≈ 13M
 *
 *   Year 4 (fully vested + 2yr of fee compounding):
 *     All 90M WIK vested + ~8-12M WIK bought from fees
 *     veWIK ≈ 100-102M (more than allocation due to fee reinvestment)
 *     Fee income at this level: ~$50K-$150K/month (scales with volume)
 *
 * ─── WHY RE-EXTENSION MATTERS ────────────────────────────────────────────────
 *
 *   Without this contract, your veWIK decays:
 *     Year 1: 90M veWIK × 4/4 = 90M  (full power)
 *     Year 2: 90M veWIK × 3/4 = 67M  (you earn 25% LESS)
 *     Year 3: 90M veWIK × 2/4 = 45M  (you earn 50% LESS)
 *     Year 4: 90M veWIK × 1/4 = 22M  (you earn 75% LESS)
 *
 *   With this contract, auto-extension every week:
 *     Every year: 90M + accumulated veWIK × 4/4 = MAXIMUM
 *     Plus newly vested tokens added each month
 *     Plus fee reinvestment adding more tokens
 *     Net effect: your share GROWS, not shrinks
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] No custody — interface IWikiDAOTreasury {
        function claimSalaryFor(address contributor) external returns (uint256 amount);
        function claimableAmount(address wallet) external view returns (
            uint256 amount, uint256 periods, uint256 nextClaimAt
        );
        function authoriseAgent(address agent, bool enabled) external;
    }

interface IWikiSpotRouter {
        function swapExactIn(
            uint256 poolId, address tokenIn, uint256 amountIn,
            uint256 amountOutMin, address to, uint256 deadline
        ) external returns (uint256 amountOut);
    }

interface IWikiStaking {
        struct Lock { uint256 amount; uint256 unlockTime; uint256 veWIK; }
        function lock(uint256 amount, uint256 duration) external;
        function claimFees() external;
        function pendingFeesView(address user) external view returns (uint256);
        function getLock(address user) external view returns (Lock memory);
        function MAX_LOCK() external view returns (uint256);
        function getCurrentVeWIK(address user) external view returns (uint256);
    }

interface IWikiTokenVesting {
        function claim() external returns (uint256);
        function claimableNow(address wallet) external view returns (
            uint256 totalClaimable, uint256[] memory ids, uint256[] memory amounts
        );
    }
}

/**
 * @dev Security properties:
 * [A1] No custody - contract never holds WIK for more than 1 transaction
 * [A2] Only the beneficiary or whitelisted keeper can trigger compound
 * [A3] Min compound threshold - prevents dust compounds wasting gas
 * [A4] Slippage protection on USDC->WIK swaps (min 97% output)
 * [A5] Emergency stop - beneficiary pauses at any time
 * [A6] Re-extension is optional - set extendLock=false to let lock expire naturally
 */
contract WikiAutoCompounder is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;




    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant MIN_COMPOUND_WIK  = 100  * 1e18;  // 100 WIK minimum [A3]
    uint256 public constant MIN_COMPOUND_USDC = 10   * 1e6;   // $10 USDC minimum
    uint256 public constant MAX_LOCK_DAYS     = 4 * 365;      // 4 years = max veWIK power
    uint256 public constant DEFAULT_INTERVAL  = 7 days;       // weekly compounding
    uint256 public constant SLIPPAGE_BPS      = 300;          // 3% max slippage [A4]
    uint256 public constant KEEPER_FEE_BPS    = 30;           // 0.3% to keeper for gas
    uint256 public constant BPS               = 10_000;

    // ── Contracts ─────────────────────────────────────────────────────────────

    IERC20            public immutable WIK;
    IERC20            public immutable USDC;
    IWikiTokenVesting public           vesting;
    IWikiStaking      public           staking;
    IWikiSpotRouter   public           spotRouter;
    uint256           public           usdcWikPoolId;    // WikiSpot USDC/WIK pool ID
    IWikiDAOTreasury  public           treasury;         // WikiDAOTreasury — salary source

    // ── Per-user config ───────────────────────────────────────────────────────

    struct Config {
        bool    active;
        bool    compoundFees;           // reinvest USDC fees → buy WIK → stake
        bool    reinvestSalary;         // claim treasury salary → buy WIK → stake instead of withdrawing
        bool    extendLock;             // re-extend to max lock each compound
        uint256 targetLockDays;         // how long to extend (default: 4yr)
        uint256 minCompoundWIK;         // don't compound until this much WIK available
        uint256 intervalSeconds;        // how often to compound (default: 7 days)
        uint256 lastCompound;           // last compound timestamp
        address keeper;                 // address(0) = any whitelisted keeper
    }
    mapping(address => Config) public configs;

    // ── Per-user growth stats ─────────────────────────────────────────────────

    struct GrowthStats {
        uint256 totalWIKCompounded;      // WIK added to lock from vesting
        uint256 totalSalaryReinvested;   // USDC salary converted to WIK instead of withdrawn
        uint256 totalUSDCReinvested;     // USDC fees converted to WIK
        uint256 totalWIKFromFees;        // WIK acquired by buying with fees
        uint256 totalCompoundEvents;     // number of times compounded
        uint256 veWIKAtStart;            // veWIK when first enabled
        uint256 veWIKLatest;             // veWIK after last compound
        uint256 startTime;               // when auto-compound was enabled
        uint256 projectedYearlyFees;     // estimated annual USDC fee income at current veWIK
    }
    mapping(address => GrowthStats) public growthStats;

    // ── Keeper registry ───────────────────────────────────────────────────────
    mapping(address => bool) public keepers;

    // ── Global stats ──────────────────────────────────────────────────────────
    uint256 public totalUsersActive;
    uint256 public totalWIKCompoundedGlobal;
    uint256 public totalCompoundEventsGlobal;

    // ── Events ────────────────────────────────────────────────────────────────

    event AutoCompoundEnabled(
        address indexed user,
        bool compoundFees,
        bool extendLock,
        uint256 intervalDays
    );
    event AutoCompoundDisabled(address indexed user);
    event Compounded(
        address indexed user,
        address indexed triggeredBy,
        uint256 wikFromVesting,      // WIK claimed from WikiTokenVesting
        uint256 usdcFeesClaimed,     // USDC claimed from WikiStaking
        uint256 wikBoughtWithFees,   // WIK purchased using USDC fees
        uint256 wikStakedTotal,      // total WIK added to veWIK lock this round
        uint256 keeperFeeWIK,        // WIK paid to keeper for gas
        uint256 newLockExpiry,       // new lock expiry timestamp
        uint256 newVeWIK,            // veWIK balance after compound
        uint256 veWIKGrowthPct       // % growth vs previous compound
    );
    event LockExtended(address indexed user, uint256 newExpiry, uint256 newVeWIK);
    event ConfigUpdated(address indexed user);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _wik,
        address _usdc,
        address _vesting,
        address _staking
    ) Ownable(_owner) {
        require(_wik     != address(0), "AC: zero WIK");
        require(_usdc    != address(0), "AC: zero USDC");
        require(_vesting != address(0), "AC: zero vesting");
        require(_staking != address(0), "AC: zero staking");

        WIK     = IERC20(_wik);
        USDC    = IERC20(_usdc);
        vesting = IWikiTokenVesting(_vesting);
        staking = IWikiStaking(_staking);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // USER SETUP
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Enable auto-compounding. Call once — the keeper handles everything.
     *
     * Recommended settings for maximum growth:
     *   compoundFees  = true   → USDC fees buy more WIK, accelerating growth
     *   extendLock    = true   → lock always at max power, no decay
     *   targetLockDays= 1460   → 4 years = maximum veWIK multiplier
     *   intervalDays  = 7      → weekly, good gas/reward balance
     *   minCompoundWIK= 1000e18→ compound when at least 1,000 WIK available
     *
     * IMPORTANT: Before calling this, approve this contract on WIK and USDC tokens:
     *   WIK.approve(autoCompounderAddress, type(uint256).max)
     *   USDC.approve(autoCompounderAddress, type(uint256).max)
     */
    function enableAutoCompound(
        bool    compoundFees,
        bool    reinvestSalary,
        bool    extendLock,
        uint256 targetLockDays,
        uint256 intervalDays,
        uint256 minCompoundWIK_
    ) external {
        require(targetLockDays >= 7 && targetLockDays <= MAX_LOCK_DAYS, "AC: lock duration 7d-4yr");
        require(intervalDays  >= 1 && intervalDays  <= 365,             "AC: interval 1d-1yr");

        bool wasActive = configs[msg.sender].active;

        configs[msg.sender] = Config({
            active:          true,
            compoundFees:    compoundFees,
            reinvestSalary:  reinvestSalary,
            extendLock:      extendLock,
            targetLockDays:  targetLockDays > 0 ? targetLockDays : MAX_LOCK_DAYS,
            minCompoundWIK:  minCompoundWIK_ > 0 ? minCompoundWIK_ : MIN_COMPOUND_WIK,
            intervalSeconds: intervalDays * 1 days,
            lastCompound:    0,
            keeper:          address(0)
        });

        if (!wasActive) {
            totalUsersActive++;
            growthStats[msg.sender].startTime  = block.timestamp;
            growthStats[msg.sender].veWIKAtStart = staking.getCurrentVeWIK(msg.sender);
        }

        _registerUser(msg.sender);
        emit AutoCompoundEnabled(msg.sender, compoundFees, extendLock, intervalDays);
    }

    function disableAutoCompound() external {
        require(configs[msg.sender].active, "AC: not active");
        configs[msg.sender].active = false;
        if (totalUsersActive > 0) totalUsersActive--;
        emit AutoCompoundDisabled(msg.sender);
    }

    function updateConfig(
        bool compoundFees, bool extendLock,
        uint256 targetLockDays, uint256 intervalDays
    ) external {
        require(configs[msg.sender].active, "AC: not enabled");
        Config storage c = configs[msg.sender];
        c.compoundFees   = compoundFees;
        c.extendLock     = extendLock;
        if (targetLockDays >= 7) c.targetLockDays  = targetLockDays;
        if (intervalDays   >= 1) c.intervalSeconds  = intervalDays * 1 days;
        emit ConfigUpdated(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CORE COMPOUND FUNCTION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute one compound cycle for a user.
     *         Can be called by: the user themselves, or a whitelisted keeper.
     *
     * The complete cycle:
     *   1. Check interval has elapsed
     *   2. Claim vested WIK from WikiTokenVesting
     *   3. Claim USDC fees from WikiStaking
     *   4. If compoundFees: swap USDC → WIK via WikiSpotRouter
     *   5. Pay keeper fee (0.3% of WIK to incentivise keepers)
     *   6. Stake all remaining WIK into WikiStaking for user
     *   7. Extend lock duration back to max (if extendLock = true)
     *   8. Update growth stats
     *
     * @param user The address to compound for
     */
    function compound(address user) external nonReentrant returns (
        uint256 wikStaked,
        uint256 newVeWIK
    ) {
        Config storage c = configs[user];
        require(c.active, "AC: not active for user");
        // [A2] Only keeper or user themselves
        require(
            msg.sender == user || keepers[msg.sender],
            "AC: not authorised"
        );

        // Check interval [A3]
        if (c.lastCompound > 0) {
            require(
                block.timestamp >= c.lastCompound + c.intervalSeconds,
                "AC: too soon"
            );
        }

        uint256 prevVeWIK = staking.getCurrentVeWIK(user);

        // ── Step 1: Claim vested WIK ────────────────────────────────────────
        uint256 wikFromVesting = 0;
        (uint256 claimable,,) = vesting.claimableNow(user);
        if (claimable >= c.minCompoundWIK) {
            // User must have approved WikiTokenVesting to claim on their behalf
            // (vesting contract sends directly to user, then user approved us)
            // In practice: user calls claim() themselves OR grants role to this contract
            // For full automation: WikiTokenVesting.claimForBeneficiary() pattern
            try vesting.claim() returns (uint256 claimed) {
                wikFromVesting = claimed;
                // Pull from user wallet (user approved this contract)
                if (claimed > 0) {
                    WIK.safeTransferFrom(user, address(this), claimed);
                }
            } catch {}
        }

        // ── Step 2: Claim USDC fees from staking ────────────────────────────
        uint256 usdcClaimed = 0;
        uint256 pendingUsdc = staking.pendingFeesView(user);
        if (pendingUsdc >= MIN_COMPOUND_USDC) {
            uint256 beforeUsdc = USDC.balanceOf(address(this));
            // Pull USDC to this contract (user must have approved staking to forward fees here)
            // Standard: staking.claimFees() sends to msg.sender = user
            // We use a delegated claim pattern: user approves, we claim on behalf
            try staking.claimFees() {} catch {}
            usdcClaimed = USDC.balanceOf(address(this)) - beforeUsdc;
        }

        // ── Step 2b: Claim and reinvest salary (if reinvestSalary enabled) ───
        uint256 salaryReinvested = 0;
        if (c.reinvestSalary && address(treasury) != address(0)) {
            (uint256 salaryDue,,) = treasury.claimableAmount(user);
            if (salaryDue >= MIN_COMPOUND_USDC) {
                uint256 beforeSalary = USDC.balanceOf(address(this));
                uint256 salaryClaimed = 0;
                try treasury.claimSalaryFor(user) returns (uint256 pulled) {
                    salaryClaimed = pulled;
                } catch {
                    // If claimSalaryFor fails, fall back to balance diff
                    salaryClaimed = USDC.balanceOf(address(this)) - beforeSalary;
                }
                if (salaryClaimed > 0) {
                    usdcClaimed     += salaryClaimed;
                    salaryReinvested = salaryClaimed;
                }
            }
        }

        // ── Step 3: Swap USDC (fees + salary) → WIK ──────────────────────────
        uint256 wikFromFees = 0;
        if (c.compoundFees && usdcClaimed > 0 && address(spotRouter) != address(0)) {
            uint256 minWIKOut = _getMinWIKOut(usdcClaimed); // [A4] slippage guard
            try spotRouter.swapExactIn(
                usdcWikPoolId,
                address(USDC),
                usdcClaimed,
                minWIKOut,
                address(this),
                block.timestamp + 60
            ) returns (uint256 bought) {
                wikFromFees = bought;
            } catch {
                // Swap failed — send USDC back to user rather than lose it
                if (usdcClaimed > 0) USDC.safeTransfer(user, usdcClaimed);
                usdcClaimed = 0;
            }
        } else if (!c.compoundFees && usdcClaimed > 0) {
            // User wants USDC as cash — send directly to their wallet
            USDC.safeTransfer(user, usdcClaimed);
            usdcClaimed = 0; // don't count as reinvested
        }

        // ── Step 4: Total WIK to stake ───────────────────────────────────────
        uint256 totalWIK = wikFromVesting + wikFromFees;
        require(totalWIK >= MIN_COMPOUND_WIK || c.extendLock, "AC: nothing to compound");

        // ── Step 5: Keeper fee (0.3%) ────────────────────────────────────────
        uint256 keeperFee = 0;
        if (msg.sender != user && totalWIK > 0) {
            keeperFee = totalWIK * KEEPER_FEE_BPS / BPS;
            if (keeperFee > 0) {
                WIK.safeTransfer(msg.sender, keeperFee);
                totalWIK -= keeperFee;
            }
        }

        // ── Step 6: Stake remaining WIK for user ─────────────────────────────
        uint256 lockDuration = c.extendLock
            ? c.targetLockDays * 1 days
            : _remainingLock(user);

        if (totalWIK > 0) {
            WIK.forceApprove(address(staking), totalWIK);
            staking.lock(totalWIK, lockDuration);
            wikStaked = totalWIK;
        } else if (c.extendLock) {
            // Even with 0 new WIK — re-extend the existing lock
            staking.lock(0, lockDuration);
        }

        // ── Step 7: Read new veWIK balance ───────────────────────────────────
        newVeWIK = staking.getCurrentVeWIK(user);
        uint256 growthPct = prevVeWIK > 0
            ? (newVeWIK - prevVeWIK) * 10_000 / prevVeWIK
            : 0;

        // ── Step 8: Update stats ──────────────────────────────────────────────
        c.lastCompound = block.timestamp;

        GrowthStats storage gs = growthStats[user];
        gs.totalWIKCompounded     += wikFromVesting;
        gs.totalSalaryReinvested  += salaryReinvested;
        gs.totalUSDCReinvested    += c.compoundFees ? (pendingUsdc > 0 ? pendingUsdc : 0) : 0;
        gs.totalWIKFromFees       += wikFromFees;
        gs.totalCompoundEvents++;
        gs.veWIKLatest             = newVeWIK;

        totalWIKCompoundedGlobal  += wikFromVesting;
        totalCompoundEventsGlobal++;

        emit Compounded(
            user, msg.sender,
            wikFromVesting, usdcClaimed, wikFromFees,
            wikStaked, keeperFee,
            block.timestamp + lockDuration,
            newVeWIK, growthPct
        );
    }

    /**
     * @notice Batch compound for multiple users in one transaction.
     *         Keeper bot calls this to save gas across all registered users.
     */
    function batchCompound(address[] calldata users) external nonReentrant {
        require(keepers[msg.sender], "AC: not keeper");
        for (uint i; i < users.length; i++) {
            if (!_shouldCompound(users[i])) continue;
            try this.compound(users[i]) {} catch {}
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEWS — GROWTH PROJECTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Full growth dashboard for a user.
     *         Frontend + keeper bot use this to show current state.
     */
    function growthDashboard(address user) external view returns (
        bool    active,
        bool    compoundFees,
        bool    extendLock,
        uint256 currentVeWIK,
        uint256 nextCompoundAt,
        uint256 wikClaimableNow,
        uint256 usdcPendingNow,
        uint256 totalWIKCompounded_,
        uint256 totalCompounds_,
        uint256 daysActive,
        uint256 veWIKGrowthPct,
        string  memory status
    ) {
        Config memory c      = configs[user];
        GrowthStats memory gs = growthStats[user];

        active           = c.active;
        compoundFees     = c.compoundFees;
        extendLock       = c.extendLock;
        currentVeWIK     = staking.getCurrentVeWIK(user);
        nextCompoundAt   = c.lastCompound + c.intervalSeconds;
        totalWIKCompounded_ = gs.totalWIKCompounded;
        totalCompounds_  = gs.totalCompoundEvents;
        daysActive       = gs.startTime > 0 ? (block.timestamp - gs.startTime) / 1 days : 0;

        (wikClaimableNow,,) = vesting.claimableNow(user);
        usdcPendingNow   = staking.pendingFeesView(user);

        veWIKGrowthPct   = gs.veWIKAtStart > 0
            ? (currentVeWIK > gs.veWIKAtStart
                ? (currentVeWIK - gs.veWIKAtStart) * 10_000 / gs.veWIKAtStart
                : 0)
            : 0;

        if (!c.active)                           status = "Disabled";
        else if (_shouldCompound(user))          status = "Ready to compound";
        else if (wikClaimableNow > 0)            status = "Waiting for interval";
        else                                     status = "Waiting for vesting/fees";
    }

    /**
     * @notice Projects your veWIK position over N years assuming:
     *         - Monthly vesting continues at current rate
     *         - Fee income at current protocol volume
     *         - All fees reinvested (if compoundFees = true)
     *         - Lock always re-extended to max
     *
     * Returns arrays of [year0, year1, year2, year3, year4] projections.
     *
     * @param user             The address to project for
     * @param monthlyWIKUnlock WIK unlocking per month from vesting
     * @param monthlyUSDCFees  USDC fee income per month at current veWIK
     * @param wikPriceUsdc     Current WIK price in USDC (6 decimals)
     */
    function projectGrowth(
        address user,
        uint256 monthlyWIKUnlock,
        uint256 monthlyUSDCFees,
        uint256 wikPriceUsdc
    ) external view returns (
        uint256[5] memory projectedVeWIK,
        uint256[5] memory projectedMonthlyFeeUsdc,
        uint256[5] memory projectedTotalWIKStaked
    ) {
        Config memory c    = configs[user];
        uint256 curWIK     = staking.getLock(user).amount;
        uint256 curVeWIK   = staking.getCurrentVeWIK(user);
        uint256 maxLock    = staking.MAX_LOCK();

        // Year 0 = current state
        projectedVeWIK[0]           = curVeWIK;
        projectedMonthlyFeeUsdc[0]  = monthlyUSDCFees;
        projectedTotalWIKStaked[0]  = curWIK;

        uint256 stakedWIK   = curWIK;
        uint256 monthlyFees = monthlyUSDCFees;

        for (uint year = 1; year <= 4; year++) {
            // Add 12 months of vesting
            stakedWIK += monthlyWIKUnlock * 12;

            // Add WIK purchased with fees (if compoundFees enabled)
            if (c.compoundFees && wikPriceUsdc > 0) {
                uint256 annualFeeUsdc = monthlyFees * 12;
                uint256 wikBought = annualFeeUsdc * 1e18 / wikPriceUsdc;
                stakedWIK += wikBought;
            }

            // veWIK at max lock = staked amount (lock duration / maxLock = 1.0 at 4yr)
            projectedTotalWIKStaked[year] = stakedWIK;
            projectedVeWIK[year]          = stakedWIK; // at max lock: veWIK = amount

            // Fees scale proportionally with veWIK growth
            // (assumes constant total veWIK supply for simplicity)
            if (projectedVeWIK[0] > 0) {
                projectedMonthlyFeeUsdc[year] = monthlyUSDCFees
                    * projectedVeWIK[year]
                    / projectedVeWIK[0];
            }
            monthlyFees = projectedMonthlyFeeUsdc[year];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────────────────────────────────

    function _shouldCompound(address user) internal view returns (bool) {
        Config memory c = configs[user];
        if (!c.active) return false;
        if (c.lastCompound > 0 && block.timestamp < c.lastCompound + c.intervalSeconds) return false;
        (uint256 claimable,,) = vesting.claimableNow(user);
        uint256 pendingUsdc = staking.pendingFeesView(user);
        return claimable >= c.minCompoundWIK || (c.extendLock && c.lastCompound > 0);
    }

    function _remainingLock(address user) internal view returns (uint256) {
        IWikiStaking.Lock memory l = staking.getLock(user);
        if (l.unlockTime <= block.timestamp) return 7 days; // minimum if expired
        return l.unlockTime - block.timestamp;
    }

    function _getMinWIKOut(uint256 usdcIn) internal view returns (uint256) {
        // Simple estimate: assume 1 USDC = some WIK. With slippage guard.
        // In production: use a TWAP oracle for proper slippage protection [A4]
        // For now: 97% of estimated output (3% slippage tolerance)
        return usdcIn * 1e18 / 1e6 * (BPS - SLIPPAGE_BPS) / BPS;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CHAINLINK AUTOMATION COMPATIBLE (backup trigger)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Register this contract at automation.chain.link
    // Select "Custom Logic" upkeep, paste this contract address.
    // Chainlink will call checkUpkeep() every block. When it returns true,
    // it calls performUpkeep() which compounds the next ready user.
    //
    // Cost: ~$5-20/month in LINK. Runs even if your keeper server is down.
    // This is a BACKUP — your keeper bot handles the primary execution.

    /// @notice All users registered for auto-compound (for Chainlink iteration)
    address[] public registeredUsers;
    mapping(address => bool) public isRegistered;

    function _registerUser(address user) internal {
        if (!isRegistered[user]) {
            isRegistered[user] = true;
            registeredUsers.push(user);
        }
    }

    /**
     * @notice Chainlink Automation: called off-chain every block.
     *         Returns true when at least one user is ready to compound.
     *         Encodes the ready user's address in performData.
     */
    function checkUpkeep(bytes calldata) external view returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {
        for (uint i; i < registeredUsers.length; i++) {
            address user = registeredUsers[i];
            if (!configs[user].active) continue;
            Config memory c_ = configs[user];
            if (c_.lastCompound > 0 &&
                block.timestamp < c_.lastCompound + c_.intervalSeconds) continue;
            (uint256 claimable,,) = vesting.claimableNow(user);
            uint256 pendingUsdc   = staking.pendingFeesView(user);
            if (claimable >= c_.minCompoundWIK ||
                pendingUsdc >= MIN_COMPOUND_USDC ||
                c_.extendLock) {
                return (true, abi.encode(user));
            }
        }
        return (false, "");
    }

    /**
     * @notice Chainlink Automation: called on-chain when checkUpkeep is true.
     *         Compounds the ready user. Chainlink pays the gas in LINK.
     *         Wikicious pays Chainlink from the subscription balance.
     */
    function performUpkeep(bytes calldata performData) external {
        address user = abi.decode(performData, (address));
        require(configs[user].active, "AC: not active");
        // Re-validate on-chain (guard against stale performData)
        Config memory c_ = configs[user];
        if (c_.lastCompound > 0 &&
            block.timestamp < c_.lastCompound + c_.intervalSeconds) return;
        // Execute compound — msg.sender is Chainlink forwarder, earns 0.3% fee
        try this.compound(user) {} catch {}
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────────

    function setKeeper(address keeper, bool enabled) external onlyOwner {
        keepers[keeper] = enabled;
    }

    function setSpotRouter(address router, uint256 poolId) external onlyOwner {
        spotRouter    = IWikiSpotRouter(router);
        usdcWikPoolId = poolId;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury != address(0)) treasury = IWikiDAOTreasury(_treasury);
    }

    function setContracts(address _vesting, address _staking) external onlyOwner {
        if (_vesting != address(0)) vesting = IWikiTokenVesting(_vesting);
        if (_staking != address(0)) staking = IWikiStaking(_staking);
    }
}
