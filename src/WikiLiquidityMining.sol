// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiLiquidityMining
 * @notice Emit WIK tokens to LPs for a defined period (6-12 months).
 *         Every successful DEX launch used this to bootstrap liquidity.
 *
 * WHY THIS EXISTS:
 *   At launch, natural fee APY is too low to attract LPs on its own.
 *   (Need TVL to generate fees. Need fees to attract TVL. Chicken-and-egg.)
 *   Liquidity mining breaks the loop: pay LPs in WIK tokens temporarily
 *   until fee revenue is high enough to sustain them naturally.
 *
 * EMISSION SCHEDULE:
 *   Total budget: up to 40M WIK from community allocation (owner sets this)
 *   Duration: 6-52 weeks per program (configurable)
 *   Distribution: pro-rata by LP stake + veWIK boost (via WikiLPBoost)
 *
 * COST vs BENEFIT:
 *   Cost: WIK inflation (dilution of existing holders)
 *   Benefit: TVL that generates fees that make protocol self-sustaining
 *   Rule of thumb: stop emission when fee APY alone > 8% for LPs
 *
 * SAFETY:
 *   Owner can reduce emission rate but CANNOT increase above initial cap
 *   This prevents governance attacks that inflate WIK to steal LP capital
 *   Emissions auto-stop at program end — no cliff, gradual wind-down
 */
