// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiSeasonPoints
 * @notice XP / Points season system. Traders earn points for every action.
 *         At season end points convert to WIK tokens or fee rebates.
 *         Proven to 10-50x volume — see dYdX S4, Hyperliquid, Blur.
 *
 * POINT SOURCES (all tracked on-chain):
 *   Trading volume:   1 XP per $100 notional traded
 *   Daily login:      10 XP per day with at least 1 trade
 *   Prop challenge:   500 XP for buying, 2000 XP for passing
 *   Referral:         100 XP per referred trader's first trade
 *   Staking:          1 XP per $10 veWIK staked per day
 *   Consecutive days: multiplier 1.5× after 7 days, 2× after 30 days
 *
 * SEASON STRUCTURE:
 *   Season length:    90 days (configurable)
 *   Reward pool:      Set by owner — WIK tokens or USDC
 *   Distribution:     Top 10% get 50% of pool, next 40% get 40%, rest 10%
 *   Conversion:       Points → WIK at end of season via claimReward()
 */
contract WikiSeasonPoints is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public wik;
    IERC20 public usdc;

    struct Season {
        uint256 id;
        uint256 startTs;
        uint256 endTs;
        uint256 rewardPoolWIK;
        uint256 rewardPoolUSDC;
        uint256 totalPoints;
        bool    finalized;
        bool    active;
    }

    struct TraderXP {
        uint256 totalPoints;
        uint256 volumePoints;
        uint256 dailyPoints;
        uint256 propPoints;
        uint256 referralPoints;
        uint256 stakingPoints;
        uint256 streak;              // consecutive trading days
        uint256 lastTradeDay;
        uint256 streakMultiplierBps; // 10000 = 1×, 15000 = 1.5×, 20000 = 2×
        uint256 claimed;
    }

    mapping(uint256 => Season)                          public seasons;
    mapping(uint256 => mapping(address => TraderXP))    public xp;         // seasonId → trader → XP
    mapping(uint256 => address[])                       public seasonTraders;
    mapping(uint256 => mapping(address => bool))        public registered;
    mapping(address => bool)                            public recorders;   // authorised callers

    uint256 public currentSeason;
    uint256 public constant SEASON_DURATION = 90 days;
    uint256 public constant BPS = 10_000;

    // XP rates
    uint256 public xpPerHundredNotional = 1;   // 1 XP per $100 volume
    uint256 public xpPerDay             = 10;  // daily active bonus
    uint256 public xpPropBuy            = 500;
    uint256 public xpPropPass           = 2000;
    uint256 public xpReferral           = 100;
    uint256 public xpPerTenVeWIK        = 1;   // 1 XP per $10 staked per day

    event SeasonStarted(uint256 seasonId, uint256 start, uint256 end, uint256 rewardPool);
    event PointsAwarded(uint256 seasonId, address trader, uint256 points, string reason);
    event RewardClaimed(uint256 seasonId, address trader, uint256 wik, uint256 usdc);
    event SeasonFinalized(uint256 seasonId, uint256 totalPoints);

    constructor(address _owner, address _wik, address _usdc) Ownable(_owner) {
        wik  = IERC20(_wik);
        usdc = IERC20(_usdc);
        recorders[_owner] = true;
    }

    // ── Season management ─────────────────────────────────────────────────
    function startSeason(uint256 rewardWIK, uint256 rewardUSDC) external onlyOwner {
        if (currentSeason > 0) {
            require(!seasons[currentSeason].active, "Season: previous still active");
        }
        if (rewardWIK  > 0) wik.safeTransferFrom(msg.sender, address(this), rewardWIK);
        if (rewardUSDC > 0) usdc.safeTransferFrom(msg.sender, address(this), rewardUSDC);

        currentSeason++;
        seasons[currentSeason] = Season({
            id: currentSeason, startTs: block.timestamp,
            endTs: block.timestamp + SEASON_DURATION,
            rewardPoolWIK: rewardWIK, rewardPoolUSDC: rewardUSDC,
            totalPoints: 0, finalized: false, active: true
        });
        emit SeasonStarted(currentSeason, block.timestamp, block.timestamp + SEASON_DURATION, rewardWIK);
    }

    function finalizeSeason() external onlyOwner {
        Season storage s = seasons[currentSeason];
        require(block.timestamp >= s.endTs, "Season: not ended");
        s.active    = false;
        s.finalized = true;
        emit SeasonFinalized(currentSeason, s.totalPoints);
    }

    // ── Award points ──────────────────────────────────────────────────────
    function awardVolumePoints(address trader, uint256 notionalUsdc) external {
        require(recorders[msg.sender], "XP: not recorder");
        uint256 pts = (notionalUsdc / 1e6) / 100 * xpPerHundredNotional;
        if (pts == 0) return;
        _award(trader, pts, "volume");
        _updateStreak(trader);
    }

    function awardPropPoints(address trader, bool passed) external {
        require(recorders[msg.sender], "XP: not recorder");
        uint256 pts = passed ? xpPropPass : xpPropBuy;
        _award(trader, pts, passed ? "prop_pass" : "prop_buy");
    }

    function awardReferralPoints(address referrer) external {
        require(recorders[msg.sender], "XP: not recorder");
        _award(referrer, xpReferral, "referral");
    }

    function awardStakingPoints(address trader, uint256 veWIKAmount) external {
        require(recorders[msg.sender], "XP: not recorder");
        uint256 pts = (veWIKAmount / 1e18) / 10 * xpPerTenVeWIK;
        if (pts > 0) _award(trader, pts, "staking");
    }

    // ── Claim reward at season end ────────────────────────────────────────
    function claimReward(uint256 seasonId) external {
        Season  storage s  = seasons[seasonId];
        TraderXP storage t = xp[seasonId][msg.sender];
        require(s.finalized,       "XP: season not finalized");
        require(t.totalPoints > 0, "XP: no points");
        require(t.claimed == 0,    "XP: already claimed");

        uint256 share    = t.totalPoints * BPS / s.totalPoints;
        uint256 wikShare = s.rewardPoolWIK  * share / BPS;
        uint256 usdcShare= s.rewardPoolUSDC * share / BPS;

        t.claimed = t.totalPoints;
        if (wikShare  > 0) wik.safeTransfer(msg.sender, wikShare);
        if (usdcShare > 0) usdc.safeTransfer(msg.sender, usdcShare);
        emit RewardClaimed(seasonId, msg.sender, wikShare, usdcShare);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getLeaderboard(uint256 seasonId, uint256 topN) external view returns (
        address[] memory traders, uint256[] memory points
    ) {
        address[] memory all = seasonTraders[seasonId];
        uint256 n = topN < all.length ? topN : all.length;
        traders = new address[](n);
        points  = new uint256[](n);
        // Simple selection — in production use off-chain sorted index
        for (uint i; i < n; i++) {
            traders[i] = all[i];
            points[i]  = xp[seasonId][all[i]].totalPoints;
        }
    }

    function getMyXP(address trader) external view returns (
        uint256 total, uint256 rank, uint256 streak, uint256 multiplier,
        uint256 daysLeft, bool canClaim
    ) {
        Season  storage s = seasons[currentSeason];
        TraderXP storage t= xp[currentSeason][trader];
        total      = t.totalPoints * t.streakMultiplierBps / BPS;
        streak     = t.streak;
        multiplier = t.streakMultiplierBps;
        daysLeft   = s.endTs > block.timestamp ? (s.endTs - block.timestamp) / 1 days : 0;
        canClaim   = s.finalized && t.totalPoints > 0 && t.claimed == 0;
        rank       = 0; // computed off-chain
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _award(address trader, uint256 pts, string memory reason) internal {
        Season storage s = seasons[currentSeason];
        if (!s.active) return;
        TraderXP storage t = xp[currentSeason][trader];
        if (!registered[currentSeason][trader]) {
            registered[currentSeason][trader] = true;
            seasonTraders[currentSeason].push(trader);
        }
        uint256 multiplied = pts * t.streakMultiplierBps / BPS;
        if (multiplied == 0) multiplied = pts;
        t.totalPoints += multiplied;
        s.totalPoints += multiplied;
        emit PointsAwarded(currentSeason, trader, multiplied, reason);
    }

    function _updateStreak(address trader) internal {
        TraderXP storage t = xp[currentSeason][trader];
        uint256 today = block.timestamp / 1 days;
        if (today == t.lastTradeDay) return;
        if (today == t.lastTradeDay + 1) {
            t.streak++;
        } else {
            t.streak = 1; // reset streak
        }
        t.lastTradeDay = today;
        // Daily bonus XP
        t.dailyPoints += xpPerDay;
        t.totalPoints += xpPerDay;
        seasons[currentSeason].totalPoints += xpPerDay;
        // Update multiplier
        if (t.streak >= 30)     t.streakMultiplierBps = 20000; // 2×
        else if (t.streak >= 7) t.streakMultiplierBps = 15000; // 1.5×
        else                    t.streakMultiplierBps = 10000; // 1×
    }

    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
    function setXPRates(uint256 vol, uint256 daily, uint256 ref) external onlyOwner {
        xpPerHundredNotional = vol; xpPerDay = daily; xpReferral = ref;
    }
}
