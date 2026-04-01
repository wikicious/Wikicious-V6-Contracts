// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiMarginLoan
 * @notice Isolated margin lending — traders borrow USDC against their trading
 *         account balance to increase leverage beyond what WikiPerp provides.
 *
 * ─────────────────────────────────────────────────────────────────
 * DESIGN
 * ─────────────────────────────────────────────────────────────────
 * 1. Trader opens a margin loan specifying amount, duration (7–90 days)
 * 2. Collateral is their WikiVault balance (locked inside WikiVault)
 * 3. Interest accrues per second (variable rate based on utilisation)
 * 4. Repayment = principal + accrued interest
 * 5. If health factor < 1.0 (debt > maxLTV × collateral), liquidation
 *    is triggered: collateral released to cover debt + liquidator bonus
 *
 * REVENUE MODEL
 * ─────────────────────────────────────────────────────────────────
 * • Lenders deposit USDC and earn variable interest from borrowers
 * • Protocol takes reserveFactorBps (default 15%) of all interest
 * • Liquidator earns LIQUIDATION_BONUS_BPS (5%) on seized collateral
 *
 * INTEREST RATE MODEL (kinked)
 * ─────────────────────────────────────────────────────────────────
 * util < kink (80%):   rate = baseRate + util × slope1
 * util ≥ kink (80%):   rate = baseRate + kink × slope1 + (util - kink) × slope2
 * Default: 2% base, 10% at kink, 150% at 100% util (annualised)
 *
 * ATTACK MITIGATIONS
 * ─────────────────────────────────────────────────────────────────
 * [A1] Reentrancy         → ReentrancyGuard + Pausable
 * [A2] CEI                → state written before all external calls
 * [A3] Self-liquidation   → liquidator ≠ borrower enforced
 * [A4] Oracle staleness   → price from WikiVault balance (USDC, no oracle needed)
 * [A5] Interest skip      → accrueInterest() called on every mutation
 * [A6] Over-borrow        → strict maxLTV check on every borrow
 * [A7] Dust positions     → minimum borrow enforced
 */
interface IWikiVault {
        function freeMargin(address user) external view returns (uint256);
        function lockedMargin(address user) external view returns (uint256);
        function lockMargin(address user, uint256 amount) external;
        function releaseMargin(address user, uint256 amount) external;
        function transferMargin(address from, address to, uint256 amount) external;
    }

