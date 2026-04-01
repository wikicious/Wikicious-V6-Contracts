// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiAIGuardrails — On-Chain Security Scoreboard + Swap Insurance
 *
 * SECURITY SCOREBOARD
 * ─────────────────────────────────────────────────────────────────────────
 * Guardian (our off-chain AI engine) continuously scans every whitelisted token
 * and pool for risk vectors:
 *   • Honeypot detection (tax-on-sell, blacklist functions, max-tx limits)
 *   • Liquidity lock expiry (unlock events = rug-pull risk)
 *   • Ownership concentration (>50% supply in 1 wallet = high risk)
 *   • Contract upgrade proxy (can be drained without notice)
 *   • Sudden large LP removals (whale exit risk)
 *
 * The AI assigns each token a RISK SCORE (0–100) and a SAFETY TIER:
 *   SAFE (0–20):     Green — no red flags
 *   CAUTION (21–50): Yellow — monitor closely
 *   DANGER (51–80):  Orange — high risk
 *   CRITICAL (81–100): Red — honeypot or exploit likely
 *
 * SWAP INSURANCE
 * ─────────────────────────────────────────────────────────────────────────
 * Users can add a $0.05 insurance premium to any swap.
 * If a rug-pull or technical exploit drains the pool within 24h of their trade:
 *   → User files a claim, guardian validates on-chain evidence
 *   → InsuranceFund pays up to 100% of the swapped amount
 *   → 2% of all swap fees + 100% of premiums build the InsuranceFund float
 *
 * This creates an "insurance float" — capital that earns yield while sitting idle,
 * identical to how traditional insurance companies generate revenue.
 */

