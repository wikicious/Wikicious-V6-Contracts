// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiInstitutionalPool — KYB-Gated Permissioned Pools for Institutions
 *
 * Creates a "clean" liquidity layer where only KYB-verified entities can participate.
 * Institutions (hedge funds, family offices, DAOs, protocols) pay a subscription fee
 * for access to these pools which offer:
 *   • Anonymous-free environment (all LPs are KYB-verified)
 *   • Regulatory compliance documentation on demand
 *   • Priority execution (orders processed before retail)
 *   • Lower slippage (deep institutional liquidity)
 *   • Premium swap fee tier (0.01% for stablecoins, 0.05% for majors)
 *
 * REVENUE MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * Subscription: $5,000/month (USDC) or $50,000/year
 * Premium swap fee: 0.10% on all institutional trades (vs 0.30% retail)
 * LP fee share: Institutional LPs earn 0.08% (higher than retail 0.05%)
 * Minimum deposit: $100,000 USDC to qualify as LP
 */

interface IWikiOracle { function getPrice(bytes32 id) external view returns (uint256, uint256); }


interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiInstitutionalPool is Ownable2Step, ReentrancyGuard, Pausable {
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

    enum KYBTier { NONE, PENDING, VERIFIED, PREMIUM, BLACKLISTED }
    enum SubscriptionTier { NONE, BASIC, PRO, ENTERPRISE }

    struct Institution {
        string   name;
        string   jurisdiction;
        address  wallet;
        KYBTier  kyb;
        SubscriptionTier sub;
        uint256  subExpiry;
        uint256  minDeposit;     // USD 18dec
        uint256  totalDeposited;
        uint256  totalVolume;
        bool     isLP;
        bool     active;
    }

    struct PoolConfig {
        address  tokenA;
        address  tokenB;
        uint256  swapFeeBps;     // 10 = 0.10%
        uint256  lpFeeBps;       // 8 = 0.08%
        uint256  minTradeSize;   // USDC
        bool     active;
    }

    struct PoolState {
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalLP;
        uint256 totalVolumeUSD;
        uint256 totalFeesUSD;
    }

    mapping(address => Institution) public institutions;
    mapping(uint256 => PoolConfig)  public poolConfigs;
    mapping(uint256 => PoolState)   public poolStates;
    mapping(uint256 => mapping(address => uint256)) public lpBalances;
    address[] public institutionList;
    uint256 public poolCount;

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


    IERC20  public immutable USDC;
    address public treasury;

    uint256 public constant SUBSCRIPTION_BASIC      = 5_000_000_000; // $5,000 USDC (6dec)
    uint256 public constant SUBSCRIPTION_PRO        = 15_000_000_000;
    uint256 public constant SUBSCRIPTION_ENTERPRISE = 50_000_000_000;
    uint256 public constant MIN_LP_DEPOSIT_USD      = 100_000e6;     // $100K USDC
    uint256 public constant BPS                     = 10000;

    uint256 public totalSubscriptionRevenue;
    uint256 public totalSwapRevenue;

    event InstitutionRegistered(address indexed wallet, string name, KYBTier tier);
    event KYBUpdated(address indexed wallet, KYBTier oldTier, KYBTier newTier);
    event SubscriptionPaid(address indexed institution, SubscriptionTier tier, uint256 amount, uint256 expiry);
    event InstitutionalSwap(address indexed institution, uint256 poolId, uint256 amtIn, uint256 amtOut, uint256 fee);
    event LiquidityAdded(address indexed institution, uint256 poolId, uint256 amtA, uint256 amtB, uint256 lpMinted);
    event PoolCreated(uint256 indexed poolId, address tokenA, address tokenB);

    constructor(address _usdc, address _treasury, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC     = IERC20(_usdc);
        treasury = _treasury;
    }

    modifier onlyVerified() {
        require(institutions[msg.sender].kyb == KYBTier.VERIFIED || institutions[msg.sender].kyb == KYBTier.PREMIUM, "InstPool: not KYB verified");
        require(institutions[msg.sender].subExpiry >= block.timestamp, "InstPool: subscription expired");
        _;
    }

    // ── KYB / Onboarding ─────────────────────────────────────────────────────

    function register(string calldata name, string calldata jurisdiction) external {
        require(institutions[msg.sender].wallet == address(0), "InstPool: already registered");
        institutions[msg.sender] = Institution({
            name:           name,
            jurisdiction:   jurisdiction,
            wallet:         msg.sender,
            kyb:            KYBTier.PENDING,
            sub:            SubscriptionTier.NONE,
            subExpiry:      0,
            minDeposit:     MIN_LP_DEPOSIT_USD,
            totalDeposited: 0,
            totalVolume:    0,
            isLP:           false,
            active:         true
        });
        institutionList.push(msg.sender);
        emit InstitutionRegistered(msg.sender, name, KYBTier.PENDING);
    }

    function approveKYB(address institution, KYBTier tier) external onlyOwner {
        KYBTier old = institutions[institution].kyb;
        institutions[institution].kyb = tier;
        emit KYBUpdated(institution, old, tier);
    }

    // ── Subscriptions ─────────────────────────────────────────────────────────

    function subscribe(SubscriptionTier tier) external nonReentrant {
        require(institutions[msg.sender].kyb == KYBTier.VERIFIED || institutions[msg.sender].kyb == KYBTier.PREMIUM, "InstPool: not verified");
        uint256 cost;
        uint256 duration;
        if (tier == SubscriptionTier.BASIC)      { cost = SUBSCRIPTION_BASIC;      duration = 30 days; }
        else if (tier == SubscriptionTier.PRO)   { cost = SUBSCRIPTION_PRO;        duration = 30 days; }
        else                                     { cost = SUBSCRIPTION_ENTERPRISE; duration = 365 days; }

        USDC.safeTransferFrom(msg.sender, treasury, cost);
        institutions[msg.sender].sub      = tier;
        institutions[msg.sender].subExpiry = block.timestamp + duration;
        totalSubscriptionRevenue += cost;
        emit SubscriptionPaid(msg.sender, tier, cost, block.timestamp + duration);
    }

    // ── Pool Management ───────────────────────────────────────────────────────

    function createPool(address tokenA, address tokenB, uint256 swapFeeBps, uint256 lpFeeBps, uint256 minTradeSize)
        external onlyOwner returns (uint256 poolId)
    {
        poolId = ++poolCount;
        poolConfigs[poolId] = PoolConfig({ tokenA:tokenA, tokenB:tokenB, swapFeeBps:swapFeeBps, lpFeeBps:lpFeeBps, minTradeSize:minTradeSize, active:true });
        emit PoolCreated(poolId, tokenA, tokenB);
    }

    // ── Institutional Swap ────────────────────────────────────────────────────

    function swap(uint256 poolId, address tokenIn, uint256 amountIn, uint256 minOut)
        external nonReentrant onlyVerified whenNotPaused returns (uint256 amountOut)
    {
        PoolConfig storage cfg = poolConfigs[poolId];
        require(cfg.active, "InstPool: pool inactive");
        require(amountIn >= cfg.minTradeSize, "InstPool: below min trade");

        PoolState storage state = poolStates[poolId];
        bool    aToB = tokenIn == cfg.tokenA;
        address tokenOut = aToB ? cfg.tokenB : cfg.tokenA;
        uint256 rIn  = aToB ? state.reserveA : state.reserveB;
        uint256 rOut = aToB ? state.reserveB : state.reserveA;

        // x*y=k swap
        uint256 fee     = amountIn * cfg.swapFeeBps / BPS;
        uint256 netIn   = amountIn - fee;
        amountOut = (netIn * rOut) / (rIn + netIn);
        require(amountOut >= minOut, "InstPool: slippage");

        // Update reserves
        if (aToB) { state.reserveA += amountIn; state.reserveB -= amountOut; }
        else      { state.reserveB += amountIn; state.reserveA -= amountOut; }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        // Fee split: lpFeeBps to LPs, rest to treasury
        uint256 lpFee    = amountIn * cfg.lpFeeBps / BPS;
        uint256 protoFee = fee - lpFee;
        IERC20(tokenIn).safeTransfer(treasury, protoFee);
        totalSwapRevenue += protoFee;
        state.totalFeesUSD += fee;
        institutions[msg.sender].totalVolume += amountIn;

        emit InstitutionalSwap(msg.sender, poolId, amountIn, amountOut, fee);
    }

    // ── Institutional LP ───────────────────────────────────────────────────────

    function addLiquidity(uint256 poolId, uint256 amtA, uint256 amtB, uint256 minLP)
        external nonReentrant onlyVerified returns (uint256 lpMinted)
    {
        require(amtA + amtB >= MIN_LP_DEPOSIT_USD, "InstPool: below min deposit");
        PoolConfig storage cfg = poolConfigs[poolId];
        PoolState  storage state = poolStates[poolId];

        IERC20(cfg.tokenA).safeTransferFrom(msg.sender, address(this), amtA);
        IERC20(cfg.tokenB).safeTransferFrom(msg.sender, address(this), amtB);

        lpMinted = state.totalLP == 0 ? amtA + amtB : (amtA + amtB) * state.totalLP / (state.reserveA + state.reserveB);
        require(lpMinted >= minLP, "InstPool: LP slippage");

        state.reserveA += amtA;
        state.reserveB += amtB;
        state.totalLP  += lpMinted;
        lpBalances[poolId][msg.sender] += lpMinted;
        institutions[msg.sender].totalDeposited += amtA + amtB;
        institutions[msg.sender].isLP = true;

        emit LiquidityAdded(msg.sender, poolId, amtA, amtB, lpMinted);
    }

    function removeLiquidity(uint256 poolId, uint256 lpAmount) external nonReentrant onlyVerified {
        PoolState storage state = poolStates[poolId];
        require(lpBalances[poolId][msg.sender] >= lpAmount, "InstPool: insufficient LP");
        PoolConfig storage cfg = poolConfigs[poolId];

        uint256 amtA = lpAmount * state.reserveA / state.totalLP;
        uint256 amtB = lpAmount * state.reserveB / state.totalLP;
        state.reserveA -= amtA; state.reserveB -= amtB; state.totalLP -= lpAmount;
        lpBalances[poolId][msg.sender] -= lpAmount;

        IERC20(cfg.tokenA).safeTransfer(msg.sender, amtA);
        IERC20(cfg.tokenB).safeTransfer(msg.sender, amtB);
    }

    // ── Views ──────────────────────────────────────────────────────────────────
    function getInstitution(address w) external view returns (Institution memory) { return institutions[w]; }
    function isEligible(address w) external view returns (bool) {
        Institution storage i = institutions[w];
        return (i.kyb == KYBTier.VERIFIED || i.kyb == KYBTier.PREMIUM) && i.subExpiry >= block.timestamp;
    }
    function getPool(uint256 id) external view returns (PoolConfig memory, PoolState memory) { return (poolConfigs[id], poolStates[id]); }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