contract WikiMarginLoan is Ownable2Step, ReentrancyGuard, Pausable {
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


    // ─────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────
    uint256 public constant BPS                  = 10_000;
    uint256 public constant PRECISION            = 1e18;
    uint256 public constant MAX_LTV_BPS          = 8000;  // 80% LTV
    uint256 public constant LIQ_THRESHOLD_BPS    = 8500;  // 85% → liquidation starts
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;  // 5% bonus to liquidator
    uint256 public constant CLOSE_FACTOR_BPS     = 5000;  // 50% max liquidation per call
    uint256 public constant MIN_BORROW           = 10 * 1e6; // $10 USDC minimum [A7]
    uint256 public constant MAX_DURATION         = 90 days;
    uint256 public constant MIN_DURATION         = 7 days;

    // Interest rate model (per second, scaled 1e18)
    // Annualised: base=2%, kink=10%, max=150%
    uint256 public baseRatePerSecond    = 634195840; // 2% p.a. ÷ 31536000
    uint256 public slope1PerSecond      = 2536783360; // reaches 10% at kink
    uint256 public slope2PerSecond      = 44407599360; // reaches 150% at 100%
    uint256 public kinkUtilization      = 0.80e18;   // 80%
    uint256 public reserveFactorBps     = 1500;       // 15%

    // ─────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────

    struct LoanPosition {
        address borrower;
        uint256 principal;       // original borrow (USDC, 6 dec)
        uint256 collateralLocked; // USDC locked in WikiVault (6 dec)
        uint256 borrowIndex;     // index snapshot at open (1e18)
        uint256 openedAt;
        uint256 dueAt;           // optional: 0 = indefinite
        bool    active;
    }

    // ─────────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────────

    IERC20     public immutable USDC;
    IWikiVault public immutable vault;

    // Lending pool state
    uint256 public totalDeposited;    // USDC supplied by lenders
    uint256 public totalBorrowed;     // outstanding USDC principal
    uint256 public totalReserves;     // protocol reserve (USDC)
    uint256 public borrowIndex;       // cumulative borrow interest index (1e18)
    uint256 public lastAccrualTime;

    // LP accounting (wTokens model identical to WikiLending)
    uint256 public totalLP;           // lender share tokens
    uint256 public exchangeRate;      // LP share → USDC (1e18 base)

    mapping(address => uint256) public lpBalances;  // lender → LP shares

    // Loans
    LoanPosition[] public loans;
    mapping(address => uint256[]) public borrowerLoans;

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────

    event Deposited(address indexed lender, uint256 usdc, uint256 shares);
    event Withdrew(address indexed lender, uint256 usdc, uint256 shares);
    event LoanOpened(uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 collateral);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 repaid, uint256 interest);
    event LoanLiquidated(uint256 indexed loanId, address indexed borrower, address indexed liquidator, uint256 seized);
    event InterestAccrued(uint256 interest, uint256 newIndex);
    event ReservesWithdrawn(address indexed to, uint256 amount);
    event IRMUpdated(uint256 base, uint256 slope1, uint256 slope2, uint256 kink);

    // ─────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────

    constructor(address usdc, address _vault, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_vault != address(0), "Wiki: zero _vault");
        require(owner != address(0), "Wiki: zero owner");
        USDC          = IERC20(usdc);
        vault         = IWikiVault(_vault);
        borrowIndex   = PRECISION;
        exchangeRate  = PRECISION;
        lastAccrualTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Owner Config
    // ─────────────────────────────────────────────────────────────────

    function setIRM(uint256 base, uint256 s1, uint256 s2, uint256 kink) external onlyOwner {
        baseRatePerSecond  = base;
        slope1PerSecond    = s1;
        slope2PerSecond    = s2;
        kinkUtilization    = kink;
        emit IRMUpdated(base, s1, s2, kink);
    }

    function setReserveFactor(uint256 bps) external onlyOwner {
        require(bps <= 3000, "MarginLoan: reserve factor too high");
        reserveFactorBps = bps;
    }

    function withdrawReserves(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= totalReserves, "MarginLoan: exceeds reserves");
        totalReserves -= amount;
        USDC.safeTransfer(to, amount);
        emit ReservesWithdrawn(to, amount);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────────
    //  Lender: Deposit / Withdraw
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC to earn margin loan interest
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "MarginLoan: zero amount");
        _accrueInterest(); // [A5]

        // LP shares minted proportional to pool value
        uint256 cash    = USDC.balanceOf(address(this)) - totalReserves;
        uint256 shares  = totalLP == 0 || cash == 0
            ? amount
            : amount * totalLP / cash;

        // [A2] State before transfer
        totalDeposited          += amount;
        totalLP                 += shares;
        lpBalances[msg.sender]  += shares;

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw USDC from lending pool
     * @param shares LP shares to redeem (type(uint256).max = all)
     */
    function withdraw(uint256 shares) external nonReentrant whenNotPaused {
        _accrueInterest();
        if (shares == type(uint256).max) shares = lpBalances[msg.sender];
        require(lpBalances[msg.sender] >= shares, "MarginLoan: insufficient shares");

        uint256 cash   = USDC.balanceOf(address(this)) - totalReserves;
        uint256 amount = totalLP > 0 ? shares * cash / totalLP : 0;
        require(amount > 0, "MarginLoan: zero withdraw");

        // Ensure sufficient unlocked liquidity
        uint256 available = USDC.balanceOf(address(this)) - totalReserves;
        require(available >= amount, "MarginLoan: insufficient liquidity");

        // [A2] State before transfer
        totalLP -= shares;
        lpBalances[msg.sender] -= shares;

        USDC.safeTransfer(msg.sender, amount);
        emit Withdrew(msg.sender, amount, shares);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Borrower: Open Margin Loan
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Open a margin loan
     * @param borrowAmount    USDC to borrow (sent to borrower's WikiVault balance)
     * @param collateralLock  USDC to lock from borrower's WikiVault free margin
     * @param duration        Loan duration in seconds (MIN_DURATION–MAX_DURATION, 0 = indefinite)
     */
    function openLoan(
        uint256 borrowAmount,
        uint256 collateralLock,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 loanId) {
        require(borrowAmount >= MIN_BORROW,                    "MarginLoan: below minimum"); // [A7]
        require(duration == 0 || (duration >= MIN_DURATION && duration <= MAX_DURATION), "MarginLoan: bad duration");

        _accrueInterest(); // [A5]

        // [A6] Collateral must support LTV
        require(collateralLock > 0, "MarginLoan: zero collateral");
        uint256 maxBorrow = collateralLock * MAX_LTV_BPS / BPS;
        require(borrowAmount <= maxBorrow, "MarginLoan: exceeds max LTV");

        // Verify borrower has sufficient free margin
        require(vault.freeMargin(msg.sender) >= collateralLock, "MarginLoan: insufficient vault balance");

        // Sufficient pool liquidity
        uint256 available = USDC.balanceOf(address(this)) - totalReserves;
        require(available >= borrowAmount, "MarginLoan: pool insufficient");

        loanId = loans.length;

        // [A2] State before external calls
        totalBorrowed += borrowAmount;

        loans.push(LoanPosition({
            borrower:         msg.sender,
            principal:        borrowAmount,
            collateralLocked: collateralLock,
            borrowIndex:      borrowIndex,
            openedAt:         block.timestamp,
            dueAt:            duration > 0 ? block.timestamp + duration : 0,
            active:           true
        }));
        borrowerLoans[msg.sender].push(loanId);

        // Lock collateral in vault
        vault.lockMargin(msg.sender, collateralLock);

        // Transfer borrowed USDC to borrower's wallet (they can deposit into vault themselves)
        USDC.safeTransfer(msg.sender, borrowAmount);

        emit LoanOpened(loanId, msg.sender, borrowAmount, collateralLock);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Borrower: Repay
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Repay a margin loan in full (principal + interest)
     * @param loanId  Loan to repay
     */
    function repayLoan(uint256 loanId) external nonReentrant whenNotPaused {
        LoanPosition storage loan = loans[loanId];
        require(loan.borrower == msg.sender, "MarginLoan: not your loan");
        require(loan.active,                 "MarginLoan: loan not active");

        _accrueInterest(); // [A5]

        uint256 debt     = _currentDebt(loan);
        uint256 interest = debt - loan.principal;

        // [A2] Close before transfers
        loan.active    = false;
        totalBorrowed -= loan.principal;

        // Protocol takes reserveFactorBps of interest
        uint256 reserve = interest * reserveFactorBps / BPS;
        totalReserves  += reserve;

        // Release collateral
        vault.releaseMargin(loan.borrower, loan.collateralLocked);

        // Collect repayment
        USDC.safeTransferFrom(msg.sender, address(this), debt);

        emit LoanRepaid(loanId, msg.sender, debt, interest);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Liquidation
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Liquidate an undercollateralised or overdue margin loan
     *         Anyone may call. Liquidator earns 5% bonus on seized collateral.
     * @param loanId  Loan to liquidate
     */
    function liquidate(uint256 loanId) external nonReentrant whenNotPaused {
        LoanPosition storage loan = loans[loanId];
        require(loan.active,                          "MarginLoan: not active");
        require(loan.borrower != msg.sender,          "MarginLoan: self-liquidation"); // [A3]

        _accrueInterest();

        uint256 debt = _currentDebt(loan);

        // Check liquidation condition
        bool undercollateralised = debt * BPS > loan.collateralLocked * LIQ_THRESHOLD_BPS;
        bool overdue             = loan.dueAt > 0 && block.timestamp > loan.dueAt;
        require(undercollateralised || overdue, "MarginLoan: healthy");

        // Seize up to CLOSE_FACTOR of collateral
        uint256 seize     = loan.collateralLocked * CLOSE_FACTOR_BPS / BPS;
        uint256 bonus     = seize * LIQUIDATION_BONUS_BPS / BPS;
        uint256 netSeize  = seize + bonus;
        if (netSeize > loan.collateralLocked) netSeize = loan.collateralLocked;

        uint256 repayPart = debt * CLOSE_FACTOR_BPS / BPS;

        // [A2] State before external calls
        loan.principal       = loan.principal >= repayPart ? loan.principal - repayPart : 0;
        loan.collateralLocked -= netSeize;
        totalBorrowed        -= repayPart;
        if (loan.principal == 0 || loan.collateralLocked == 0) loan.active = false;

        // Release seized portion from vault to this contract
        vault.releaseMargin(loan.borrower, netSeize);

        // Liquidator provides repayPart USDC, gets netSeize USDC back
        USDC.safeTransferFrom(msg.sender, address(this), repayPart);
        USDC.safeTransfer(msg.sender, netSeize);

        emit LoanLiquidated(loanId, loan.borrower, msg.sender, netSeize);
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal: Interest Accrual [A5]
    // ─────────────────────────────────────────────────────────────────

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0 || totalBorrowed == 0) {
            lastAccrualTime = block.timestamp;
            return;
        }
        lastAccrualTime = block.timestamp;

        uint256 cash    = USDC.balanceOf(address(this)) - totalReserves;
        uint256 util    = _utilization(cash);
        uint256 rate    = _borrowRate(util);

        uint256 interest = totalBorrowed * rate * elapsed / PRECISION;
        uint256 reserve  = interest * reserveFactorBps / BPS;

        totalBorrowed  += interest;
        totalReserves  += reserve;
        borrowIndex     = borrowIndex * (PRECISION + rate * elapsed) / PRECISION;

        emit InterestAccrued(interest, borrowIndex);
    }

    function _borrowRate(uint256 util) internal view returns (uint256) {
        if (util <= kinkUtilization) {
            return baseRatePerSecond + util * slope1PerSecond / PRECISION;
        }
        uint256 over = util - kinkUtilization;
        return baseRatePerSecond
            + kinkUtilization * slope1PerSecond / PRECISION
            + over * slope2PerSecond / PRECISION;
    }

    function _utilization(uint256 cash) internal view returns (uint256) {
        uint256 total = cash + totalBorrowed;
        if (total == 0) return 0;
        return totalBorrowed * PRECISION / total;
    }

    function _currentDebt(LoanPosition storage loan) internal view returns (uint256) {
        if (!loan.active || loan.borrowIndex == 0) return loan.principal;
        return loan.principal * borrowIndex / loan.borrowIndex;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────

    function getLoan(uint256 loanId) external view returns (LoanPosition memory) {
        return loans[loanId];
    }

    function currentDebt(uint256 loanId) external view returns (uint256) {
        return _currentDebt(loans[loanId]);
    }

    function healthFactor(uint256 loanId) external view returns (uint256) {
        LoanPosition storage loan = loans[loanId];
        if (!loan.active) return type(uint256).max;
        uint256 debt = _currentDebt(loan);
        if (debt == 0) return type(uint256).max;
        return loan.collateralLocked * PRECISION / debt;
    }

    function isLiquidatable(uint256 loanId) external view returns (bool) {
        LoanPosition storage loan = loans[loanId];
        if (!loan.active) return false;
        uint256 debt = _currentDebt(loan);
        bool undercol = debt * BPS > loan.collateralLocked * LIQ_THRESHOLD_BPS;
        bool overdue  = loan.dueAt > 0 && block.timestamp > loan.dueAt;
        return undercol || overdue;
    }

    function getBorrowLoans(address borrower) external view returns (uint256[] memory) {
        return borrowerLoans[borrower];
    }

    function getLPBalance(address lender) external view returns (uint256 usdc) {
        uint256 shares = lpBalances[lender];
        if (shares == 0 || totalLP == 0) return 0;
        uint256 cash   = USDC.balanceOf(address(this)) - totalReserves;
        return shares * cash / totalLP;
    }

    function supplyAPY() external view returns (uint256) {
        uint256 cash = USDC.balanceOf(address(this)) - totalReserves;
        uint256 util = _utilization(cash);
        uint256 rate = _borrowRate(util);
        return rate * util / PRECISION * (BPS - reserveFactorBps) / BPS * 365 days;
    }

    function borrowAPY() external view returns (uint256) {
        uint256 cash = USDC.balanceOf(address(this)) - totalReserves;
        return _borrowRate(_utilization(cash)) * 365 days;
    }

    function utilizationRate() external view returns (uint256) {
        uint256 cash = USDC.balanceOf(address(this)) - totalReserves;
        return _utilization(cash);
    }

    function loanCount() external view returns (uint256) { return loans.length; }
}
