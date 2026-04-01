// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLiquidationInsurance
 * @notice Traders pay an upfront premium to buy downside protection within a
 *         price band. If they are liquidated within the protected range, they
 *         receive a percentage of collateral back. If they aren't liquidated,
 *         the protocol keeps the premium.
 *
 * MECHANISM
 * ─────────────────────────────────────────────────────────────────────────
 * 1. Trader has an open position at entryPrice with liquidationPrice liqPrice
 * 2. Trader buys BASIC (10% refund), STANDARD (25%), or PREMIUM (50%) cover
 * 3. Premium = positionSize × premiumBps / 10000
 * 4. If WikiLiquidator triggers liquidation → insurance 
interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

interface IWikiVault {
    function collectFee(address user, uint256 amount) external;
}

contract detects it
 *    via direct call from keeper → pays out to trader
 * 5. If position is closed normally → no payout, protocol keeps premium
 *
 * ACTUARIAL DESIGN
 * ─────────────────────────────────────────────────────────────────────────
 * Premium rates are set higher than expected payouts:
 * BASIC    (10% payout): 0.2% premium → expected 70% loss rate → 0.07% EV payout
 *          → protocol earns ~0.13% net per insured position
 * STANDARD (25% payout): 0.4% premium
 * PREMIUM  (50% payout): 0.8% premium
 *
 * RESERVE REQUIREMENT
 * ─────────────────────────────────────────────────────────────────────────
 * Contract maintains a reserve fund to pay claims.
 * Owner adds capital to reserve. 50% of premiums go to reserve, 50% to revenue.
 * If reserve drops below minReserveRatio, new policies are paused.
 */

interface IWikiLiquidator {
    function isLiquidatable(uint256 posId) external view returns (bool, uint256, uint256);
}