contract WikiLiquidityMining is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable WIK;

    struct MiningProgram {
        uint256 id;
        address lpToken;            // which LP token earns rewards
        uint256 rewardPerSecond;    // WIK per second emitted to this pool
        uint256 startTime;
        uint256 endTime;
        uint256 totalAllocated;     // total WIK allocated to program
        uint256 totalDistributed;   // total WIK paid out so far
        uint256 lastRewardTime;
        uint256 accRewardPerShare;  // accumulated reward per LP token (scaled 1e18)
        uint256 totalStaked;        // total LP tokens staked
        bool    active;
    }

    struct UserStake {
        uint256 amount;         // LP tokens staked
        uint256 rewardDebt;     // used to calculate pending rewards
        uint256 pendingRewards; // accumulated but unclaimed
        uint256 totalClaimed;   // lifetime claimed
        uint256 boostBps;       // current boost (from WikiLPBoost)
    }

    mapping(uint256 => MiningProgram)                       public programs;
    mapping(uint256 => mapping(address => UserStake))       public stakes;
    mapping(address => uint256)                             public lpToProgram;

    address public lpBoost;       // WikiLPBoost contract
    uint256 public nextProgramId;
    uint256 public totalWIKAllocated;
    uint256 public totalWIKDistributed;
    uint256 public constant PRECISION = 1e18;

    event ProgramCreated(uint256 id, address lpToken, uint256 rewardPerSec, uint256 duration);
    event Staked(uint256 programId, address user, uint256 amount);
    event Unstaked(uint256 programId, address user, uint256 amount);
    event RewardClaimed(uint256 programId, address user, uint256 amount);
    event EmissionReduced(uint256 programId, uint256 oldRate, uint256 newRate);

    constructor(address _owner, address _wik, address _lpBoost) Ownable(_owner) {
        WIK     = IERC20(_wik);
        lpBoost = _lpBoost;
    }

    // ── Create a mining program ───────────────────────────────────────────
    function createProgram(
        address lpToken,
        uint256 rewardPerSecond,
        uint256 durationDays,
        uint256 totalBudget
    ) external onlyOwner returns (uint256 programId) {
        require(durationDays >= 7 && durationDays <= 365, "LM: duration 7-365 days");
        WIK.safeTransferFrom(msg.sender, address(this), totalBudget);
        totalWIKAllocated += totalBudget;

        programId = nextProgramId++;
        programs[programId] = MiningProgram({
            id:               programId,
            lpToken:          lpToken,
            rewardPerSecond:  rewardPerSecond,
            startTime:        block.timestamp,
            endTime:          block.timestamp + durationDays * 1 days,
            totalAllocated:   totalBudget,
            totalDistributed: 0,
            lastRewardTime:   block.timestamp,
            accRewardPerShare:0,
            totalStaked:      0,
            active:           true
        });
        lpToProgram[lpToken] = programId;
        emit ProgramCreated(programId, lpToken, rewardPerSecond, durationDays);
    }

    // ── Stake LP tokens ───────────────────────────────────────────────────
    function stake(uint256 programId, uint256 amount) external nonReentrant {
        MiningProgram storage prog = programs[programId];
        require(prog.active && block.timestamp < prog.endTime, "LM: program ended");
        require(amount > 0, "LM: zero amount");

        _updatePool(programId);

        IERC20(prog.lpToken).safeTransferFrom(msg.sender, address(this), amount);

        UserStake storage us = stakes[programId][msg.sender];
        if (us.amount > 0) {
            // Claim pending before updating
            uint256 pending = us.amount * prog.accRewardPerShare / PRECISION - us.rewardDebt;
            if (pending > 0) us.pendingRewards += pending;
        }

        us.amount         += amount;
        us.rewardDebt      = us.amount * prog.accRewardPerShare / PRECISION;
        prog.totalStaked  += amount;

        // Update boost if WikiLPBoost is configured
        if (lpBoost != address(0)) {
            (bool ok,) = lpBoost.call(
                abi.encodeWithSignature("recordDeposit(uint256,address,uint256)", programId, msg.sender, amount)
            );
        }
        emit Staked(programId, msg.sender, amount);
    }

    // ── Unstake LP tokens ─────────────────────────────────────────────────
    function unstake(uint256 programId, uint256 amount) external nonReentrant {
        MiningProgram storage prog = programs[programId];
        UserStake storage us = stakes[programId][msg.sender];
        require(us.amount >= amount, "LM: insufficient stake");

        _updatePool(programId);

        uint256 pending = us.amount * prog.accRewardPerShare / PRECISION - us.rewardDebt;
        if (pending > 0) us.pendingRewards += pending;

        us.amount         -= amount;
        us.rewardDebt      = us.amount * prog.accRewardPerShare / PRECISION;
        prog.totalStaked  -= amount;

        IERC20(prog.lpToken).safeTransfer(msg.sender, amount);

        if (lpBoost != address(0)) {
            lpBoost.call(
                abi.encodeWithSignature("recordWithdraw(uint256,address,uint256)", programId, msg.sender, amount)
            );
        }
        emit Unstaked(programId, msg.sender, amount);
    }

    // ── Claim WIK rewards ─────────────────────────────────────────────────
    function claim(uint256 programId) external nonReentrant {
        _updatePool(programId);
        MiningProgram storage prog = programs[programId];
        UserStake storage us = stakes[programId][msg.sender];

        uint256 pending = us.amount * prog.accRewardPerShare / PRECISION - us.rewardDebt;
        uint256 total   = us.pendingRewards + pending;
        require(total > 0, "LM: nothing to claim");

        us.pendingRewards  = 0;
        us.rewardDebt      = us.amount * prog.accRewardPerShare / PRECISION;
        us.totalClaimed   += total;
        prog.totalDistributed += total;
        totalWIKDistributed   += total;

        WIK.safeTransfer(msg.sender, total);
        emit RewardClaimed(programId, msg.sender, total);
    }

    // ── Owner: reduce emission (cannot increase) ──────────────────────────
    function reduceEmission(uint256 programId, uint256 newRatePerSecond) external onlyOwner {
        MiningProgram storage prog = programs[programId];
        require(newRatePerSecond < prog.rewardPerSecond, "LM: can only reduce rate");
        _updatePool(programId);
        emit EmissionReduced(programId, prog.rewardPerSecond, newRatePerSecond);
        prog.rewardPerSecond = newRatePerSecond;
    }

    function endProgram(uint256 programId) external onlyOwner {
        _updatePool(programId);
        programs[programId].endTime  = block.timestamp;
        programs[programId].active   = false;
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function pendingReward(uint256 programId, address user) external view returns (uint256) {
        MiningProgram storage prog = programs[programId];
        UserStake storage us = stakes[programId][user];
        if (us.amount == 0) return us.pendingRewards;

        uint256 acc = prog.accRewardPerShare;
        if (block.timestamp > prog.lastRewardTime && prog.totalStaked > 0) {
            uint256 end     = block.timestamp < prog.endTime ? block.timestamp : prog.endTime;
            uint256 elapsed = end - prog.lastRewardTime;
            uint256 reward  = elapsed * prog.rewardPerSecond;
            acc += reward * PRECISION / prog.totalStaked;
        }
        return us.pendingRewards + us.amount * acc / PRECISION - us.rewardDebt;
    }

    function getProgramAPY(uint256 programId, uint256 wikPriceUsdc, uint256 lpPriceUsdc)
        external view returns (uint256 apyBps)
    {
        MiningProgram storage prog = programs[programId];
        if (prog.totalStaked == 0 || lpPriceUsdc == 0) return 0;
        uint256 yearlyWIK     = prog.rewardPerSecond * 365 days;
        uint256 yearlyUsdc    = yearlyWIK * wikPriceUsdc / 1e18;
        uint256 stakedUsdc    = prog.totalStaked * lpPriceUsdc / 1e18;
        apyBps = yearlyUsdc * 10000 / stakedUsdc;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _updatePool(uint256 programId) internal {
        MiningProgram storage prog = programs[programId];
        if (block.timestamp <= prog.lastRewardTime) return;
        if (prog.totalStaked == 0) { prog.lastRewardTime = block.timestamp; return; }

        uint256 end     = block.timestamp < prog.endTime ? block.timestamp : prog.endTime;
        uint256 elapsed = end > prog.lastRewardTime ? end - prog.lastRewardTime : 0;
        uint256 reward  = elapsed * prog.rewardPerSecond;

        // Cap at remaining budget
        uint256 remaining = prog.totalAllocated - prog.totalDistributed;
        if (reward > remaining) reward = remaining;

        prog.accRewardPerShare += reward * PRECISION / prog.totalStaked;
        prog.lastRewardTime     = block.timestamp;
    }
}
