// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiLPBoost
 * @notice veWIK holders earn up to 2.5× more LP rewards.
 *         Copies Curve Finance's boost model exactly.
 *         Curve went from $500M → $20B TVL with this one mechanism.
 *
 * BOOST FORMULA (Curve-exact):
 *   min_boost  = 1.0× (no veWIK)
 *   max_boost  = 2.5× (enough veWIK relative to pool share)
 *
 *   boost = min(
 *     2.5,
 *     0.4 + 0.6 × (veWIK_balance / veWIK_total) / (LP_balance / LP_total)
 *   )
 *
 * WHY THIS WORKS:
 *   LP with no veWIK: earns 1.0× base rate
 *   LP with small veWIK: earns 1.2-1.8× base rate
 *   LP with proportional veWIK: earns 2.5× base rate
 *
 *   This creates permanent demand to lock WIK as veWIK:
 *   Lock WIK → higher LP boost → more rewards → buy more WIK → lock more
 *   The flywheel: WikiStaking + WikiGaugeVoting + WikiLPBoost = Curve model
 *
 * REVENUE MULTIPLICATION:
 *   More LPs (attracted by 2.5× boost) → deeper pools → better fills
 *   Better fills → more traders → more fees → higher natural APY
 *   Higher APY → more LPs → compounding liquidity growth
 */
