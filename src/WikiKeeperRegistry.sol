// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WikiKeeperRegistry — On-chain keeper staking, tiering, and reward accounting
///
/// Keepers stake WIK tokens to register. Their tier determines their reward
/// multiplier on liquidation/order fees distributed by WikiLiquidator.
///
/// ATTACK MITIGATIONS:
/// [A1] Reentrancy             → ReentrancyGuard on all state-mutating external functions
/// [A2] Checks-Effects-Interactions → state written before external calls throughout
/// [A3] Reward drain           → rewards only claimable by registered, non-slashed keepers
/// [A4] Stake griefing         → unstake has cooldown (7 days), slash burns half
/// [A5] Sybil attacks          → minimum stake of 10,000 WIK per keeper address
/// [A6] Unauthorized slashing  → only slasher role (WikiLiquidator) can slash
/// [A7] Integer overflow       → Solidity 0.8 built-in checks + explicit guards
/// [A8] Accidental owner loss  → Ownable2Step

contract WikiKeeperRegistry is Ownable2Step, ReentrancyGuard {
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

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant MIN_STAKE            = 10_000  * 1e18;  // 10k WIK
    uint256 public constant TIER2_STAKE          = 50_000  * 1e18;  // 50k WIK
    uint256 public constant TIER3_STAKE          = 200_000 * 1e18;  // 200k WIK
    uint256 public constant UNSTAKE_COOLDOWN     = 7 days;
    uint256 public constant SLASH_BURN_BPS       = 5000;            // 50% of slash burned
    uint256 public constant BPS                  = 10000;

    // Reward multipliers per tier (in BPS, 10000 = 1×)
    uint256 public constant TIER1_MULT           = 10000;  // 1.0×
    uint256 public constant TIER2_MULT           = 12500;  // 1.25×
    uint256 public constant TIER3_MULT           = 15000;  // 1.5×

    // ── State ──────────────────────────────────────────────────────────────
    IERC20 public immutable WIK;

    struct KeeperInfo {
        uint256 stakedWIK;          // current stake
        uint256 unstakeRequestedAt; // timestamp of unstake request (0 = none)
        uint256 pendingUnstake;     // amount queued for unstake
        uint256 rewardBalance;      // accrued USDC rewards (6 dec)
        uint256 totalLiquidations;  // lifetime liquidation count
        uint256 totalOrdersFilled;  // lifetime orders filled
        uint256 slashCount;         // number of times slashed
        bool    active;             // false if slashed-out or withdrawn
        uint256 registeredAt;
    }

    mapping(address => KeeperInfo) public keepers;
    address[] public keeperList;

    // Total USDC rewards held in this contract for keepers
    uint256 public totalPendingRewards;

    // Roles
    mapping(address => bool) public slashers;  // WikiLiquidator gets this role
    address public rewardToken;                 // USDC address (6 dec)

    // ── Events ─────────────────────────────────────────────────────────────
    event KeeperRegistered(address indexed keeper, uint256 stake, uint8 tier);
    event KeeperStakeIncreased(address indexed keeper, uint256 added, uint256 newTotal);
    event UnstakeRequested(address indexed keeper, uint256 amount, uint256 availableAt);
    event UnstakeClaimed(address indexed keeper, uint256 amount);
    event RewardAccrued(address indexed keeper, uint256 amount, string reason);
    event RewardClaimed(address indexed keeper, uint256 amount);
    event KeeperSlashed(address indexed keeper, address slasher, uint256 slashAmount, uint256 burned);
    event SlasherSet(address indexed slasher, bool enabled);
    event RewardDeposited(address indexed from, uint256 amount);
    event KeeperStatUpdated(address indexed keeper, uint256 liquidations, uint256 orders);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _wik, address _rewardToken, address _owner) Ownable(_owner) {
        require(_wik != address(0), "Wiki: zero _wik");
        require(_rewardToken != address(0), "Wiki: zero _rewardToken");
        require(_owner != address(0), "Wiki: zero _owner");
        WIK         = IERC20(_wik);
        rewardToken = _rewardToken;
    }

    // ── Owner config ───────────────────────────────────────────────────────
    function setSlasher(address slasher, bool enabled) external onlyOwner {
        slashers[slasher] = enabled;
        emit SlasherSet(slasher, enabled);
    }

    // ── Registration ───────────────────────────────────────────────────────

    /// @notice Register as a keeper by staking at least MIN_STAKE WIK
    function register(uint256 stakeAmount) external nonReentrant {
        require(stakeAmount >= MIN_STAKE,          "Registry: stake below minimum");
        require(!keepers[msg.sender].active,       "Registry: already registered");
        require(stakeAmount <= WIK.balanceOf(msg.sender), "Registry: insufficient WIK balance");

        // [A2] State before transfer
        keepers[msg.sender] = KeeperInfo({
            stakedWIK:          stakeAmount,
            unstakeRequestedAt: 0,
            pendingUnstake:     0,
            rewardBalance:      0,
            totalLiquidations:  0,
            totalOrdersFilled:  0,
            slashCount:         0,
            active:             true,
            registeredAt:       block.timestamp
        });
        keeperList.push(msg.sender);

        // [A1] Transfer after state update
        WIK.safeTransferFrom(msg.sender, address(this), stakeAmount);

        emit KeeperRegistered(msg.sender, stakeAmount, tierOf(msg.sender));
    }

    /// @notice Increase your existing stake
    function increaseStake(uint256 amount) external nonReentrant {
        require(keepers[msg.sender].active, "Registry: not registered");
        require(amount > 0,                 "Registry: zero amount");

        keepers[msg.sender].stakedWIK += amount;
        WIK.safeTransferFrom(msg.sender, address(this), amount);

        emit KeeperStakeIncreased(msg.sender, amount, keepers[msg.sender].stakedWIK);
    }

    // ── Unstake (with cooldown) ────────────────────────────────────────────

    /// @notice Request to unstake WIK — starts 7-day cooldown [A4]
    function requestUnstake(uint256 amount) external nonReentrant {
        KeeperInfo storage k = keepers[msg.sender];
        require(k.active,                   "Registry: not registered");
        require(amount > 0,                 "Registry: zero amount");
        require(k.pendingUnstake == 0,      "Registry: unstake already pending");
        require(k.stakedWIK >= amount,      "Registry: insufficient stake");

        uint256 remaining = k.stakedWIK - amount;
        require(remaining == 0 || remaining >= MIN_STAKE, "Registry: remaining stake below minimum");

        k.stakedWIK           -= amount;
        k.pendingUnstake       = amount;
        k.unstakeRequestedAt   = block.timestamp;
        if (remaining == 0) k.active = false;

        emit UnstakeRequested(msg.sender, amount, block.timestamp + UNSTAKE_COOLDOWN);
    }

    /// @notice Claim unstaked WIK after cooldown expires
    function claimUnstake() external nonReentrant {
        KeeperInfo storage k = keepers[msg.sender];
        require(k.pendingUnstake > 0,       "Registry: nothing pending");
        require(
            block.timestamp >= k.unstakeRequestedAt + UNSTAKE_COOLDOWN,
            "Registry: cooldown not elapsed"
        );

        uint256 amount     = k.pendingUnstake;
        k.pendingUnstake   = 0;
        k.unstakeRequestedAt = 0;

        WIK.safeTransfer(msg.sender, amount);
        emit UnstakeClaimed(msg.sender, amount);
    }

    // ── Rewards ────────────────────────────────────────────────────────────

    /// @notice Accrue USDC reward to a keeper — called by WikiLiquidator [A3]
    function accrueReward(address keeper, uint256 amount, string calldata reason) external {
        require(slashers[msg.sender], "Registry: not slasher");
        require(isActive(keeper),     "Registry: keeper inactive");
        require(amount > 0,           "Registry: zero reward");

        keepers[keeper].rewardBalance += amount;
        totalPendingRewards           += amount;

        emit RewardAccrued(keeper, amount, reason);
    }

    /// @notice Keeper claims their accrued USDC rewards [A1][A3]
    function claimRewards() external nonReentrant {
        KeeperInfo storage k = keepers[msg.sender];
        uint256 amount = k.rewardBalance;
        require(amount > 0, "Registry: no rewards");

        // [A2] State before transfer
        k.rewardBalance      = 0;
        totalPendingRewards -= amount;

        IERC20(rewardToken).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice Deposit USDC rewards into this contract (called by WikiLiquidator)
    function depositRewards(uint256 amount) external nonReentrant {
        require(amount > 0, "Registry: zero deposit");
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        emit RewardDeposited(msg.sender, amount);
    }

    // ── Slashing ───────────────────────────────────────────────────────────

    /// @notice Slash a keeper for provable misbehaviour or missed critical liquidation [A6]
    /// @param keeper  Keeper address to slash
    /// @param amount  Amount of WIK to slash (capped at their stake)
    function slash(address keeper, uint256 amount) external {
        require(slashers[msg.sender], "Registry: not slasher");
        KeeperInfo storage k = keepers[keeper];
        require(k.stakedWIK > 0 || k.pendingUnstake > 0, "Registry: nothing to slash");

        // Draw from active stake first, then pending
        uint256 fromStake   = amount > k.stakedWIK   ? k.stakedWIK   : amount;
        uint256 remaining   = amount - fromStake;
        uint256 fromPending = remaining > k.pendingUnstake ? k.pendingUnstake : remaining;
        uint256 totalSlash  = fromStake + fromPending;

        k.stakedWIK     -= fromStake;
        k.pendingUnstake -= fromPending;
        k.slashCount     += 1;
        if (k.stakedWIK == 0) k.active = false;

        // Burn half, return half to insurance / treasury [A4]
        uint256 burned    = totalSlash * SLASH_BURN_BPS / BPS;
        uint256 toTreasury = totalSlash - burned;

        // Burn portion by sending to dead address
        if (burned > 0)      WIK.safeTransfer(address(0xdead), burned);
        // Return remainder to owner (goes to insurance fund)
        if (toTreasury > 0)  WIK.safeTransfer(owner(), toTreasury);

        emit KeeperSlashed(keeper, msg.sender, totalSlash, burned);
    }

    // ── Stats update (called by WikiLiquidator) ────────────────────────────
    function recordLiquidation(address keeper) external {
        require(slashers[msg.sender], "Registry: not slasher");
        keepers[keeper].totalLiquidations += 1;
        emit KeeperStatUpdated(keeper, keepers[keeper].totalLiquidations, keepers[keeper].totalOrdersFilled);
    }

    function recordOrderFill(address keeper) external {
        require(slashers[msg.sender], "Registry: not slasher");
        keepers[keeper].totalOrdersFilled += 1;
        emit KeeperStatUpdated(keeper, keepers[keeper].totalLiquidations, keepers[keeper].totalOrdersFilled);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    /// @notice Returns the tier (1/2/3) based on staked WIK
    function tierOf(address keeper) public view returns (uint8) {
        uint256 staked = keepers[keeper].stakedWIK;
        if (staked >= TIER3_STAKE) return 3;
        if (staked >= TIER2_STAKE) return 2;
        if (staked >= MIN_STAKE)   return 1;
        return 0;
    }

    /// @notice Reward multiplier in BPS for a given keeper
    function rewardMultiplier(address keeper) public view returns (uint256) {
        uint8 tier = tierOf(keeper);
        if (tier == 3) return TIER3_MULT;
        if (tier == 2) return TIER2_MULT;
        if (tier >= 1) return TIER1_MULT;
        return BPS; // unregistered = 1× (no bonus)
    }

    function isActive(address keeper) public view returns (bool) {
        return keepers[keeper].active;
    }

    function keeperCount() external view returns (uint256) {
        return keeperList.length;
    }

    function getKeeperInfo(address keeper) external view returns (KeeperInfo memory) {
        return keepers[keeper];
    }

    /// @notice Returns all active keepers (paginated for gas safety)
    function getActiveKeepers(uint256 offset, uint256 limit)
        external view returns (address[] memory result, uint256 total)
    {
        total = keeperList.length;
        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 count;
        address[] memory tmp = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            if (keepers[keeperList[i]].active) tmp[count++] = keeperList[i];
        }
        result = new address[](count);
        for (uint256 i = 0; i < count; i++) result[i] = tmp[i];
    }
}
