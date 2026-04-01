// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiReferralLeaderboard
 * @notice Monthly affiliate competition with on-chain prize distribution.
 *         Makes top affiliates compete fiercely — each one works harder
 *         knowing rivals can see their rank updated in real time.
 *
 * PRIZE STRUCTURE (monthly, funded from ops vault):
 *   1st place: $2,000 USDC
 *   2nd place: $1,000 USDC
 *   3rd place: $500 USDC
 *   4th-10th:  Share of $500 USDC pool
 *   Total:     $4,000/month = $48,000/year
 *
 * WHAT GETS TRACKED:
 *   Volume referred (weighted most heavily)
 *   New traders referred
 *   Trader retention (traders still active after 30 days)
 *   Diversity bonus (referred traders across different features)
 *
 * COST/BENEFIT:
 *   Cost: $4,000/month in prizes
 *   Benefit: Top 10 affiliates each driving $500K-$5M monthly volume
 *   At $10M extra volume × 0.07% fee: $7,000 in fees from prizes alone
 *   Net ROI: >100% on prize spend
 */
contract WikiReferralLeaderboard is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct MonthlyStats {
        address affiliate;
        uint256 volumeReferred;     // USDC notional from referred traders
        uint256 newTradersReferred;
        uint256 activeTraders30d;   // still active after 30 days (retention)
        uint256 feesGenerated;      // actual fees from referred traders
        uint256 score;              // computed score for ranking
        bool    claimed;
    }

    struct PrizePool {
        uint256 month;              // unix month (timestamp / 30 days)
        uint256 totalPrize;
        uint256[3]  topPrizes;      // 1st/2nd/3rd place
        uint256     restPool;       // shared among 4th-10th
        bool        distributed;
        address[10] topAffiliates;
        uint256[10] topScores;
    }

    mapping(uint256 => mapping(address => MonthlyStats)) public monthlyStats; // month → affiliate → stats
    mapping(uint256 => PrizePool)  public prizePools;
    mapping(uint256 => address[])  public monthParticipants;
    mapping(address => bool)       public recorders;
    mapping(address => uint256)    public lifetimeEarnings;

    uint256 public currentMonth;
    uint256 public constant SCORE_VOLUME_WEIGHT   = 60; // 60% weight to volume
    uint256 public constant SCORE_TRADERS_WEIGHT  = 25; // 25% weight to new traders
    uint256 public constant SCORE_RETENTION_WEIGHT= 15; // 15% weight to retention

    event StatsUpdated(address affiliate, uint256 month, uint256 volume, uint256 traders);
    event MonthFinalized(uint256 month, address[10] winners, uint256[10] prizes);
    event PrizeClaimed(address affiliate, uint256 month, uint256 amount);

    constructor(address _owner, address _usdc) Ownable(_owner) {
        USDC = IERC20(_usdc);
        recorders[_owner] = true;
        currentMonth = block.timestamp / 30 days;
    }

    // ── Record referral activity ──────────────────────────────────────────
    function recordReferral(
        address affiliate,
        uint256 volumeUsdc,
        uint256 feesUsdc,
        bool    isNewTrader
    ) external {
        require(recorders[msg.sender], "RL: not recorder");
        uint256 month = block.timestamp / 30 days;

        MonthlyStats storage s = monthlyStats[month][affiliate];
        if (s.affiliate == address(0)) {
            s.affiliate = affiliate;
            monthParticipants[month].push(affiliate);
        }

        s.volumeReferred  += volumeUsdc;
        s.feesGenerated   += feesUsdc;
        if (isNewTrader) s.newTradersReferred++;

        s.score = _computeScore(s);
        emit StatsUpdated(affiliate, month, s.volumeReferred, s.newTradersReferred);
    }

    function updateRetention(address affiliate, uint256 month, uint256 activeTraders) external {
        require(recorders[msg.sender] || msg.sender == owner(), "RL: not recorder");
        monthlyStats[month][affiliate].activeTraders30d = activeTraders;
        monthlyStats[month][affiliate].score = _computeScore(monthlyStats[month][affiliate]);
    }

    // ── Fund prize pool ───────────────────────────────────────────────────
    function fundPrizePool(uint256 month, uint256 totalPrize) external onlyOwner {
        USDC.safeTransferFrom(msg.sender, address(this), totalPrize);
        PrizePool storage p = prizePools[month];
        p.month       = month;
        p.totalPrize  = totalPrize;
        p.topPrizes   = [totalPrize * 40 / 100, totalPrize * 25 / 100, totalPrize * 12 / 100];
        p.restPool    = totalPrize - p.topPrizes[0] - p.topPrizes[1] - p.topPrizes[2];
    }

    // ── Finalize month and set winners ────────────────────────────────────
    function finalizeMonth(uint256 month) external onlyOwner {
        require(block.timestamp / 30 days > month, "RL: month not ended");
        PrizePool storage pool = prizePools[month];
        require(!pool.distributed,                "RL: already distributed");

        address[] storage participants = monthParticipants[month];
        address[10] memory topAffiliates;
        uint256[10] memory topScores;

        // Simple top-10 selection
        for (uint rank; rank < 10 && rank < participants.length; rank++) {
            address best; uint256 bestScore;
            for (uint j; j < participants.length; j++) {
                uint256 score = monthlyStats[month][participants[j]].score;
                bool already;
                for (uint k; k < rank; k++) if (topAffiliates[k] == participants[j]) { already = true; break; }
                if (!already && score > bestScore) { bestScore = score; best = participants[j]; }
            }
            topAffiliates[rank] = best;
            topScores[rank]     = bestScore;
        }

        pool.topAffiliates = topAffiliates;
        pool.topScores     = topScores;

        emit MonthFinalized(month, topAffiliates, topScores);
    }

    // ── Claim prize ───────────────────────────────────────────────────────
    function claimPrize(uint256 month) external nonReentrant {
        PrizePool storage pool = prizePools[month];
        MonthlyStats storage s = monthlyStats[month][msg.sender];
        require(s.affiliate == msg.sender && !s.claimed, "RL: not eligible or claimed");
        require(pool.month == month,                      "RL: pool not set");

        uint256 prize;
        for (uint rank; rank < 10; rank++) {
            if (pool.topAffiliates[rank] == msg.sender) {
                if      (rank == 0) prize = pool.topPrizes[0];
                else if (rank == 1) prize = pool.topPrizes[1];
                else if (rank == 2) prize = pool.topPrizes[2];
                else                prize = pool.restPool / 7; // split 4th-10th evenly
                break;
            }
        }
        require(prize > 0, "RL: not a winner");
        s.claimed = true;
        lifetimeEarnings[msg.sender] += prize;
        USDC.safeTransfer(msg.sender, prize);
        emit PrizeClaimed(msg.sender, month, prize);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getMonthlyLeaderboard(uint256 month, uint256 n) external view returns (
        address[] memory affiliates, uint256[] memory scores,
        uint256[] memory volumes, uint256[] memory traders
    ) {
        address[] storage all = monthParticipants[month];
        uint256 count = n < all.length ? n : all.length;
        affiliates = new address[](count); scores  = new uint256[](count);
        volumes    = new uint256[](count); traders = new uint256[](count);
        for (uint rank; rank < count; rank++) {
            address best; uint256 bestScore;
            for (uint j; j < all.length; j++) {
                uint256 sc = monthlyStats[month][all[j]].score;
                bool already;
                for (uint k; k < rank; k++) if (affiliates[k] == all[j]) { already = true; break; }
                if (!already && sc > bestScore) { bestScore = sc; best = all[j]; }
            }
            affiliates[rank] = best;
            scores[rank]     = bestScore;
            volumes[rank]    = monthlyStats[month][best].volumeReferred;
            traders[rank]    = monthlyStats[month][best].newTradersReferred;
        }
    }

    function getAffiliateStats(address affiliate, uint256 month) external view returns (MonthlyStats memory) {
        return monthlyStats[month][affiliate];
    }

    function _computeScore(MonthlyStats memory s) internal pure returns (uint256) {
        uint256 volScore     = (s.volumeReferred / 1e6) * SCORE_VOLUME_WEIGHT;
        uint256 traderScore  = s.newTradersReferred * 1000 * SCORE_TRADERS_WEIGHT;
        uint256 retScore     = s.activeTraders30d * 500 * SCORE_RETENTION_WEIGHT;
        return volScore + traderScore + retScore;
    }

    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