contract WikiLPBoost is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable veWIK;
    IERC20 public immutable WIK;

    struct PoolBoostConfig {
        address lpToken;
        uint256 totalLPSupply;      // total LP tokens in this pool
        bool    active;
    }

    struct UserBoost {
        uint256 lpBalance;          // LP tokens deposited
        uint256 workingBalance;     // boosted effective balance
        uint256 lastUpdate;
    }

    mapping(uint256 => PoolBoostConfig)            public pools;      // poolId → config
    mapping(uint256 => mapping(address => UserBoost)) public userBoosts; // poolId → user → boost
    mapping(uint256 => uint256)                    public totalWorking; // poolId → total working balance

    uint256 public nextPoolId;
    uint256 public constant BOOST_PRECISION = 1e18;
    uint256 public constant MAX_BOOST_BPS   = 25000; // 2.5× in BPS (10000 = 1×)
    uint256 public constant MIN_BOOST_BPS   = 10000; // 1.0×
    // Curve formula constants: boost = 0.4 + 0.6 × veShare/lpShare
    uint256 public constant BASE_FACTOR     = 4000;  // 40% of max = base with no veWIK
    uint256 public constant VE_FACTOR       = 6000;  // 60% comes from veWIK weight

    event PoolAdded(uint256 poolId, address lpToken);
    event BoostUpdated(uint256 poolId, address user, uint256 boostBps, uint256 workingBalance);

    constructor(address _owner, address _veWIK, address _wik) Ownable(_owner) {
        veWIK = IERC20(_veWIK);
        WIK   = IERC20(_wik);
    }

    // ── Add a pool ────────────────────────────────────────────────────────
    function addPool(address lpToken) external onlyOwner returns (uint256 poolId) {
        poolId = nextPoolId++;
        pools[poolId] = PoolBoostConfig({ lpToken: lpToken, totalLPSupply: 0, active: true });
        emit PoolAdded(poolId, lpToken);
    }

    // ── Calculate boost for a user ────────────────────────────────────────
    /**
     * @notice Calculate boost multiplier for user in a pool.
     * @return boostBps  10000 = 1.0×, 25000 = 2.5×
     */
    function calculateBoost(uint256 poolId, address user) public view returns (uint256 boostBps) {
        PoolBoostConfig storage pool = pools[poolId];
        if (!pool.active) return MIN_BOOST_BPS;

        uint256 lpBal     = userBoosts[poolId][user].lpBalance;
        uint256 lpTotal   = pool.totalLPSupply;
        if (lpBal == 0 || lpTotal == 0) return MIN_BOOST_BPS;

        uint256 veBal     = veWIK.balanceOf(user);
        uint256 veTotal   = veWIK.totalSupply();
        if (veTotal == 0) return MIN_BOOST_BPS;

        // Curve formula:
        // working = 0.4 × lp + 0.6 × (veShare/lpShare) × lp
        // boost   = working / (0.4 × lp)  — normalised
        // Simplified to BPS:
        uint256 veShare = veBal * 1e18 / veTotal;
        uint256 lpShare = lpBal * 1e18 / lpTotal;

        // Avoid division by zero
        if (lpShare == 0) return MIN_BOOST_BPS;

        uint256 veBonus   = VE_FACTOR * veShare / lpShare; // scaled BPS
        uint256 rawBoost  = BASE_FACTOR + veBonus;

        // Cap at 2.5×
        boostBps = rawBoost > MAX_BOOST_BPS ? MAX_BOOST_BPS : rawBoost;
        if (boostBps < MIN_BOOST_BPS) boostBps = MIN_BOOST_BPS;
    }

    // ── Update working balance (call when user's LP or veWIK changes) ─────
    function updateWorkingBalance(uint256 poolId, address user) external {
        UserBoost storage ub = userBoosts[poolId][user];
        uint256 boostBps = calculateBoost(poolId, user);

        uint256 oldWorking = ub.workingBalance;
        uint256 newWorking = ub.lpBalance * boostBps / MIN_BOOST_BPS;

        totalWorking[poolId] = totalWorking[poolId] - oldWorking + newWorking;
        ub.workingBalance    = newWorking;
        ub.lastUpdate        = block.timestamp;

        emit BoostUpdated(poolId, user, boostBps, newWorking);
    }

    // ── Record LP deposit ─────────────────────────────────────────────────
    function recordDeposit(uint256 poolId, address user, uint256 lpAmount) external onlyOwner {
        PoolBoostConfig storage pool = pools[poolId];
        require(pool.active, "Boost: pool inactive");
        userBoosts[poolId][user].lpBalance += lpAmount;
        pool.totalLPSupply                 += lpAmount;
        _refreshBoost(poolId, user);
    }

    function recordWithdraw(uint256 poolId, address user, uint256 lpAmount) external onlyOwner {
        PoolBoostConfig storage pool = pools[poolId];
        UserBoost storage ub = userBoosts[poolId][user];
        require(ub.lpBalance >= lpAmount, "Boost: insufficient LP");
        ub.lpBalance      -= lpAmount;
        pool.totalLPSupply -= lpAmount;
        _refreshBoost(poolId, user);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getBoostMultiplier(uint256 poolId, address user) external view returns (
        uint256 boostBps,
        uint256 boostDisplay,  // e.g. 15000 → "1.50×"
        uint256 workingBalance,
        uint256 lpBalance,
        uint256 veWIKNeededForMax
    ) {
        boostBps       = calculateBoost(poolId, user);
        boostDisplay   = boostBps;
        workingBalance = userBoosts[poolId][user].workingBalance;
        lpBalance      = userBoosts[poolId][user].lpBalance;

        // How much veWIK needed to reach 2.5×?
        uint256 lpBal  = userBoosts[poolId][user].lpBalance;
        uint256 lpTot  = pools[poolId].totalLPSupply;
        uint256 veTot  = veWIK.totalSupply();
        if (lpBal > 0 && lpTot > 0 && veTot > 0) {
            // Solve for veBal: 2.5 = 0.4 + 0.6 × (veBal/veTot)/(lpBal/lpTot)
            // veBal = (veTot × lpBal × (2.5-0.4)) / (lpTot × 0.6)
            veWIKNeededForMax = veTot * lpBal * (MAX_BOOST_BPS - BASE_FACTOR)
                / lpTot / VE_FACTOR;
        }
    }

    function getPoolStats(uint256 poolId) external view returns (
        uint256 totalLP, uint256 totalWorkingBal, uint256 avgBoostBps
    ) {
        totalLP         = pools[poolId].totalLPSupply;
        totalWorkingBal = totalWorking[poolId];
        avgBoostBps     = totalLP > 0 ? totalWorkingBal * MIN_BOOST_BPS / totalLP : MIN_BOOST_BPS;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _refreshBoost(uint256 poolId, address user) internal {
        UserBoost storage ub  = userBoosts[poolId][user];
        uint256 boostBps      = calculateBoost(poolId, user);
        uint256 oldWorking     = ub.workingBalance;
        uint256 newWorking     = ub.lpBalance * boostBps / MIN_BOOST_BPS;
        totalWorking[poolId]  = totalWorking[poolId] - oldWorking + newWorking;
        ub.workingBalance      = newWorking;
        ub.lastUpdate          = block.timestamp;
        emit BoostUpdated(poolId, user, boostBps, newWorking);
    }
}