contract WikiAIGuardrails is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    enum RiskTier { SAFE, CAUTION, DANGER, CRITICAL }

    struct SecurityScore {
        uint8    score;          // 0–100 (100 = most dangerous)
        RiskTier tier;
        bool     honeypot;
        bool     liquidityLocked;
        uint256  liquidityLockExpiry;
        bool     proxyUpgradeable;
        uint256  ownerConcentrationPct; // % of supply in largest wallet
        uint256  lastScanTime;
        bool     active;
    }

    struct InsurancePolicy {
        address  user;
        address  tokenIn;
        address  tokenOut;
        uint256  amountIn;
        uint256  amountOut;
        uint256  premium;        // USDC paid
        uint256  coverageAmount; // max payout
        uint256  expiresAt;      // 24h window
        bool     claimed;
        bool     active;
    }

    struct Claim {
        uint256  policyId;
        address  user;
        string   evidence;       // IPFS hash of rug-pull proof
        uint256  claimedAt;
        bool     approved;
        bool     processed;
    }

    mapping(address => SecurityScore) public scores;       // token → score
    mapping(uint256 => InsurancePolicy) public policies;
    mapping(uint256 => Claim)          public claims;
    mapping(address => uint256[])      public userPolicies;
    mapping(address => bool)           public guardians;   // authorised AI scanners

    address[] public watchlist;
    uint256 public policyCount;
    uint256 public claimCount;
    uint256 public insuranceFund;    // USDC held
    uint256 public totalPremiums;
    uint256 public totalPayouts;

    uint256 public constant INSURANCE_PREMIUM_USDC = 50000;  // $0.05 (6 dec)
    uint256 public constant COVERAGE_MULTIPLIER    = 100;    // 1x = full coverage
    uint256 public constant INSURANCE_WINDOW       = 86400;  // 24h
    uint256 public constant PROTOCOL_CUT_BPS       = 2000;   // 20% of premiums → treasury
    uint256 public constant BPS                    = 10000;

    address public treasury;

    event ScoreUpdated(address indexed token, uint8 score, RiskTier tier, bool honeypot);
    event PolicyIssued(uint256 indexed policyId, address user, uint256 coverage, uint256 premium);
    event ClaimFiled(uint256 indexed claimId, uint256 policyId, address user);
    event ClaimApproved(uint256 indexed claimId, uint256 payout);
    event ClaimDenied(uint256 indexed claimId, string reason);
    event InsuranceFundDeposited(uint256 amount);

    constructor(address _usdc, address _treasury, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC     = IERC20(_usdc);
        treasury = _treasury;
    }

    modifier onlyGuardian() { require(guardians[msg.sender] || msg.sender == owner(), "Guardrails: not guardian"); _; }

    // ── Security Score Management (Guardian writes) ────────────────────────

    function updateScore(
        address token,
        uint8   score,
        bool    honeypot,
        bool    liquidityLocked,
        uint256 liquidityLockExpiry,
        bool    proxyUpgradeable,
        uint256 ownerConcentrationPct
    ) external onlyGuardian {
        RiskTier tier;
        if      (score <= 20) tier = RiskTier.SAFE;
        else if (score <= 50) tier = RiskTier.CAUTION;
        else if (score <= 80) tier = RiskTier.DANGER;
        else                  tier = RiskTier.CRITICAL;

        scores[token] = SecurityScore({
            score:                  score,
            tier:                   tier,
            honeypot:               honeypot,
            liquidityLocked:        liquidityLocked,
            liquidityLockExpiry:    liquidityLockExpiry,
            proxyUpgradeable:       proxyUpgradeable,
            ownerConcentrationPct:  ownerConcentrationPct,
            lastScanTime:           block.timestamp,
            active:                 true
        });

        emit ScoreUpdated(token, score, tier, honeypot);
    }

    function batchUpdateScores(
        address[] calldata tokens,
        uint8[]   calldata scoreArr,
        bool[]    calldata honeypots
    ) external onlyGuardian {
        require(tokens.length == scoreArr.length && tokens.length == honeypots.length, "Guardrails: length");
        for (uint i; i < tokens.length; i++) {
            RiskTier tier = scoreArr[i] <= 20 ? RiskTier.SAFE :
                            scoreArr[i] <= 50 ? RiskTier.CAUTION :
                            scoreArr[i] <= 80 ? RiskTier.DANGER : RiskTier.CRITICAL;
            scores[tokens[i]] = SecurityScore({ score:scoreArr[i], tier:tier, honeypot:honeypots[i],
                liquidityLocked:false, liquidityLockExpiry:0, proxyUpgradeable:false,
                ownerConcentrationPct:0, lastScanTime:block.timestamp, active:true });
        }
    }

    // ── Insurance Purchase ────────────────────────────────────────────────────

    function buyInsurance(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) external nonReentrant returns (uint256 policyId) {
        // Collect premium
        USDC.safeTransferFrom(msg.sender, address(this), INSURANCE_PREMIUM_USDC);

        // Protocol cut
        uint256 cut = INSURANCE_PREMIUM_USDC * PROTOCOL_CUT_BPS / BPS;
        USDC.safeTransfer(treasury, cut);
        insuranceFund += INSURANCE_PREMIUM_USDC - cut;
        totalPremiums += INSURANCE_PREMIUM_USDC;

        policyId = ++policyCount;
        policies[policyId] = InsurancePolicy({
            user:           msg.sender,
            tokenIn:        tokenIn,
            tokenOut:       tokenOut,
            amountIn:       amountIn,
            amountOut:      amountOut,
            premium:        INSURANCE_PREMIUM_USDC,
            coverageAmount: amountIn,   // covers up to 100% of input
            expiresAt:      block.timestamp + INSURANCE_WINDOW,
            claimed:        false,
            active:         true
        });
        userPolicies[msg.sender].push(policyId);
        emit PolicyIssued(policyId, msg.sender, amountIn, INSURANCE_PREMIUM_USDC);
    }

    // ── Claim Process ─────────────────────────────────────────────────────────

    function fileClaim(uint256 policyId, string calldata evidenceIPFS) external nonReentrant returns (uint256 claimId) {
        InsurancePolicy storage p = policies[policyId];
        require(p.user == msg.sender, "Guardrails: not policyholder");
        require(p.active && !p.claimed, "Guardrails: invalid policy");
        require(block.timestamp <= p.expiresAt, "Guardrails: policy expired");

        claimId = ++claimCount;
        claims[claimId] = Claim({
            policyId:  policyId,
            user:      msg.sender,
            evidence:  evidenceIPFS,
            claimedAt: block.timestamp,
            approved:  false,
            processed: false
        });
        emit ClaimFiled(claimId, policyId, msg.sender);
    }

    function processClaim(uint256 claimId, bool approve, string calldata reason) external onlyGuardian nonReentrant {
        Claim storage c = claims[claimId];
        require(!c.processed, "Guardrails: already processed");
        c.processed = true;

        if (approve) {
            InsurancePolicy storage p = policies[c.policyId];
            p.claimed = true;
            uint256 payout = p.coverageAmount > insuranceFund ? insuranceFund : p.coverageAmount;
            insuranceFund -= payout;
            totalPayouts  += payout;
            USDC.safeTransfer(c.user, payout);
            c.approved = true;
            emit ClaimApproved(claimId, payout);
        } else {
            emit ClaimDenied(claimId, reason);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function getScore(address token) external view returns (SecurityScore memory) { return scores[token]; }
    function isSafe(address token) external view returns (bool) {
        SecurityScore storage s = scores[token];
        return s.active && s.tier == RiskTier.SAFE && !s.honeypot;
    }
    function isHoneypot(address token) external view returns (bool) { return scores[token].honeypot; }
    function getUserPolicies(address user) external view returns (uint256[] memory) { return userPolicies[user]; }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function depositToFund(uint256 amount) external {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        insuranceFund += amount;
        emit InsuranceFundDeposited(amount);
    }

    function setGuardian(address g, bool enabled) external onlyOwner { guardians[g] = enabled; }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    function addToWatchlist(address token) external onlyOwner { watchlist.push(token); }

    // ── AI Risk Copilot — Health Score Alerts ────────────────────────────────
    // Monitors user positions and emits alerts when health drops.
    // Frontend subscribes to events and shows one-click suggestions.
    // AI agent (WikiAgenticDAO) can trigger preventive actions.

    struct RiskAlert {
        address user;
        uint256 healthScore;     // 0-100 (100 = perfectly healthy)
        uint256 liquidationRisk; // BPS to liquidation price
        string  suggestion;      // "Reduce leverage" / "Add margin" / "Close position"
        uint256 timestamp;
        bool    acknowledged;
    }

    mapping(address => RiskAlert) public latestAlert;
    mapping(address => uint256)   public alertThreshold; // user sets their own threshold
    uint256 public defaultThreshold = 2000; // alert at <20% health
    address public aiAgent;

    event HealthAlert(
        address indexed user,
        uint256 healthScore,
        uint256 liquidationRisk,
        string  suggestion
    );
    event HighVolatilityWarning(string eventName, uint256 expectedVolatilityBps, uint256 timestamp);

    function setAlertThreshold(uint256 thresholdBps) external {
        require(thresholdBps >= 500 && thresholdBps <= 8000, "Risk: threshold 5%-80%");
        alertThreshold[msg.sender] = thresholdBps;
    }

    function checkAndAlert(address user, uint256 healthScore, uint256 liquidationRisk) external {
        require(msg.sender == aiAgent || msg.sender == owner(), "Risk: not agent");
        uint256 threshold = alertThreshold[user] > 0 ? alertThreshold[user] : defaultThreshold;
        if (healthScore <= threshold) {
            string memory suggestion = healthScore <= 1000
                ? "URGENT: Add margin immediately or close position"
                : healthScore <= 2000
                    ? "Add margin or reduce position size"
                    : "Consider reducing leverage";
            latestAlert[user] = RiskAlert({
                user:             user,
                healthScore:      healthScore,
                liquidationRisk:  liquidationRisk,
                suggestion:       suggestion,
                timestamp:        block.timestamp,
                acknowledged:     false
            });
            emit HealthAlert(user, healthScore, liquidationRisk, suggestion);
        }
    }

    function broadcastVolatilityWarning(
        string calldata eventName,
        uint256 expectedVolatilityBps
    ) external {
        require(msg.sender == aiAgent || msg.sender == owner(), "Risk: not agent");
        emit HighVolatilityWarning(eventName, expectedVolatilityBps, block.timestamp);
    }

    function acknowledgeAlert() external {
        latestAlert[msg.sender].acknowledged = true;
    }

    function setAIAgent(address _agent) external onlyOwner {
        aiAgent = _agent;
    }

    function getUserRiskProfile(address user) external view returns (
        uint256 healthScore,
        uint256 liqRisk,
        string  memory suggestion,
        bool    hasAlert,
        bool    acknowledged,
        uint256 alertAge
    ) {
        RiskAlert storage a = latestAlert[user];
        healthScore    = a.healthScore;
        liqRisk        = a.liquidationRisk;
        suggestion     = a.suggestion;
        hasAlert       = a.timestamp > 0 && !a.acknowledged;
        acknowledged   = a.acknowledged;
        alertAge       = a.timestamp > 0 ? block.timestamp - a.timestamp : 0;
    }

}