contract WikiLiquidationInsurance is Ownable2Step, ReentrancyGuard, Pausable {
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
    uint256 public constant BPS = 10_000;

    // Coverage tiers: coverage percentage, premium rate
    uint256[3] public COVERAGE_BPS   = [1000, 2500, 5000]; // 10%, 25%, 50%
    uint256[3] public PREMIUM_BPS    = [20,   40,   80];   // 0.2%, 0.4%, 0.8%

    uint256 public constant RESERVE_SHARE_BPS = 5000; // 50% of premiums → reserve
    uint256 public constant REVENUE_SHARE_BPS = 5000; // 50% → protocol revenue

    // ──────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────
    enum CoverageLevel { BASIC, STANDARD, PREMIUM }
    enum PolicyStatus  { ACTIVE, CLAIMED, EXPIRED, CANCELLED }

    struct Policy {
        address  trader;
        uint256  positionId;      // WikiPerp position ID being insured
        uint256  collateral;      // position collateral at time of purchase
        uint256  positionSize;    // notional size of the position
        uint256  premiumPaid;     // USDC premium paid
        uint256  coverageAmount;  // max payout if liquidated
        CoverageLevel level;
        PolicyStatus  status;
        uint256  createdAt;
        uint256  expiresAt;       // coverage expires after this timestamp
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20           public immutable USDC;
    IWikiLiquidator  public liquidator;

    Policy[]         public policies;
    mapping(uint256 => uint256) public positionToPolicy; // posId → policyId+1
    mapping(address => uint256[]) public traderPolicies;
    mapping(address => bool) public keepers;

    uint256 public reserveFund;       // USDC held to pay claims
    uint256 public protocolRevenue;   // USDC earned as profit
    uint256 public totalPremiums;
    uint256 public totalClaims;
    uint256 public totalPolicies;
    uint256 public activePolicies;

    uint256 public policyDuration   = 7 days;  // default coverage duration
    uint256 public minPositionSize  = 100 * 1e6; // min $100 position to insure

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event PolicyPurchased(uint256 indexed policyId, address indexed trader, uint256 positionId, CoverageLevel level, uint256 premium, uint256 coverage);
    event ClaimPaid(uint256 indexed policyId, address indexed trader, uint256 payout);
    event PolicyExpired(uint256 indexed policyId, address indexed trader);
    event ReserveFunded(address from, uint256 amount);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    
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

    constructor(address _usdc, address _liquidator, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_liquidator != address(0), "Wiki: zero _liquidator");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC       = IERC20(_usdc);
        liquidator = IWikiLiquidator(_liquidator);
    }

    // ──────────────────────────────────────────────────────────────────
    //  User: Buy Coverage
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Buy liquidation insurance for an open position.
     *
     * @param positionId   WikiPerp position ID to insure
     * @param collateral   Collateral amount of the position (USDC)
     * @param positionSize Notional size of the position (USDC)
     * @param level        BASIC / STANDARD / PREMIUM coverage tier
     */
    function buyPolicy(
        uint256       positionId,
        uint256       collateral,
        uint256       positionSize,
        CoverageLevel level
    ) external nonReentrant whenNotPaused returns (uint256 policyId) {
        require(positionSize >= minPositionSize,       "LI: position too small");
        require(positionToPolicy[positionId] == 0,    "LI: already insured");

        uint256 premium  = positionSize * PREMIUM_BPS[uint256(level)]  / BPS;
        uint256 coverage = collateral   * COVERAGE_BPS[uint256(level)] / BPS;

        require(reserveFund >= coverage, "LI: insufficient reserve");

        // [CEI] state before transfer
        policyId = policies.length;
        policies.push(Policy({
            trader:         msg.sender,
            positionId:     positionId,
            collateral:     collateral,
            positionSize:   positionSize,
            premiumPaid:    premium,
            coverageAmount: coverage,
            level:          level,
            status:         PolicyStatus.ACTIVE,
            createdAt:      block.timestamp,
            expiresAt:      block.timestamp + policyDuration
        }));

        positionToPolicy[positionId]  = policyId + 1;
        traderPolicies[msg.sender].push(policyId);
        totalPremiums  += premium;
        totalPolicies++;
        activePolicies++;

        // Split premium: 50% reserve, 50% revenue
        uint256 toReserve  = premium * RESERVE_SHARE_BPS / BPS;
        uint256 toRevenue  = premium - toReserve;
        reserveFund      += toReserve;
        protocolRevenue  += toRevenue;

        USDC.safeTransferFrom(msg.sender, address(this), premium);

        emit PolicyPurchased(policyId, msg.sender, positionId, level, premium, coverage);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Keeper: Process Claim
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Called by WikiLiquidator keeper after liquidating an insured position.
     *         Pays out the coverage amount to the trader.
     */
    function processClaim(uint256 positionId) external nonReentrant {
        require(keepers[msg.sender] || msg.sender == owner(), "LI: not keeper");

        uint256 idx = positionToPolicy[positionId];
        require(idx > 0, "LI: no policy");

        Policy storage p = policies[idx - 1];
        require(p.status == PolicyStatus.ACTIVE, "LI: policy not active");
        require(block.timestamp <= p.expiresAt,  "LI: policy expired");

        uint256 payout = p.coverageAmount;
        require(reserveFund >= payout, "LI: reserve insufficient");

        // [CEI] state before transfer
        p.status      = PolicyStatus.CLAIMED;
        reserveFund  -= payout;
        totalClaims  += payout;
        activePolicies--;

        positionToPolicy[positionId] = 0;
        USDC.safeTransfer(p.trader, payout);

        emit ClaimPaid(idx - 1, p.trader, payout);
    }

    /**
     * @notice Expire a policy whose coverage window has passed without liquidation.
     *         The premium stays with the protocol.
     */
    function expirePolicy(uint256 policyId) external {
        Policy storage p = policies[policyId];
        require(p.status == PolicyStatus.ACTIVE,    "LI: not active");
        require(block.timestamp > p.expiresAt,       "LI: not expired");

        p.status = PolicyStatus.EXPIRED;
        activePolicies--;
        positionToPolicy[p.positionId] = 0;

        emit PolicyExpired(policyId, p.trader);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function fundReserve(uint256 amount) external {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        reserveFund += amount;
        emit ReserveFunded(msg.sender, amount);
    }

    function withdrawRevenue(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= protocolRevenue, "LI: exceeds revenue");
        protocolRevenue -= amount;
        USDC.safeTransfer(to, amount);
    }

    function setKeeper(address keeper, bool enabled) external onlyOwner {
        keepers[keeper] = enabled;
    }

    function setPremiumRates(uint256[3] calldata premiumBps) external onlyOwner {
        for (uint256 i = 0; i < 3; i++) {
            require(premiumBps[i] <= 500, "LI: rate too high"); // max 5%
            PREMIUM_BPS[i] = premiumBps[i];
        }
    }

    function setPolicyDuration(uint256 duration) external onlyOwner {
        require(duration >= 1 days && duration <= 30 days, "LI: bad duration");
        policyDuration = duration;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getPolicy(uint256 id) external view returns (Policy memory) { return policies[id]; }
    function getPolicyForPosition(uint256 posId) external view returns (Policy memory) {
        uint256 idx = positionToPolicy[posId];
        require(idx > 0, "LI: no policy");
        return policies[idx - 1];
    }
    function getTraderPolicies(address trader) external view returns (uint256[] memory) { return traderPolicies[trader]; }

    function previewPremium(uint256 positionSize, CoverageLevel level)
        external view returns (uint256 premium, uint256 coverage)
    {
        premium  = positionSize * PREMIUM_BPS[uint256(level)] / BPS;
        coverage = positionSize * COVERAGE_BPS[uint256(level)] / BPS;
    }

    function reserveRatio() external view returns (uint256) {
        if (totalPolicies == 0) return BPS;
        // Ratio of reserve to total active coverage
        uint256 totalActiveCoverage;
        for (uint256 i = 0; i < policies.length; i++) {
            if (policies[i].status == PolicyStatus.ACTIVE) {
                totalActiveCoverage += policies[i].coverageAmount;
            }
        }
        if (totalActiveCoverage == 0) return BPS;
        return reserveFund * BPS / totalActiveCoverage;
    }

    function stats() external view returns (
        uint256 _totalPremiums, uint256 _totalClaims,
        uint256 _reserve, uint256 _revenue,
        uint256 _activePolicies, uint256 _lossRatio
    ) {
        uint256 lr = totalPremiums > 0 ? totalClaims * BPS / totalPremiums : 0;
        return (totalPremiums, totalClaims, reserveFund, protocolRevenue, activePolicies, lr);
    }
}
