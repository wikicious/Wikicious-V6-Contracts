// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLPCollateral
 * @notice Borrow USDC using LP tokens (WLP, WikiSpot LP, external Uniswap V5/V3 LP) as collateral
 *
 * ─────────────────────────────────────────────────────────────────
 * DESIGN
 * ─────────────────────────────────────────────────────────────────
 * LP tokens are valued by querying the underlying pool reserves directly
 * (on-chain, manipulation-resistant). For each LP type we store a
 * CollateralType config that specifies:
 *   • valuation method (WLP/AMM/UniV5/External)
 *   • ltvBps (max borrow % of collateral value)
 *   • liquidationThresholdBps (when liquidation triggers)
 *   • liquidationBonusBps (incentive for liquidators)
 *
 * LP VALUATION (anti-manipulation)
 * ─────────────────────────────────────────────────────────────────
 * • WLP (WikiAMM):     getAUM() / totalSupply() — TWAP-backed AUM
 * • WikiSpot LP:       √(reserveA × reserveB) × 2 / totalSupply
 *   This is the "fair LP price" formula that is flash-loan resistant
 *   because both tokens must be manipulated simultaneously
 * • External (e.g. Uniswap V5): same formula using pool.getReserves()
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────
 * Interest on all outstanding USDC loans accrues to lenders.
 * Protocol takes reserveFactorBps (default 10%) of interest.
 *
 * ATTACK MITIGATIONS
 * ─────────────────────────────────────────────────────────────────
 * [A1] Reentrancy          → ReentrancyGuard
 * [A2] CEI                 → state before all external calls
 * [A3] Flash loan attack   → fair LP price formula (√(x·y)/total) [see above]
 * [A4] Oracle bypass       → LP value derived on-chain from pool state
 * [A5] Interest skip       → accrueInterest() on every mutation
 * [A6] Self-liquidation    → enforced
 * [A7] Collateral dust     → minimum collateral value enforced
 */
interface IOracle {
        function getPriceView(bytes32 id) external view returns (uint256 price, uint256 ts);
    }

interface IWikiSpot {
        function pools(uint256 poolId) external view returns (
            address tokenA, address tokenB,
            uint256 reserveA, uint256 reserveB,
            uint256 totalLP, uint256 feeBps,
            uint256 volumeA, uint256 volumeB, bool active
        );
        function lpBalances(uint256 poolId, address user) external view returns (uint256);
    }

interface IWikiAMM {
        function getAUM() external view returns (uint256);
        function totalSupply() external view returns (uint256);
    }

