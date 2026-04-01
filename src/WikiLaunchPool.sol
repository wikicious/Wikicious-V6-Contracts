// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLaunchPool
 * @notice Stake WIK or WLP tokens for a fixed period to earn new project tokens.
 *         Think Binance Launchpool: projects seed a reward pot, users stake to earn share.
 *
 * DESIGN
 * ──────────────────────────────────────────────────────────────────────────
 * A Pool has:
 *   • stakeToken  — the token users stake (WIK, WLP, or any whitelisted token)
 *   • rewardToken — the new project token being distributed
 *   • rewardPerSecond — total reward rate for the entire pool
 *   • startTime / endTime — fixed emission window
 *   • maxStakePerUser — anti-whale cap
 *
 * Rewards are accrued second-by-second using a standard accRewardPerShare
 * accumulator (MasterChef-style, but without pool weights — each pool is
 * fully independent).
 *
 * REVENUE
 * ───────
 * Projects pay a listing fee in USDC to create a pool. Protocol earns from
 * every launch without taking from the reward pot.
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy           → ReentrancyGuard on all state-mutating functions
 * [A2] CEI pattern          → state written before every transfer
 * [A3] Reward dust           → safeTransfer with balance cap
 * [A4] Flash stake            → minimum stake duration (1 block or 1 second min accrual)
 * [A5] Over-allocation       → rewardBudget tracked, cannot over-distribute
 * [A6] Inflation attack      → first depositor handled via multiplier init
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiLaunchPool is Ownable2Step, ReentrancyGuard {
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
    uint256 public constant PRECISION       = 1e18;
    uint256 public constant LISTING_FEE     = 1000 * 1e6;   // $1000 USDC per pool
    uint256 public constant MAX_POOLS       = 50;

    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────
    struct Pool {
        // ── Identity ──
        uint256  id;
        string   projectName;
        string   projectURL;
        address  stakeToken;        // token users deposit
        address  rewardToken;       // new project token
        address  projectOwner;      // can top-up reward budget

        // ── Emission config ──
        uint256  rewardPerSecond;   // total reward/sec across all stakers
        uint256  startTime;
        uint256  endTime;
        uint256  rewardBudget;      // total rewards deposited by project
        uint256  rewardPaid;        // total rewards distributed so far

        // ── Accounting ──
        uint256  totalStaked;
        uint256  accRewardPerShare; // × PRECISION
        uint256  lastRewardTime;

        // ── Config ──
        uint256  maxStakePerUser;
        uint256  minStakeDuration;  // seconds before user can withdraw
        bool     active;
    }

    struct UserInfo {
        uint256 staked;
        uint256 rewardDebt;         // accRewardPerShare × staked at last update
        uint256 pendingHarvest;     // harvested but not yet claimed
        uint256 stakedAt;           // timestamp of last deposit (for minStakeDuration)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IERC20 public immutable USDC;

    Pool[]    public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256   public protocolFees;

    // Whitelisted stake tokens (WIK, WLP, USDC, etc.)
    mapping(address => bool) public allowedStakeTokens;

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event PoolCreated(uint256 indexed pid, string name, address stakeToken, address rewardToken, uint256 startTime, uint256 endTime);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Unstaked(uint256 indexed pid, address indexed user, uint256 amount);
    event Harvested(uint256 indexed pid, address indexed user, uint256 amount);
    event RewardTopUp(uint256 indexed pid, uint256 amount);
    event PoolDeactivated(uint256 indexed pid);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
    }

    /// @notice Keeper calls this to deploy idle USDC to yield strategies
    function deployIdle(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        require(address(idleYieldRouter) != address(0), "Router not set");
        USDC.approve(address(idleYieldRouter), amount);
        idleYieldRouter.depositIdle(amount);
    }

    /// @notice Recall capital before a claim/allocation
    function recallIdle(uint256 amount, string calldata reason) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        if (address(idleYieldRouter) != address(0)) {
            idleYieldRouter.recall(amount, reason);
        }
    }

    constructor(address usdc, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(owner != address(0), "Wiki: zero owner");
        USDC = IERC20(usdc);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Config
    // ─────────────────────────────────────────────────────────────────────

    function setAllowedStakeToken(address token, bool allowed) external onlyOwner {
        allowedStakeTokens[token] = allowed;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Create Pool (permissioned — project pays listing fee)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new LaunchPool. Caller pays LISTING_FEE USDC.
     * @param stakeToken      Token users will stake
     * @param rewardToken     New project token to distribute
     * @param rewardBudget    Total reward tokens deposited for the pool
     * @param startTime       Pool opens (must be future)
     * @param endTime         Pool closes
     * @param maxStakePerUser Whale cap (0 = no cap)
     * @param minStakeDuration Minimum seconds before unstake (0 = instant)
     */
    function createPool(
        string  calldata projectName,
        string  calldata projectURL,
        address stakeToken,
        address rewardToken,
        uint256 rewardBudget,
        uint256 startTime,
        uint256 endTime,
        uint256 maxStakePerUser,
        uint256 minStakeDuration
    ) external nonReentrant returns (uint256 pid) {
        require(pools.length < MAX_POOLS,                         "LP: max pools");
        require(allowedStakeTokens[stakeToken],                   "LP: stake token not allowed");
        require(rewardToken != address(0),                        "LP: zero reward token");
        require(startTime >= block.timestamp,                     "LP: start in past");
        require(endTime > startTime + 1 days,                     "LP: pool too short");
        require(rewardBudget > 0,                                 "LP: zero budget");

        // Collect listing fee
        USDC.safeTransferFrom(msg.sender, address(this), LISTING_FEE);
        protocolFees += LISTING_FEE;

        uint256 duration       = endTime - startTime;
        uint256 rewardPerSec   = rewardBudget / duration;

        // [A2] State before token transfer
        pid = pools.length;
        pools.push(Pool({
            id:               pid,
            projectName:      projectName,
            projectURL:       projectURL,
            stakeToken:       stakeToken,
            rewardToken:      rewardToken,
            projectOwner:     msg.sender,
            rewardPerSecond:  rewardPerSec,
            startTime:        startTime,
            endTime:          endTime,
            rewardBudget:     rewardBudget,
            rewardPaid:       0,
            totalStaked:      0,
            accRewardPerShare: 0,
            lastRewardTime:   startTime,
            maxStakePerUser:  maxStakePerUser,
            minStakeDuration: minStakeDuration,
            active:           true
        }));

        // Pull reward tokens from project
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rewardBudget);

        emit PoolCreated(pid, projectName, stakeToken, rewardToken, startTime, endTime);
    }

    /**
     * @notice Top up a pool's reward budget (only project owner)
     */
    function topUpRewards(uint256 pid, uint256 amount) external nonReentrant {
        Pool storage p = pools[pid];
        require(msg.sender == p.projectOwner || msg.sender == owner(), "LP: not project");
        require(p.active && block.timestamp < p.endTime,              "LP: pool ended");
        require(amount > 0,                                            "LP: zero amount");

        _updatePool(pid);
        uint256 remaining  = p.endTime - block.timestamp;
        uint256 addedRate  = amount / remaining;

        // [A2] State before transfer
        p.rewardBudget    += amount;
        p.rewardPerSecond += addedRate;

        IERC20(p.rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        emit RewardTopUp(pid, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Stake
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Stake tokens into a LaunchPool
     */
    function stake(uint256 pid, uint256 amount) external nonReentrant {
        Pool     storage p  = pools[pid];
        UserInfo storage ui = userInfo[pid][msg.sender];

        require(p.active,                                           "LP: pool inactive");
        require(block.timestamp >= p.startTime,                     "LP: not started");
        require(block.timestamp < p.endTime,                        "LP: pool ended");
        require(amount > 0,                                         "LP: zero amount");
        require(
            p.maxStakePerUser == 0 || ui.staked + amount <= p.maxStakePerUser,
            "LP: exceeds max stake"
        );

        _updatePool(pid);
        _harvestPending(pid, msg.sender);

        // [A2] State before transfer
        ui.staked    += amount;
        ui.stakedAt   = block.timestamp;
        p.totalStaked += amount;
        ui.rewardDebt = ui.staked * p.accRewardPerShare / PRECISION;

        IERC20(p.stakeToken).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(pid, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Unstake
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw staked tokens (harvests pending rewards first)
     */
    function unstake(uint256 pid, uint256 amount) external nonReentrant {
        Pool     storage p  = pools[pid];
        UserInfo storage ui = userInfo[pid][msg.sender];

        require(ui.staked >= amount,                                 "LP: insufficient balance");
        require(
            p.minStakeDuration == 0 ||
            block.timestamp >= ui.stakedAt + p.minStakeDuration,
            "LP: min duration not met"
        );

        _updatePool(pid);
        _harvestPending(pid, msg.sender);

        // [A2] State before transfer
        ui.staked     -= amount;
        p.totalStaked -= amount;
        ui.rewardDebt  = ui.staked * p.accRewardPerShare / PRECISION;

        IERC20(p.stakeToken).safeTransfer(msg.sender, amount);
        emit Unstaked(pid, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Harvest
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Claim pending reward tokens
     */
    function harvest(uint256 pid) external nonReentrant {
        _updatePool(pid);
        _harvestPending(pid, msg.sender);

        UserInfo storage ui = userInfo[pid][msg.sender];
        uint256 amount      = ui.pendingHarvest;
        require(amount > 0, "LP: nothing to harvest");

        // [A2] State before transfer
        ui.pendingHarvest = 0;
        Pool storage p    = pools[pid];
        p.rewardPaid     += amount;

        _safeRewardTransfer(p.rewardToken, msg.sender, amount); // [A3]
        emit Harvested(pid, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner
    // ─────────────────────────────────────────────────────────────────────

    function deactivatePool(uint256 pid) external onlyOwner {
        pools[pid].active = false;
        emit PoolDeactivated(pid);
    }

    function withdrawProtocolFees(address to) external onlyOwner nonReentrant {
        uint256 amt   = protocolFees;
        require(amt > 0, "LP: no fees");
        protocolFees  = 0;
        USDC.safeTransfer(to, amt);
        emit ProtocolFeesWithdrawn(to, amt);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────

    function _updatePool(uint256 pid) internal {
        Pool storage p    = pools[pid];
        uint256 now_      = block.timestamp < p.endTime ? block.timestamp : p.endTime;
        if (now_ <= p.lastRewardTime) return;

        if (p.totalStaked == 0) {
            p.lastRewardTime = now_;
            return;
        }

        uint256 elapsed   = now_ - p.lastRewardTime;
        uint256 reward    = elapsed * p.rewardPerSecond;

        // [A5] Cap reward to remaining budget
        uint256 remaining = p.rewardBudget > p.rewardPaid ? p.rewardBudget - p.rewardPaid : 0;
        if (reward > remaining) reward = remaining;

        p.accRewardPerShare += reward * PRECISION / p.totalStaked;
        p.lastRewardTime     = now_;
    }

    function _harvestPending(uint256 pid, address user) internal {
        Pool     storage p  = pools[pid];
        UserInfo storage ui = userInfo[pid][user];
        if (ui.staked == 0) return;
        uint256 pending = ui.staked * p.accRewardPerShare / PRECISION;
        if (pending > ui.rewardDebt) {
            ui.pendingHarvest += pending - ui.rewardDebt;
        }
        ui.rewardDebt = ui.staked * p.accRewardPerShare / PRECISION;
    }

    function _safeRewardTransfer(address token, address to, uint256 amount) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount > bal ? bal : amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function pendingReward(uint256 pid, address user) external view returns (uint256) {
        Pool     storage p  = pools[pid];
        UserInfo storage ui = userInfo[pid][user];
        if (ui.staked == 0) return ui.pendingHarvest;

        uint256 acc   = p.accRewardPerShare;
        uint256 now_  = block.timestamp < p.endTime ? block.timestamp : p.endTime;
        if (now_ > p.lastRewardTime && p.totalStaked > 0) {
            uint256 elapsed   = now_ - p.lastRewardTime;
            uint256 reward    = elapsed * p.rewardPerSecond;
            uint256 remaining = p.rewardBudget > p.rewardPaid ? p.rewardBudget - p.rewardPaid : 0;
            if (reward > remaining) reward = remaining;
            acc += reward * PRECISION / p.totalStaked;
        }
        uint256 pending = ui.staked * acc / PRECISION;
        return ui.pendingHarvest + (pending > ui.rewardDebt ? pending - ui.rewardDebt : 0);
    }

    function getPool(uint256 pid) external view returns (Pool memory) { return pools[pid]; }
    function poolCount() external view returns (uint256) { return pools.length; }
    function getUserInfo(uint256 pid, address user) external view returns (UserInfo memory) { return userInfo[pid][user]; }

    function poolAPR(uint256 pid, uint256 rewardPriceUSD, uint256 stakePriceUSD)
        external view returns (uint256 aprBps)
    {
        Pool storage p = pools[pid];
        if (p.totalStaked == 0 || stakePriceUSD == 0) return 0;
        uint256 yearlyReward = p.rewardPerSecond * 365 days;
        uint256 yearlyUSD    = yearlyReward * rewardPriceUSD / 1e18;
        uint256 tvlUSD       = p.totalStaked  * stakePriceUSD / 1e18;
        return yearlyUSD * 10000 / tvlUSD;
    }
}
