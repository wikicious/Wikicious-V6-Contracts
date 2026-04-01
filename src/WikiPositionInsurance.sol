// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiPositionInsurance
 * @notice Insurance marketplace for open positions.
 *         Traders pay premium to insure against liquidation gap losses.
 *         Underwriters earn yield by providing coverage.
 *         Protocol earns 10% of all premiums.
 *
 * HOW IT WORKS:
 *   1. Trader opens $10K BTC position at 10× leverage
 *   2. Buys insurance: "pay $50 to insure first $500 of gap loss"
 *   3. If BTC gaps 6% down — normal liquidation covers 1%,
 *      gap is 5% = $500. Insurance pays the trader $500.
 *   4. Underwriter who provided coverage earns the $50 premium
 *
 * COVERAGE TYPES:
 *   GAP_ONLY:      Covers price gap beyond DD limit (most common)
 *   FULL_LOSS:     Covers 100% of position loss (expensive)
 *   PARTIAL:       Covers up to X% of position size
 *
 * PREMIUM PRICING:
 *   Base rate = coverage amount × volatility factor × duration
 *   Forex (low vol):  0.1-0.3% per week
 *   Crypto (high vol): 0.5-2.0% per week
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiPositionInsurance is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    enum CoverageType { GAP_ONLY, PARTIAL, FULL_LOSS }
    enum PolicyStatus  { Active, Claimed, Expired, Cancelled }

    struct Policy {
        address     trader;
        uint256     positionId;
        uint256     marketId;
        CoverageType coverageType;
        PolicyStatus status;
        uint256     coverageAmount;  // max USDC payout
        uint256     premiumPaid;
        uint256     startTs;
        uint256     expiryTs;
        uint256     underwriterPool; // which pool underwrote this
    }

    struct UnderwriterPool {
        address   underwriter;
        uint256   totalCapital;
        uint256   deployedCapital;
        uint256   totalPremiumEarned;
        uint256   totalClaimsPaid;
        uint256   coverageMultiplier; // how much coverage per $1 capital (e.g. 5 = 5:1)
        bool      active;
    }

    mapping(uint256 => Policy)           public policies;
    mapping(uint256 => UnderwriterPool)  public pools;
    mapping(address => uint256[])        public traderPolicies;
    mapping(address => uint256)          public underwriterPoolId;

    address public revenueSplitter;
    address public keeper;
    address public oracle;

    uint256 public nextPolicyId;
    uint256 public nextPoolId;
    uint256 public protocolFeeBps = 1000; // 10% of premiums
    uint256 public constant BPS   = 10_000;

    event PolicyPurchased(uint256 policyId, address trader, uint256 coverage, uint256 premium);
    event PolicyClaimed(uint256 policyId, address trader, uint256 payout);
    event PolicyExpired(uint256 policyId);
    event PoolCreated(uint256 poolId, address underwriter, uint256 capital);
    event UnderwriterEarned(uint256 poolId, uint256 premium);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = router;
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

    constructor(
        address _owner, address _usdc,
        address _revenueSplitter, address _keeper
    ) Ownable(_owner) {
        USDC            = IERC20(_usdc);
        revenueSplitter = _revenueSplitter;
        keeper          = _keeper;
    }

    // ── Underwriter: provide coverage capital ─────────────────────────────
    function createPool(uint256 capital, uint256 coverageMultiplier) external nonReentrant returns (uint256 poolId) {
        require(capital >= 1000 * 1e6,             "Ins: min $1,000 capital");
        require(coverageMultiplier >= 2 && coverageMultiplier <= 10, "Ins: multiplier 2-10");
        USDC.safeTransferFrom(msg.sender, address(this), capital);
        poolId = nextPoolId++;
        pools[poolId] = UnderwriterPool({
            underwriter:        msg.sender,
            totalCapital:       capital,
            deployedCapital:    0,
            totalPremiumEarned: 0,
            totalClaimsPaid:    0,
            coverageMultiplier: coverageMultiplier,
            active:             true
        });
        underwriterPoolId[msg.sender] = poolId;
        emit PoolCreated(poolId, msg.sender, capital);
    }

    function addCapital(uint256 poolId, uint256 amount) external nonReentrant {
        require(pools[poolId].underwriter == msg.sender, "Ins: not your pool");
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        pools[poolId].totalCapital += amount;
    }

    function withdrawCapital(uint256 poolId, uint256 amount) external nonReentrant {
        UnderwriterPool storage p = pools[poolId];
        require(p.underwriter == msg.sender, "Ins: not your pool");
        uint256 available = p.totalCapital - p.deployedCapital;
        require(available >= amount, "Ins: capital deployed");
        p.totalCapital -= amount;
        USDC.safeTransfer(msg.sender, amount);
    }

    // ── Trader: buy insurance ─────────────────────────────────────────────
    function buyPolicy(
        uint256      positionId,
        uint256      marketId,
        CoverageType coverageType,
        uint256      coverageAmount,
        uint256      poolId,
        uint256      durationDays
    ) external nonReentrant returns (uint256 policyId) {
        require(durationDays >= 1 && durationDays <= 30, "Ins: 1-30 days");
        UnderwriterPool storage pool = pools[poolId];
        require(pool.active, "Ins: pool inactive");
        uint256 available = (pool.totalCapital * pool.coverageMultiplier) - pool.deployedCapital;
        require(coverageAmount <= available, "Ins: insufficient pool capacity");

        // Calculate premium (simple model — production uses vol oracle)
        uint256 baseRateBps = marketId < 100 ? 50 : 150; // forex=0.5%, crypto=1.5% per week
        uint256 premium = coverageAmount * baseRateBps * durationDays / 7 / BPS;
        require(premium > 0, "Ins: zero premium");

        USDC.safeTransferFrom(msg.sender, address(this), premium);

        // Split: 90% to underwriter, 10% to protocol
        uint256 protocolShare    = premium * protocolFeeBps / BPS;
        uint256 underwriterShare = premium - protocolShare;
        pool.totalPremiumEarned += underwriterShare;
        pool.deployedCapital    += coverageAmount;

        if (protocolShare > 0) USDC.safeTransfer(revenueSplitter, protocolShare);

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            trader:         msg.sender,
            positionId:     positionId,
            marketId:       marketId,
            coverageType:   coverageType,
            status:         PolicyStatus.Active,
            coverageAmount: coverageAmount,
            premiumPaid:    premium,
            startTs:        block.timestamp,
            expiryTs:       block.timestamp + durationDays * 1 days,
            underwriterPool:poolId
        });
        traderPolicies[msg.sender].push(policyId);
        emit PolicyPurchased(policyId, msg.sender, coverageAmount, premium);
        emit UnderwriterEarned(poolId, underwriterShare);
    }

    // ── Claim insurance payout ────────────────────────────────────────────
    function claimPolicy(uint256 policyId, uint256 actualLoss) external nonReentrant {
        Policy storage pol = policies[policyId];
        require(pol.trader    == msg.sender,          "Ins: not your policy");
        require(pol.status    == PolicyStatus.Active, "Ins: not active");
        require(block.timestamp <= pol.expiryTs,      "Ins: expired");
        require(actualLoss     > 0,                   "Ins: zero loss");

        uint256 payout = actualLoss > pol.coverageAmount ? pol.coverageAmount : actualLoss;
        UnderwriterPool storage pool = pools[pol.underwriterPool];

        pol.status = PolicyStatus.Claimed;
        pool.deployedCapital    -= pol.coverageAmount;
        pool.totalClaimsPaid    += payout;
        pool.totalCapital       -= payout; // underwriter absorbs loss

        USDC.safeTransfer(msg.sender, payout);
        emit PolicyClaimed(policyId, msg.sender, payout);
    }

    function expirePolicy(uint256 policyId) external {
        Policy storage pol = policies[policyId];
        require(block.timestamp > pol.expiryTs, "Ins: not expired");
        require(pol.status == PolicyStatus.Active, "Ins: not active");
        pol.status = PolicyStatus.Expired;
        pools[pol.underwriterPool].deployedCapital -= pol.coverageAmount;
        emit PolicyExpired(policyId);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getQuote(uint256 coverageAmount, uint256 marketId, uint256 durationDays)
        external pure returns (uint256 premium, uint256 weeklyRateBps)
    {
        weeklyRateBps = marketId < 100 ? 50 : 150;
        premium = coverageAmount * weeklyRateBps * durationDays / 7 / BPS;
    }

    function getPoolStats(uint256 poolId) external view returns (
        uint256 totalCapital, uint256 availableCapacity, uint256 totalEarned,
        uint256 totalClaims, uint256 netPnl, uint256 utilizationBps
    ) {
        UnderwriterPool storage p = pools[poolId];
        totalCapital     = p.totalCapital;
        availableCapacity= (p.totalCapital * p.coverageMultiplier) - p.deployedCapital;
        totalEarned      = p.totalPremiumEarned;
        totalClaims      = p.totalClaimsPaid;
        netPnl           = totalEarned > totalClaims ? totalEarned - totalClaims : 0;
        utilizationBps   = p.totalCapital > 0 ? p.deployedCapital * BPS / (p.totalCapital * p.coverageMultiplier) : 0;
    }

    function setKeeper(address k) external onlyOwner { keeper = k; }
    function setProtocolFee(uint256 bps) external onlyOwner { require(bps <= 2000); protocolFeeBps = bps; }
}
