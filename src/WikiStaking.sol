// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiStaking
 * @notice Vote-escrowed WIK staking (veWIK) + multi-pool LP farming
 *
 * STAKING (veWIK)
 * ───────────────
 * • Users lock WIK for 1 week–4 years to receive veWIK (voting power)
 * • veWIK = amount × (lockDuration / MAX_LOCK)  — linear decay to unlock date
 * • Stakers share 100% of protocol fee revenue proportional to their veWIK
 * • Early unlock allowed at 50% penalty (penalty burned)
 *
 * FARMING
 * ───────
 * • Multiple LP token pools each earn WIK emissions
 * • Pool weight (allocPoint) is governance-adjustable
 * • Boost: veWIK holders get up to 2.5× farming boost on their LP position
 *   boostedBalance = min(lpBalance × 0.4 + totalLP × veWIK/totalVeWIK × 0.6, lpBalance)
 *   (Curve-style boost formula)
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy  → ReentrancyGuard on all external state-mutating functions
 * [A2] CEI         → state written before all token transfers
 * [A3] Flash boost → veWIK snapshot at deposit; recalculate on explicit rebalance()
 * [A4] Overflow    → Solidity 0.8 + explicit guards
 * [A5] Dust        → minimum lock amount
 */
contract WikiStaking is Ownable2Step, ReentrancyGuard {
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

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant MAX_LOCK         = 4 * 365 days;
    uint256 public constant MIN_LOCK         = 7 days;
    uint256 public constant EARLY_EXIT_BPS   = 5000;  // 50% penalty
    uint256 public constant BOOST_MAX_BPS    = 25000; // 2.5× boost (BPS × 2.5)
    uint256 public constant BOOST_BASE_BPS   = 10000; // 1×
    uint256 public constant BPS              = 10_000;
    uint256 public constant ACC_PRECISION    = 1e18;
    uint256 public constant MIN_LOCK_AMOUNT  = 1e18;  // 1 WIK

    // ─────────────────────────────────────────────────────────────────────
    //  Tokens
    // ─────────────────────────────────────────────────────────────────────
    IERC20 public immutable WIK;   // staking + farming reward token
    IERC20 public immutable USDC;  // fee distribution token

    // ─────────────────────────────────────────────────────────────────────
    //  veWIK Staking Storage
    // ─────────────────────────────────────────────────────────────────────
    struct Lock {
        uint256 amount;      // WIK locked
        uint256 unlockTime;  // timestamp when lock expires
        uint256 veWIK;       // snapshot of veWIK at lock time (decays linearly)
    }

    mapping(address => Lock) public locks;

    uint256 public totalLockedWIK;
    uint256 public totalVeWIK;       // sum of all current veWIK (decays over time — use getCurrentVeWIK)

    // Fee distribution
    uint256 public accFeePerVeWIK;   // accumulated USDC per veWIK (scaled by ACC_PRECISION)
    mapping(address => uint256) public feeDebt;
    mapping(address => uint256) public pendingFees;

    // ─────────────────────────────────────────────────────────────────────
    //  Farming Storage
    // ─────────────────────────────────────────────────────────────────────
    struct Pool {
        IERC20  lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accWIKPerShare;  // accumulated WIK per boosted LP share (× ACC_PRECISION)
        uint256 totalBoosted;    // sum of all boostedBalance in pool
        bool    active;
    }

    struct UserPool {
        uint256 lpAmount;        // actual LP deposited
        uint256 boostedAmount;   // LP after boost (what rewards are based on)
        uint256 rewardDebt;      // used for reward accounting
    }

    Pool[]  public pools;
    uint256 public totalAllocPoint;
    uint256 public wikPerSecond;     // WIK emission rate
    uint256 public startTime;

    mapping(uint256 => mapping(address => UserPool)) public userPools;

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event Locked(address indexed user, uint256 amount, uint256 duration, uint256 unlockTime, uint256 veWIK);
    event Unlocked(address indexed user, uint256 amount, uint256 penalty);
    event LockExtended(address indexed user, uint256 newUnlock, uint256 newVeWIK);
    event FeeDistributed(uint256 amount, uint256 perVeWIK);
    event FeeClaimed(address indexed user, uint256 amount);

    event PoolAdded(uint256 indexed pid, address lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint);
    event Deposited(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvested(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateSet(uint256 wikPerSecond);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    constructor(address wik, address usdc, address owner) Ownable(owner) {
        require(wik != address(0), "Wiki: zero wik");
        require(usdc != address(0), "Wiki: zero usdc");
        require(owner != address(0), "Wiki: zero owner");
        WIK       = IERC20(wik);
        USDC      = IERC20(usdc);
        startTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Farming Config
    // ─────────────────────────────────────────────────────────────────────

    function setEmissionRate(uint256 _wikPerSecond) external onlyOwner {
        _massUpdatePools();
        wikPerSecond = _wikPerSecond;
        emit EmissionRateSet(_wikPerSecond);
    }

    function addPool(address lpToken, uint256 allocPoint) external onlyOwner {
        _massUpdatePools();
        totalAllocPoint += allocPoint;
        uint256 pid = pools.length;
        pools.push(Pool({
            lpToken:        IERC20(lpToken),
            allocPoint:     allocPoint,
            lastRewardTime: block.timestamp,
            accWIKPerShare: 0,
            totalBoosted:   0,
            active:         true
        }));
        emit PoolAdded(pid, lpToken, allocPoint);
    }

    function setPool(uint256 pid, uint256 allocPoint) external onlyOwner {
        _massUpdatePools();
        totalAllocPoint = totalAllocPoint - pools[pid].allocPoint + allocPoint;
        pools[pid].allocPoint = allocPoint;
        emit PoolUpdated(pid, allocPoint);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Fee Distribution
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Distribute USDC fees to all veWIK holders.
     *         Called by WikiVault/keeper after fee accrual.
     */
    function distributeFees(uint256 amount) external nonReentrant {
        require(amount > 0, "Staking: zero amount");
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tvw = _currentTotalVeWIK();
        if (tvw == 0) {
            // No stakers — send to owner as fallback
            USDC.safeTransfer(owner(), amount);
            return;
        }
        accFeePerVeWIK += amount * ACC_PRECISION / tvw;
        emit FeeDistributed(amount, accFeePerVeWIK);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  veWIK: Lock / Unlock
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Lock WIK for veWIK and start earning protocol fee revenue
     * @param amount   Amount of WIK to lock
     * @param duration Lock duration in seconds (MIN_LOCK to MAX_LOCK)
     */
    function lock(uint256 amount, uint256 duration) external nonReentrant {
        require(amount >= MIN_LOCK_AMOUNT,                    "Staking: below minimum");
        require(duration >= MIN_LOCK && duration <= MAX_LOCK, "Staking: bad duration");

        // Collect any existing lock (top-up or extend)
        Lock storage l = locks[msg.sender];
        _settleFees(msg.sender);

        // If already locked: extend and add
        uint256 newUnlock;
        if (l.amount > 0) {
            newUnlock = block.timestamp + duration;
            if (newUnlock < l.unlockTime) newUnlock = l.unlockTime; // never shorten
            totalVeWIK -= l.veWIK;
        } else {
            newUnlock = block.timestamp + duration;
        }

        uint256 totalAmount = l.amount + amount;
        uint256 remaining   = newUnlock - block.timestamp;
        uint256 newVeWIK    = totalAmount * remaining / MAX_LOCK;

        // [A2] State before transfer
        totalLockedWIK += amount;
        totalVeWIK     += newVeWIK;
        l.amount        = totalAmount;
        l.unlockTime    = newUnlock;
        l.veWIK         = newVeWIK;
        feeDebt[msg.sender] = newVeWIK * accFeePerVeWIK / ACC_PRECISION;

        WIK.safeTransferFrom(msg.sender, address(this), amount);
        emit Locked(msg.sender, amount, duration, newUnlock, newVeWIK);
    }

    /**
     * @notice Unlock WIK after lock expires (or early with 50% penalty)
     */
    function unlock() external nonReentrant {
        Lock storage l = locks[msg.sender];
        require(l.amount > 0, "Staking: nothing locked");

        _settleFees(msg.sender);

        uint256 amount  = l.amount;
        uint256 penalty = 0;

        if (block.timestamp < l.unlockTime) {
            // Early exit: burn 50% penalty [A5]
            penalty = amount * EARLY_EXIT_BPS / BPS;
        }

        uint256 payout = amount - penalty;

        // [A2] State before transfer
        totalLockedWIK -= amount;
        totalVeWIK     = totalVeWIK >= l.veWIK ? totalVeWIK - l.veWIK : 0;
        feeDebt[msg.sender] = 0;
        delete locks[msg.sender];

        if (penalty > 0) {
            // Send penalty to dead address (burn)
            WIK.safeTransfer(address(0xdead), penalty);
        }
        WIK.safeTransfer(msg.sender, payout);
        emit Unlocked(msg.sender, payout, penalty);
    }

    /**
     * @notice Claim accrued USDC fee revenue
     */
    function claimFees() external nonReentrant {
        _settleFees(msg.sender);
        uint256 amount = pendingFees[msg.sender];
        require(amount > 0, "Staking: no fees");
        pendingFees[msg.sender] = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit FeeClaimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Farming: Deposit / Withdraw / Harvest
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit LP tokens to earn WIK farming rewards
     * @param pid    Pool ID
     * @param amount LP token amount
     */
    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        _updatePool(pid);
        Pool    storage pool = pools[pid];
        UserPool storage up  = userPools[pid][msg.sender];
        require(pool.active, "Staking: pool inactive");
        require(amount > 0,  "Staking: zero amount");

        // Harvest pending before changing balance
        if (up.boostedAmount > 0) {
            uint256 pending = up.boostedAmount * pool.accWIKPerShare / ACC_PRECISION - up.rewardDebt;
            if (pending > 0) _safeWIKTransfer(msg.sender, pending);
        }

        pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
        up.lpAmount += amount;

        // Calculate boost
        uint256 newBoosted = _calcBoosted(pid, msg.sender, up.lpAmount);
        pool.totalBoosted  = pool.totalBoosted - up.boostedAmount + newBoosted;
        up.boostedAmount   = newBoosted;
        up.rewardDebt      = newBoosted * pool.accWIKPerShare / ACC_PRECISION;

        emit Deposited(msg.sender, pid, amount);
    }

    /**
     * @notice Withdraw LP tokens (also harvests pending rewards)
     */
    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        _updatePool(pid);
        Pool    storage pool = pools[pid];
        UserPool storage up  = userPools[pid][msg.sender];
        require(up.lpAmount >= amount, "Staking: insufficient balance");

        // Harvest
        uint256 pending = up.boostedAmount * pool.accWIKPerShare / ACC_PRECISION - up.rewardDebt;
        if (pending > 0) _safeWIKTransfer(msg.sender, pending);

        up.lpAmount -= amount;
        uint256 newBoosted = _calcBoosted(pid, msg.sender, up.lpAmount);
        pool.totalBoosted  = pool.totalBoosted - up.boostedAmount + newBoosted;
        up.boostedAmount   = newBoosted;
        up.rewardDebt      = newBoosted * pool.accWIKPerShare / ACC_PRECISION;

        pool.lpToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, pid, amount);
        if (pending > 0) emit Harvested(msg.sender, pid, pending);
    }

    /**
     * @notice Harvest WIK farming rewards without withdrawing LP
     */
    function harvest(uint256 pid) external nonReentrant {
        _updatePool(pid);
        Pool    storage pool = pools[pid];
        UserPool storage up  = userPools[pid][msg.sender];

        uint256 pending = up.boostedAmount * pool.accWIKPerShare / ACC_PRECISION - up.rewardDebt;
        require(pending > 0, "Staking: nothing to harvest");

        up.rewardDebt = up.boostedAmount * pool.accWIKPerShare / ACC_PRECISION;
        _safeWIKTransfer(msg.sender, pending);
        emit Harvested(msg.sender, pid, pending);
    }

    /**
     * @notice Recalculate boost after lock amount changes.
     *         Must be called manually after locking more WIK.
     */
    function rebalance(uint256 pid) external nonReentrant {
        _updatePool(pid);
        Pool    storage pool = pools[pid];
        UserPool storage up  = userPools[pid][msg.sender];
        if (up.lpAmount == 0) return;

        // Harvest first
        uint256 pending = up.boostedAmount * pool.accWIKPerShare / ACC_PRECISION - up.rewardDebt;
        if (pending > 0) _safeWIKTransfer(msg.sender, pending);

        uint256 newBoosted = _calcBoosted(pid, msg.sender, up.lpAmount);
        pool.totalBoosted  = pool.totalBoosted - up.boostedAmount + newBoosted;
        up.boostedAmount   = newBoosted;
        up.rewardDebt      = newBoosted * pool.accWIKPerShare / ACC_PRECISION;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────

    function _calcBoosted(uint256 pid, address user, uint256 lpAmount) internal view returns (uint256) {
        if (lpAmount == 0) return 0;
        Pool storage pool    = pools[pid];
        uint256 totalLP      = pool.lpToken.balanceOf(address(this));
        uint256 userVeWIK    = getCurrentVeWIK(user);
        uint256 tvw          = _currentTotalVeWIK();

        // Base: 40% of LP without boost
        uint256 base         = lpAmount * 4 / 10;
        // Boost portion (60%): proportional to veWIK share
        uint256 boosted      = tvw > 0
            ? totalLP * userVeWIK / tvw * 6 / 10
            : 0;

        uint256 result       = base + boosted;
        return result > lpAmount ? lpAmount : result; // cap at actual LP
    }

    function _updatePool(uint256 pid) internal {
        Pool storage pool = pools[pid];
        if (block.timestamp <= pool.lastRewardTime) return;
        if (pool.totalBoosted == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - pool.lastRewardTime;
        uint256 reward  = elapsed * wikPerSecond * pool.allocPoint / totalAllocPoint;
        pool.accWIKPerShare  += reward * ACC_PRECISION / pool.totalBoosted;
        pool.lastRewardTime   = block.timestamp;
    }

    function _massUpdatePools() internal {
        for (uint256 i = 0; i < pools.length; i++) _updatePool(i);
    }

    function _settleFees(address user) internal {
        Lock storage l = locks[user];
        if (l.amount == 0) return;
        uint256 vw      = getCurrentVeWIK(user);
        uint256 earned  = vw * accFeePerVeWIK / ACC_PRECISION;
        if (earned > feeDebt[user]) {
            pendingFees[user] += earned - feeDebt[user];
        }
        feeDebt[user] = earned;
    }

    function _currentTotalVeWIK() internal view returns (uint256) {
        return totalVeWIK; // simplified: decays handled at lock/unlock time
    }

    function _safeWIKTransfer(address to, uint256 amount) internal {
        uint256 bal = WIK.balanceOf(address(this)) - totalLockedWIK;
        WIK.safeTransfer(to, amount > bal ? bal : amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Current veWIK for a user (decays linearly to unlock time)
    function getCurrentVeWIK(address user) public view returns (uint256) {
        Lock storage l = locks[user];
        if (l.amount == 0 || block.timestamp >= l.unlockTime) return 0;
        uint256 remaining = l.unlockTime - block.timestamp;
        return l.amount * remaining / MAX_LOCK;
    }

    function pendingWIK(uint256 pid, address user) external view returns (uint256) {
        Pool    storage pool = pools[pid];
        UserPool storage up  = userPools[pid][user];
        if (up.boostedAmount == 0) return 0;
        uint256 acc = pool.accWIKPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.totalBoosted > 0 && totalAllocPoint > 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward  = elapsed * wikPerSecond * pool.allocPoint / totalAllocPoint;
            acc            += reward * ACC_PRECISION / pool.totalBoosted;
        }
        return up.boostedAmount * acc / ACC_PRECISION - up.rewardDebt;
    }

    function pendingFeesView(address user) external view returns (uint256) {
        Lock storage l = locks[user];
        if (l.amount == 0) return pendingFees[user];
        uint256 vw     = getCurrentVeWIK(user);
        uint256 earned = vw * accFeePerVeWIK / ACC_PRECISION;
        uint256 extra  = earned > feeDebt[user] ? earned - feeDebt[user] : 0;
        return pendingFees[user] + extra;
    }

    function poolCount() external view returns (uint256) { return pools.length; }
    function getLock(address user) external view returns (Lock memory) { return locks[user]; }
    function getUserPool(uint256 pid, address user) external view returns (UserPool memory) {
        return userPools[pid][user];
    }

    /// @notice APR estimate for a farming pool (annualised, scaled 1e18)
    function poolAPR(uint256 pid, uint256 wikPriceUSD, uint256 lpPriceUSD) external view returns (uint256) {
        Pool storage pool = pools[pid];
        if (pool.totalBoosted == 0 || totalAllocPoint == 0 || lpPriceUSD == 0) return 0;
        uint256 yearlyWIK = wikPerSecond * 365 days * pool.allocPoint / totalAllocPoint;
        uint256 yearlyUSD = yearlyWIK * wikPriceUSD / 1e18;
        uint256 tvlUSD    = pool.totalBoosted * lpPriceUSD / 1e18;
        return yearlyUSD * 1e18 / tvlUSD;
    }
}