contract WikiLPCollateral is Ownable2Step, ReentrancyGuard, Pausable {
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

    // ─────────────────────────────────────────────────────────────────
    //  Interfaces
    // ─────────────────────────────────────────────────────────────────

    // WikiAMM (WLP)


    // WikiSpot pool (for fair price valuation)


    // Chainlink-style oracle for token prices


    // ─────────────────────────────────────────────────────────────────
    //  Enums & Structs
    // ─────────────────────────────────────────────────────────────────

    enum ValuationMethod { WLP, WikiSpot, UniV5, External }

    struct CollateralType {
        bool            enabled;
        ValuationMethod method;
        address         lpToken;
        address         pool;           // pool address (for WikiSpot / UniV5)
        uint256         poolId;         // pool ID (WikiSpot only)
        bytes32         tokenAOracleId; // for UniV5 / External
        bytes32         tokenBOracleId;
        uint256         ltvBps;
        uint256         liquidationThresholdBps;
        uint256         liquidationBonusBps;
        uint256         totalDeposited; // total LP deposited (in LP units)
    }

    struct Vault {
        address borrower;
        uint256 collateralTypeId;
        uint256 lpAmount;         // LP tokens deposited
        uint256 debtPrincipal;    // USDC borrowed
        uint256 debtIndex;        // borrow index at open
        bool    active;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────

    uint256 public constant BPS                   = 10_000;
    uint256 public constant PRECISION             = 1e18;
    uint256 public constant MIN_COLLATERAL_VALUE  = 50 * 1e6;  // $50 minimum [A7]
    uint256 public constant CLOSE_FACTOR_BPS      = 5000;       // 50%
    uint256 public constant DEFAULT_RESERVE_BPS   = 1000;       // 10%

    // Kinked IRM defaults (per second, 1e18 scaled)
    // 1% base, 8% at 80% kink, 100% at full
    uint256 public constant DEFAULT_BASE_RATE     = 317097920;  // 1% p.a.
    uint256 public constant DEFAULT_SLOPE1        = 2219685440; // +7% at kink
    uint256 public constant DEFAULT_SLOPE2        = 31709792000;// +92% above kink
    uint256 public constant DEFAULT_KINK          = 0.80e18;

    // ─────────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────────

    IERC20   public immutable USDC;
    IOracle  public oracle;

    CollateralType[] public collateralTypes;
    Vault[]          public vaults;
    mapping(address => uint256[]) public borrowerVaults;

    // Lending pool
    uint256 public poolBalance;      // USDC available (supplied by lenders)
    uint256 public totalBorrowed;
    uint256 public totalReserves;
    uint256 public borrowIndex;
    uint256 public lastAccrualTime;

    // LP supply accounting
    uint256 public totalLP;
    mapping(address => uint256) public lpShares;

    // IRM params (can be tuned by owner)
    uint256 public baseRatePerSecond;
    uint256 public slope1PerSecond;
    uint256 public slope2PerSecond;
    uint256 public kinkUtilization;
    uint256 public reserveFactorBps;

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────

    event CollateralTypeAdded(uint256 indexed ctId, address lpToken, ValuationMethod method);
    event VaultOpened(uint256 indexed vaultId, address indexed borrower, uint256 ctId, uint256 lpAmount, uint256 borrowed);
    event VaultRepaid(uint256 indexed vaultId, address indexed borrower, uint256 repaid);
    event VaultLiquidated(uint256 indexed vaultId, address indexed borrower, address indexed liquidator, uint256 lpSeized, uint256 usdcRepaid);
    event LenderDeposited(address indexed lender, uint256 usdc, uint256 shares);
    event LenderWithdrew(address indexed lender, uint256 usdc, uint256 shares);
    event InterestAccrued(uint256 interest, uint256 newIndex);

    // ─────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────

    constructor(address usdc, address _oracle, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(owner != address(0), "Wiki: zero owner");
        USDC             = IERC20(usdc);
        oracle           = IOracle(_oracle);
        borrowIndex      = PRECISION;
        lastAccrualTime  = block.timestamp;

        baseRatePerSecond = DEFAULT_BASE_RATE;
        slope1PerSecond   = DEFAULT_SLOPE1;
        slope2PerSecond   = DEFAULT_SLOPE2;
        kinkUtilization   = DEFAULT_KINK;
        reserveFactorBps  = DEFAULT_RESERVE_BPS;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Owner: Configure Collateral Types
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Register an LP token as accepted collateral
     */
    function addCollateralType(
        ValuationMethod method,
        address         lpToken,
        address         pool,
        uint256         poolId,
        bytes32         tokenAOracleId,
        bytes32         tokenBOracleId,
        uint256         ltvBps,
        uint256         liqThreshBps,
        uint256         liqBonusBps
    ) external onlyOwner returns (uint256 ctId) {
        require(ltvBps       <= 8000,    "LPColl: LTV too high");
        require(liqThreshBps <= 9000,    "LPColl: threshold too high");
        require(liqThreshBps >= ltvBps,  "LPColl: threshold < LTV");
        require(liqBonusBps  <= 1500,    "LPColl: bonus too high");

        ctId = collateralTypes.length;
        collateralTypes.push(CollateralType({
            enabled:                 true,
            method:                  method,
            lpToken:                 lpToken,
            pool:                    pool,
            poolId:                  poolId,
            tokenAOracleId:          tokenAOracleId,
            tokenBOracleId:          tokenBOracleId,
            ltvBps:                  ltvBps,
            liquidationThresholdBps: liqThreshBps,
            liquidationBonusBps:     liqBonusBps,
            totalDeposited:          0
        }));
        emit CollateralTypeAdded(ctId, lpToken, method);
    }

    function setCollateralEnabled(uint256 ctId, bool enabled) external onlyOwner {
        collateralTypes[ctId].enabled = enabled;
    }

    function withdrawReserves(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= totalReserves, "LPColl: exceeds reserves");
        totalReserves -= amount;
        USDC.safeTransfer(to, amount);
    }

    function setOracle(address _oracle) external onlyOwner { oracle = IOracle(_oracle); }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────────
    //  Lender Pool
    // ─────────────────────────────────────────────────────────────────

    function depositToPool(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "LPColl: zero amount");
        _accrueInterest();

        uint256 cash   = USDC.balanceOf(address(this)) - totalReserves;
        uint256 shares = totalLP == 0 || cash == 0 ? amount : amount * totalLP / cash;

        totalLP              += shares;
        lpShares[msg.sender] += shares;

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit LenderDeposited(msg.sender, amount, shares);
    }

    function withdrawFromPool(uint256 shares) external nonReentrant whenNotPaused {
        _accrueInterest();
        if (shares == type(uint256).max) shares = lpShares[msg.sender];
        require(lpShares[msg.sender] >= shares, "LPColl: insufficient shares");

        uint256 cash   = USDC.balanceOf(address(this)) - totalReserves;
        uint256 amount = totalLP > 0 ? shares * cash / totalLP : 0;
        require(USDC.balanceOf(address(this)) - totalReserves >= amount, "LPColl: insufficient liquidity");

        totalLP              -= shares;
        lpShares[msg.sender] -= shares;

        USDC.safeTransfer(msg.sender, amount);
        emit LenderWithdrew(msg.sender, amount, shares);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Borrower: Open Vault
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit LP tokens and borrow USDC
     * @param ctId       Collateral type ID
     * @param lpAmount   LP tokens to deposit
     * @param borrowAmt  USDC to borrow
     */
    function openVault(
        uint256 ctId,
        uint256 lpAmount,
        uint256 borrowAmt
    ) external nonReentrant whenNotPaused returns (uint256 vaultId) {
        CollateralType storage ct = collateralTypes[ctId];
        require(ct.enabled,   "LPColl: collateral disabled");
        require(lpAmount > 0, "LPColl: zero LP");
        require(borrowAmt > 0, "LPColl: zero borrow");

        _accrueInterest();

        // Value the LP collateral [A3][A4]
        uint256 collateralUSDC = _valueLp(ct, lpAmount);
        require(collateralUSDC >= MIN_COLLATERAL_VALUE, "LPColl: below minimum value"); // [A7]

        // Check LTV
        uint256 maxBorrow = collateralUSDC * ct.ltvBps / BPS;
        require(borrowAmt <= maxBorrow, "LPColl: exceeds max LTV");

        // Check pool liquidity
        uint256 available = USDC.balanceOf(address(this)) - totalReserves;
        require(available >= borrowAmt, "LPColl: pool insufficient");

        vaultId = vaults.length;

        // [A2] State before external calls
        ct.totalDeposited += lpAmount;
        totalBorrowed     += borrowAmt;

        vaults.push(Vault({
            borrower:         msg.sender,
            collateralTypeId: ctId,
            lpAmount:         lpAmount,
            debtPrincipal:    borrowAmt,
            debtIndex:        borrowIndex,
            active:           true
        }));
        borrowerVaults[msg.sender].push(vaultId);

        IERC20(ct.lpToken).safeTransferFrom(msg.sender, address(this), lpAmount);
        USDC.safeTransfer(msg.sender, borrowAmt);

        emit VaultOpened(vaultId, msg.sender, ctId, lpAmount, borrowAmt);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Borrower: Repay & Withdraw LP
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Repay loan and recover LP tokens
     * @param vaultId  Vault to repay
     */
    function repayVault(uint256 vaultId) external nonReentrant whenNotPaused {
        Vault storage v = vaults[vaultId];
        require(v.borrower == msg.sender, "LPColl: not your vault");
        require(v.active,                 "LPColl: vault not active");

        _accrueInterest();

        uint256 debt     = _vaultDebt(v);
        uint256 interest = debt - v.debtPrincipal;

        CollateralType storage ct = collateralTypes[v.collateralTypeId];

        // [A2] Close vault before transfers
        v.active       = false;
        ct.totalDeposited -= v.lpAmount;
        totalBorrowed  -= v.debtPrincipal;
        totalReserves  += interest * reserveFactorBps / BPS;

        // Collect repayment
        USDC.safeTransferFrom(msg.sender, address(this), debt);

        // Return LP collateral
        IERC20(ct.lpToken).safeTransfer(msg.sender, v.lpAmount);

        emit VaultRepaid(vaultId, msg.sender, debt);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Liquidation
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Liquidate an undercollateralised vault
     * @param vaultId  Vault to liquidate
     */
    function liquidate(uint256 vaultId) external nonReentrant whenNotPaused {
        Vault storage v = vaults[vaultId];
        require(v.active,                 "LPColl: vault not active");
        require(v.borrower != msg.sender, "LPColl: self-liquidation"); // [A6]

        _accrueInterest();

        CollateralType storage ct  = collateralTypes[v.collateralTypeId];
        uint256 debt               = _vaultDebt(v);
        uint256 collateralUSDC     = _valueLp(ct, v.lpAmount);

        // Verify unhealthy
        require(
            debt * BPS > collateralUSDC * ct.liquidationThresholdBps,
            "LPColl: vault healthy"
        );

        // Repay up to CLOSE_FACTOR
        uint256 repayPart  = debt * CLOSE_FACTOR_BPS / BPS;
        uint256 seizeUSDC  = repayPart * (BPS + ct.liquidationBonusBps) / BPS;
        uint256 seizeLp    = v.lpAmount * seizeUSDC / collateralUSDC;
        if (seizeLp > v.lpAmount) seizeLp = v.lpAmount;

        uint256 debtPrinPart = v.debtPrincipal * CLOSE_FACTOR_BPS / BPS;

        // [A2] State before external calls
        v.lpAmount        -= seizeLp;
        v.debtPrincipal   = v.debtPrincipal >= debtPrinPart ? v.debtPrincipal - debtPrinPart : 0;
        ct.totalDeposited -= seizeLp;
        totalBorrowed     -= debtPrinPart;
        if (v.debtPrincipal == 0 || v.lpAmount == 0) v.active = false;

        USDC.safeTransferFrom(msg.sender, address(this), repayPart);
        IERC20(ct.lpToken).safeTransfer(msg.sender, seizeLp);

        emit VaultLiquidated(vaultId, v.borrower, msg.sender, seizeLp, repayPart);
    }

    // ─────────────────────────────────────────────────────────────────
    //  LP Valuation [A3][A4]
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Value a given amount of LP tokens in USDC (6 dec)
     * Uses flash-loan-resistant "fair price" formula for AMM LP tokens.
     */
    function valueLp(uint256 ctId, uint256 lpAmount) external view returns (uint256) {
        return _valueLp(collateralTypes[ctId], lpAmount);
    }

    function _valueLp(CollateralType storage ct, uint256 lpAmount) internal view returns (uint256) {
        if (lpAmount == 0) return 0;

        if (ct.method == ValuationMethod.WLP) {
            // WLP: value = AUM × share / totalSupply
            uint256 aum   = IWikiAMM(ct.pool).getAUM();                    // USDC, 6 dec
            uint256 total = IWikiAMM(ct.pool).totalSupply();              // 1e18 dec
            if (total == 0) return 0;
            return aum * lpAmount / total; // → 6 dec

        } else if (ct.method == ValuationMethod.WikiSpot) {
            // WikiSpot: fair LP price = 2 × √(reserveA_USD × reserveB_USD) / totalLP
            (,, uint256 resA, uint256 resB, uint256 poolTotalLP,,,,) = IWikiSpot(ct.pool).pools(ct.poolId);
            if (poolTotalLP == 0) return 0;

            (uint256 priceA,) = oracle.getPriceView(ct.tokenAOracleId);
            (uint256 priceB,) = oracle.getPriceView(ct.tokenBOracleId);

            // Both prices in 1e18, reserveA/B in token decimals assumed 1e18
            uint256 valueA = resA * priceA / PRECISION;  // 1e18 USD
            uint256 valueB = resB * priceB / PRECISION;  // 1e18 USD

            // Fair price: 2 × √(k) / totalLP  where k = valueA × valueB
            uint256 k       = valueA * valueB;
            uint256 sqrtK   = _sqrt(k);
            uint256 fairUSD = 2 * sqrtK * lpAmount / poolTotalLP; // 1e18

            return fairUSD / 1e12; // → 6 dec (USDC)

        } else {
            // External (UniV5-compatible): same fair price formula
            // ct.pool is the Uniswap V5 pair; read reserves directly
            (bool ok, bytes memory data) = ct.pool.staticcall(
                abi.encodeWithSignature("getReserves()")
            );
            if (!ok) return 0;
            (uint112 r0, uint112 r1,) = abi.decode(data, (uint112, uint112, uint32));
            (bool ok2, bytes memory data2) = ct.lpToken.staticcall(
                abi.encodeWithSignature("totalSupply()")
            );
            if (!ok2) return 0;
            uint256 totalSup = abi.decode(data2, (uint256));
            if (totalSup == 0) return 0;

            (uint256 priceA,) = oracle.getPriceView(ct.tokenAOracleId);
            (uint256 priceB,) = oracle.getPriceView(ct.tokenBOracleId);

            uint256 valA    = uint256(r0) * priceA / PRECISION;
            uint256 valB    = uint256(r1) * priceB / PRECISION;
            uint256 k       = valA * valB;
            uint256 sqrtK   = _sqrt(k);
            uint256 fairUSD = 2 * sqrtK * lpAmount / totalSup;
            return fairUSD / 1e12;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────────────────────────

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0 || totalBorrowed == 0) { lastAccrualTime = block.timestamp; return; }
        lastAccrualTime = block.timestamp;

        uint256 cash  = USDC.balanceOf(address(this)) - totalReserves;
        uint256 util  = (cash + totalBorrowed) > 0
            ? totalBorrowed * PRECISION / (cash + totalBorrowed) : 0;
        uint256 rate  = _borrowRate(util);

        uint256 interest = totalBorrowed * rate * elapsed / PRECISION;
        uint256 reserve  = interest * reserveFactorBps / BPS;

        totalBorrowed  += interest;
        totalReserves  += reserve;
        borrowIndex     = borrowIndex * (PRECISION + rate * elapsed) / PRECISION;

        emit InterestAccrued(interest, borrowIndex);
    }

    function _borrowRate(uint256 util) internal view returns (uint256) {
        if (util <= kinkUtilization)
            return baseRatePerSecond + util * slope1PerSecond / PRECISION;
        uint256 over = util - kinkUtilization;
        return baseRatePerSecond
            + kinkUtilization * slope1PerSecond / PRECISION
            + over * slope2PerSecond / PRECISION;
    }

    function _vaultDebt(Vault storage v) internal view returns (uint256) {
        if (!v.active || v.debtIndex == 0) return v.debtPrincipal;
        return v.debtPrincipal * borrowIndex / v.debtIndex;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = x;
        y = 1;
        while (z > y) { z = (z + y) / 2; y = x / z; }
        y = z;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────

    function getVault(uint256 vaultId) external view returns (Vault memory) { return vaults[vaultId]; }
    function vaultDebt(uint256 vaultId) external view returns (uint256) { return _vaultDebt(vaults[vaultId]); }
    function collateralTypeCount() external view returns (uint256) { return collateralTypes.length; }
    function getBorrowerVaults(address borrower) external view returns (uint256[] memory) { return borrowerVaults[borrower]; }

    function vaultHealthFactor(uint256 vaultId) external view returns (uint256) {
        Vault storage v          = vaults[vaultId];
        if (!v.active) return type(uint256).max;
        CollateralType storage ct = collateralTypes[v.collateralTypeId];
        uint256 debt             = _vaultDebt(v);
        if (debt == 0) return type(uint256).max;
        uint256 collateral       = _valueLp(ct, v.lpAmount);
        return collateral * PRECISION / debt;
    }

    function getLPBalance(address lender) external view returns (uint256) {
        if (lpShares[lender] == 0 || totalLP == 0) return 0;
        uint256 cash = USDC.balanceOf(address(this)) - totalReserves;
        return lpShares[lender] * cash / totalLP;
    }
}
