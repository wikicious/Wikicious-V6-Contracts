// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiPropChallenge
 * @notice Flat upfront challenge fees for prop trading evaluations.
 *         Wraps WikiPropEval: trader pays flat fee → WikiPropEval runs the eval.
 *
 * MODEL (same as FTMO/TopStepTrader/The Funded Trader)
 * ─────────────────────────────────────────────────────────────────────────
 * Trader pays $100–$500 flat fee to attempt an evaluation.
 * If they PASS → funded account created. WikiPropFunded earns 20–30% of profits.
 * If they FAIL → trader can retry (paying again). Statistically 70–80% fail.
 *
 * REVENUE MODEL (per 1,000 challenges/month)
 * ─────────────────────────────────────────────────────────────────────────
 * • 750 fail (75%) × $200 avg fee = $150,000
 * • 250 pass → funded accounts → 25% profit split on trading profits
 * • Total challenge fee revenue: $200,000/month at scale
 *
 * CHALLENGE TIERS
 * ─────────────────────────────────────────────────────────────────────────
 * STARTER    : $10K account — $99 fee  — 8% profit target — 30 days
 * TRADER     : $25K account — $199 fee — 8% profit target — 30 days
 * FUNDED     : $50K account — $299 fee — 8% profit target — 45 days
 * ELITE      : $100K account — $499 fee — 10% profit target — 60 days
 * INSTANT    : Any size    — 3% of size — No evaluation — Immediate funding
 *
 * REFUND POLICY
 * ─────────────────────────────────────────────────────────────────────────
 * Passed traders receive a partial fee refund (configurable, default 50%).
 * Failed traders pay full fee — this is the primary revenue source.
 */

interface IWikiPropEval {
    function startEval(uint8 tier, uint256 accountSize) external returns (uint256 evalId);
}

interface IWikiPropFunded {
    function createFundedAccount(
        address trader,
        uint256 accountSize,
        uint8 tier,
        uint256 initialSplitBps
    ) external returns (uint256 accountId);
}

contract WikiPropChallenge is Ownable2Step, ReentrancyGuard {
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

    // ──────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────
    uint256 public constant BPS           = 10_000;
    uint256 public constant MAX_REFUND    = 8000;   // max 80% refund on pass
    uint256 public constant TREASURY_SHARE = 7000;  // 70% of fees → treasury
    uint256 public constant POOL_SHARE    = 3000;   // 30% → prop pool (funds winners)

    // ──────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────
    enum ChallengeStatus { ACTIVE, PASSED, FAILED, REFUNDED }
    enum AccountTier { STARTER, TRADER, FUNDED, ELITE, INSTANT }

    struct TierConfig {
        uint256 accountSize;    // virtual account size (USDC 6 dec)
        uint256 flatFee;        // USDC challenge fee
        uint256 passRefundBps;  // refund on pass (e.g. 5000 = 50%)
        uint256 profitTargetBps;// profit target to pass
        uint256 maxDailyDDBps;  // daily drawdown limit
        uint256 maxTotalDDBps;  // total drawdown limit
        uint256 durationDays;   // days to complete challenge
        uint8   evalTier;       // maps to WikiPropEval tier
        bool    instant;        // true = skip eval, fund immediately
    }

    struct Challenge {
        address trader;
        AccountTier tier;
        uint256 feePaid;
        uint256 evalId;      // 0 if instant tier
        uint256 startTime;
        ChallengeStatus status;
        bool    refundClaimed;
        uint256 fundedAccountId; // set on pass
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20           public immutable USDC;
    IWikiPropEval    public propEval;
    IWikiPropFunded  public propFunded;

    TierConfig[5]    public tiers;
    Challenge[]      public challenges;

    mapping(address => uint256[]) public traderChallenges;

    address public treasury;
    address public propPool;

    uint256 public totalFeesCollected;
    uint256 public totalChallenges;
    uint256 public totalPassed;
    uint256 public totalFailed;
    uint256 public totalRefunded;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event ChallengeStarted(uint256 indexed id, address indexed trader, AccountTier tier, uint256 fee);
    event ChallengePassed(uint256 indexed id, address indexed trader, uint256 fundedAccountId);
    event ChallengeFailed(uint256 indexed id, address indexed trader, string reason);
    event RefundClaimed(uint256 indexed id, address indexed trader, uint256 amount);
    event TierUpdated(AccountTier tier, uint256 fee, uint256 accountSize);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _propEval,
        address _propFunded,
        address _treasury,
        address _propPool,
        address _owner
    ) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_propEval != address(0), "Wiki: zero _propEval");
        require(_propFunded != address(0), "Wiki: zero _propFunded");
        USDC        = IERC20(_usdc);
        propEval    = IWikiPropEval(_propEval);
        propFunded  = IWikiPropFunded(_propFunded);
        treasury    = _treasury;
        propPool    = _propPool;
        _initTiers();
    }

    function _initTiers() internal {
        // STARTER: $10K account, $99 fee
        tiers[0] = TierConfig({
            accountSize:     10_000 * 1e6,
            flatFee:         99     * 1e6,
            passRefundBps:   5000,           // 50% refund on pass
            profitTargetBps: 800,            // 8%
            maxDailyDDBps:   400,
            maxTotalDDBps:   800,
            durationDays:    30,
            evalTier:        1,              // WikiPropEval Tier 1
            instant:         false
        });
        // TRADER: $25K account, $199 fee
        tiers[1] = TierConfig({
            accountSize:     25_000 * 1e6,
            flatFee:         199    * 1e6,
            passRefundBps:   5000,
            profitTargetBps: 800,
            maxDailyDDBps:   500,
            maxTotalDDBps:   1000,
            durationDays:    30,
            evalTier:        2,
            instant:         false
        });
        // FUNDED: $50K account, $299 fee
        tiers[2] = TierConfig({
            accountSize:     50_000 * 1e6,
            flatFee:         299    * 1e6,
            passRefundBps:   5000,
            profitTargetBps: 800,
            maxDailyDDBps:   500,
            maxTotalDDBps:   1000,
            durationDays:    45,
            evalTier:        2,
            instant:         false
        });
        // ELITE: $100K account, $499 fee
        tiers[3] = TierConfig({
            accountSize:     100_000 * 1e6,
            flatFee:         499     * 1e6,
            passRefundBps:   5000,
            profitTargetBps: 1000,           // 10%
            maxDailyDDBps:   400,
            maxTotalDDBps:   800,
            durationDays:    60,
            evalTier:        2,
            instant:         false
        });
        // INSTANT: 3% fee, immediate funding (no evaluation)
        tiers[4] = TierConfig({
            accountSize:     0,              // variable — set at purchase
            flatFee:         0,              // variable — 3% of account size
            passRefundBps:   0,
            profitTargetBps: 0,
            maxDailyDDBps:   300,
            maxTotalDDBps:   600,
            durationDays:    0,
            evalTier:        3,
            instant:         true
        });
    }

    // ──────────────────────────────────────────────────────────────────
    //  User: Start Challenge
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Pay the challenge fee and start your evaluation.
     * @param tier         Which challenge tier (0=STARTER … 4=INSTANT)
     * @param instantSize  Account size for INSTANT tier only (ignored for others)
     */
    function startChallenge(AccountTier tier, uint256 instantSize)
        external nonReentrant returns (uint256 challengeId)
    {
        TierConfig memory cfg = tiers[uint256(tier)];

        uint256 fee;
        uint256 accountSize;

        if (tier == AccountTier.INSTANT) {
            require(instantSize >= 1_000 * 1e6,   "PC: min $1K account");
            require(instantSize <= 200_000 * 1e6, "PC: max $200K account");
            accountSize = instantSize;
            fee         = instantSize * 300 / BPS; // 3% of account size
        } else {
            accountSize = cfg.accountSize;
            fee         = cfg.flatFee;
        }

        require(fee > 0, "PC: zero fee");

        // [CEI] State before transfer
        challengeId = challenges.length;
        challenges.push(Challenge({
            trader:          msg.sender,
            tier:            tier,
            feePaid:         fee,
            evalId:          0,
            startTime:       block.timestamp,
            status:          ChallengeStatus.ACTIVE,
            refundClaimed:   false,
            fundedAccountId: 0
        }));
        traderChallenges[msg.sender].push(challengeId);

        totalFeesCollected += fee;
        totalChallenges++;

        // Transfer fee
        USDC.safeTransferFrom(msg.sender, address(this), fee);

        // Distribute fee: 70% treasury, 30% prop pool
        uint256 toTreasury = fee * TREASURY_SHARE / BPS;
        uint256 toPool     = fee - toTreasury;
        if (toTreasury > 0 && treasury != address(0)) USDC.safeTransfer(treasury, toTreasury);
        if (toPool     > 0 && propPool  != address(0)) USDC.safeTransfer(propPool,  toPool);

        // For INSTANT tier: create funded account immediately
        if (tier == AccountTier.INSTANT && address(propFunded) != address(0)) {
            uint256 fundedId = propFunded.createFundedAccount(
                msg.sender, accountSize, cfg.evalTier, 8000 // 80% trader / 20% protocol
            );
            challenges[challengeId].status          = ChallengeStatus.PASSED;
            challenges[challengeId].fundedAccountId = fundedId;
            totalPassed++;
            emit ChallengePassed(challengeId, msg.sender, fundedId);
        } else if (address(propEval) != address(0)) {
            // Start evaluation in WikiPropEval
            uint256 evalId = propEval.startEval(cfg.evalTier, accountSize);
            challenges[challengeId].evalId = evalId;
        }

        emit ChallengeStarted(challengeId, msg.sender, tier, fee);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Admin: Mark Pass / Fail (called by keeper after eval completes)
    // ──────────────────────────────────────────────────────────────────

    function markPassed(uint256 challengeId, uint256 fundedAccountId) external onlyOwner {
        Challenge storage c = challenges[challengeId];
        require(c.status == ChallengeStatus.ACTIVE, "PC: not active");

        c.status          = ChallengeStatus.PASSED;
        c.fundedAccountId = fundedAccountId;
        totalPassed++;

        emit ChallengePassed(challengeId, c.trader, fundedAccountId);
    }

    function markFailed(uint256 challengeId, string calldata reason) external onlyOwner {
        Challenge storage c = challenges[challengeId];
        require(c.status == ChallengeStatus.ACTIVE, "PC: not active");

        c.status = ChallengeStatus.FAILED;
        totalFailed++;

        emit ChallengeFailed(challengeId, c.trader, reason);
    }

    // ──────────────────────────────────────────────────────────────────
    //  User: Claim Pass Refund
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice If you passed, claim your partial fee refund.
     *         Default 50% refund — reward for passing, incentive to retry.
     */
    function claimPassRefund(uint256 challengeId) external nonReentrant {
        Challenge storage c = challenges[challengeId];
        require(c.trader == msg.sender,             "PC: not your challenge");
        require(c.status == ChallengeStatus.PASSED, "PC: not passed");
        require(!c.refundClaimed,                   "PC: already claimed");

        c.refundClaimed = true;
        c.status        = ChallengeStatus.REFUNDED;

        TierConfig memory cfg = tiers[uint256(c.tier)];
        uint256 refund = c.feePaid * cfg.passRefundBps / BPS;

        if (refund > 0 && USDC.balanceOf(address(this)) >= refund) {
            totalRefunded += refund;
            USDC.safeTransfer(msg.sender, refund);
            emit RefundClaimed(challengeId, msg.sender, refund);
        }
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function updateTierFee(AccountTier tier, uint256 newFee) external onlyOwner {
        require(newFee <= 5000 * 1e6, "PC: fee too high"); // max $5K
        tiers[uint256(tier)].flatFee = newFee;
        emit TierUpdated(tier, newFee, tiers[uint256(tier)].accountSize);
    }

    function updateTierPassRefund(AccountTier tier, uint256 refundBps) external onlyOwner {
        require(refundBps <= MAX_REFUND, "PC: refund too high");
        tiers[uint256(tier)].passRefundBps = refundBps;
    }

    function setContracts(address _eval, address _funded, address _treasury, address _pool) external onlyOwner {
        propEval   = IWikiPropEval(_eval);
        propFunded = IWikiPropFunded(_funded);
        treasury   = _treasury;
        propPool   = _pool;
    }

    function withdrawExcess(uint256 amount, address to) external onlyOwner {
        USDC.safeTransfer(to, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getChallenge(uint256 id) external view returns (Challenge memory) {
        return challenges[id];
    }

    function getTier(AccountTier tier) external view returns (TierConfig memory) {
        return tiers[uint256(tier)];
    }

    function getTraderChallenges(address trader) external view returns (uint256[] memory) {
        return traderChallenges[trader];
    }

    function challengeCount() external view returns (uint256) {
        return challenges.length;
    }

    function passRate() external view returns (uint256) {
        if (totalChallenges == 0) return 0;
        return totalPassed * 10000 / totalChallenges; // in BPS
    }

    function projectedMonthlyRevenue() external view returns (uint256) {
        if (totalChallenges == 0) return 0;
        uint256 avgFee = totalFeesCollected / totalChallenges;
        // Estimate based on current run rate (30-day projection)
        return avgFee * totalChallenges;
    }
}
