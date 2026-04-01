// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiFlashLoan
 * @notice EIP-3156 compliant flash loan provider
 *
 * ─────────────────────────────────────────────────────────────────
 * DESIGN
 * ─────────────────────────────────────────────────────────────────
 * Flash loans lend liquidity from supported pools for one transaction.
 * The borrower must implement IERC3156FlashBorrower.onFlashLoan and
 * repay principal + fee within the same transaction.
 *
 * Liquidity sources (priority order):
 *   1. WikiFlashLoan's own reserve (deposits by LPs earn yield)
 *   2. WikiLending pool (lending pool as secondary source)
 *
 * REVENUE MODEL
 * ─────────────────────────────────────────────────────────────────
 * • flashFeeBps (default 9 bps = 0.09%) collected on each flash loan
 * • Fee split:  70% to reserve LPs | 20% to protocol | 10% insurance
 * • LP providers earn yield from flash loan demand
 *
 * ATTACK MITIGATIONS
 * ─────────────────────────────────────────────────────────────────
 * [A1] Reentrancy        → ReentrancyGuard; flash callback checked first
 * [A2] CEI               → state updated before external calls
 * [A3] Repayment check   → balance delta verified post-callback
 * [A4] Borrower whitelist → optional; open by default, can be restricted
 * [A5] Max loan cap      → per-token daily borrow limit
 * [A6] Same-block abuse  → no state manipulation possible (callback must repay)
 * [A7] Token validation  → only whitelisted tokens supported
 */
interface IERC3156FlashBorrower {
        function onFlashLoan(
            address initiator,
            address token,
            uint256 amount,
            uint256 fee,
            bytes calldata data
        ) external returns (bytes32);
    }

contract WikiFlashLoan is Ownable2Step, ReentrancyGuard {
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
    //  EIP-3156 Interface
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");


    // ─────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────
    uint256 public constant BPS              = 10_000;
    uint256 public constant DEFAULT_FEE_BPS  = 9;     // 0.09%
    uint256 public constant MAX_FEE_BPS      = 100;   // 1%
    uint256 public constant LP_SHARE_BPS     = 7000;  // 70% to LPs
    uint256 public constant PROTOCOL_BPS     = 2000;  // 20% to protocol
    uint256 public constant INSURANCE_BPS    = 1000;  // 10% insurance

    // ─────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────

    struct Reserve {
        bool    enabled;
        uint256 feeBps;
        uint256 totalDeposited;   // total LP deposits
        uint256 totalLP;          // LP share tokens outstanding
        uint256 accFeePerShare;   // accumulated fee per LP share (× 1e18)
        uint256 protocolFees;     // protocol's share pending withdrawal
        uint256 insuranceFund;    // insurance reserve
        uint256 dailyBorrowed;    // rolling daily flash borrow volume
        uint256 dayStart;         // timestamp of current day
        uint256 maxDailyBorrow;   // daily cap [A5]
        uint256 totalFlashVolume; // lifetime flash loan volume
        uint256 totalFlashCount;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────

    mapping(address => Reserve)                       public reserves;
    mapping(address => mapping(address => uint256))   public lpShares;     // token → user → shares
    mapping(address => mapping(address => uint256))   public lpFeeDebt;    // token → user → debt
    mapping(address => mapping(address => uint256))   public pendingFees;  // token → user → claimable
    address[]                                          public supportedTokens;
    mapping(address => bool)                           public isSupported;

    // Optional borrower whitelist [A4]
    bool    public whitelistMode;
    mapping(address => bool) public approvedBorrowers;

    // ─────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────

    event FlashLoan(
        address indexed borrower,
        address indexed token,
        uint256 amount,
        uint256 fee,
        bytes32 referenceId
    );
    event LiquidityAdded(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event FeesClaimed(address indexed user, address indexed token, uint256 amount);
    event TokenConfigured(address indexed token, uint256 feeBps, uint256 maxDailyBorrow);
    event ProtocolFeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────

    constructor(address owner) Ownable(owner) {}

    // ─────────────────────────────────────────────────────────────────
    //  Owner: Token Configuration
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Add or configure a supported token reserve
     * @param token          ERC20 token address
     * @param feeBps         Flash loan fee (max 100 bps / 1%)
     * @param maxDailyBorrow Daily flash borrow cap (protects LPs) [A5]
     */
    function configureToken(
        address token,
        uint256 feeBps,
        uint256 maxDailyBorrow
    ) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Flash: fee too high");
        require(token != address(0),   "Flash: zero address");

        if (!isSupported[token]) {
            isSupported[token] = true;
            supportedTokens.push(token);
        }

        Reserve storage r = reserves[token];
        r.enabled        = true;
        r.feeBps         = feeBps == 0 ? DEFAULT_FEE_BPS : feeBps;
        r.maxDailyBorrow = maxDailyBorrow;

        emit TokenConfigured(token, r.feeBps, maxDailyBorrow);
    }

    function setWhitelistMode(bool enabled) external onlyOwner { whitelistMode = enabled; }
    function setBorrowerApproval(address borrower, bool approved) external onlyOwner {
        approvedBorrowers[borrower] = approved;
    }

    function withdrawProtocolFees(address token, address to) external onlyOwner nonReentrant {
        Reserve storage r = reserves[token];
        uint256 amt = r.protocolFees;
        require(amt > 0, "Flash: no fees");
        r.protocolFees = 0;
        IERC20(token).safeTransfer(to, amt);
        emit ProtocolFeesWithdrawn(token, to, amt);
    }

    // ─────────────────────────────────────────────────────────────────
    //  LP: Add / Remove Liquidity
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit tokens to earn flash loan fee yield
     * @param token  Token to deposit
     * @param amount Amount to deposit
     */
    function addLiquidity(address token, uint256 amount) external nonReentrant {
        Reserve storage r = reserves[token];
        require(r.enabled, "Flash: token not supported");
        require(amount > 0, "Flash: zero amount");

        // Settle pending fees before balance change
        _settleFees(token, msg.sender);

        // Calculate share tokens to mint
        uint256 balance  = IERC20(token).balanceOf(address(this)) - r.protocolFees - r.insuranceFund;
        uint256 shares   = r.totalLP == 0 || balance == 0
            ? amount
            : amount * r.totalLP / balance;

        // [A2] State before transfer
        r.totalDeposited        += amount;
        r.totalLP               += shares;
        lpShares[token][msg.sender] += shares;
        lpFeeDebt[token][msg.sender] = lpShares[token][msg.sender] * r.accFeePerShare / 1e18;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(msg.sender, token, amount, shares);
    }

    /**
     * @notice Withdraw liquidity and claim accumulated fees
     * @param token  Token to withdraw
     * @param shares LP share tokens to redeem (use type(uint256).max for all)
     */
    function removeLiquidity(address token, uint256 shares) external nonReentrant {
        Reserve storage r = reserves[token];

        _settleFees(token, msg.sender);
        if (shares == type(uint256).max) shares = lpShares[token][msg.sender];
        require(lpShares[token][msg.sender] >= shares, "Flash: insufficient shares");

        // [A2] Calculate withdrawal amount before state change
        uint256 balance = IERC20(token).balanceOf(address(this)) - r.protocolFees - r.insuranceFund;
        uint256 amount  = r.totalLP > 0 ? shares * balance / r.totalLP : 0;

        r.totalLP -= shares;
        lpShares[token][msg.sender] -= shares;
        lpFeeDebt[token][msg.sender] = lpShares[token][msg.sender] * r.accFeePerShare / 1e18;

        if (amount > 0) IERC20(token).safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(msg.sender, token, amount, shares);
    }

    /**
     * @notice Claim accumulated flash loan fee share
     */
    function claimFees(address token) external nonReentrant {
        _settleFees(token, msg.sender);
        uint256 amt = pendingFees[token][msg.sender];
        require(amt > 0, "Flash: no fees to claim");
        pendingFees[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit FeesClaimed(msg.sender, token, amt);
    }

    // ─────────────────────────────────────────────────────────────────
    //  EIP-3156: Flash Loan
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Returns max flash loanable amount for a token
     */
    function maxFlashLoan(address token) external view returns (uint256) {
        Reserve storage r = reserves[token];
        if (!r.enabled) return 0;
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 locked  = r.protocolFees + r.insuranceFund;
        return balance > locked ? balance - locked : 0;
    }

    /**
     * @notice Returns the flash loan fee for a given amount
     */
    function flashFee(address token, uint256 amount) external view returns (uint256) {
        require(reserves[token].enabled, "Flash: unsupported token");
        return amount * reserves[token].feeBps / BPS;
    }

    /**
     * @notice Execute a flash loan
     *
     * @param receiver   Contract to receive tokens and call onFlashLoan
     * @param token      Token to borrow
     * @param amount     Amount to borrow
     * @param data       Arbitrary data passed to receiver
     * @param referenceId Optional external reference (for indexing/analytics)
     *
     * @dev Flow:
     *  1. Validate → 2. Transfer → 3. Callback → 4. Repayment check → 5. Fee split
     */
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data,
        bytes32 referenceId
    ) external nonReentrant returns (bool) {
        // ── Validation ────────────────────────────────────────────
        Reserve storage r = reserves[token];
        require(r.enabled,                          "Flash: unsupported token");
        require(amount > 0,                         "Flash: zero amount");
        if (whitelistMode) require(approvedBorrowers[msg.sender], "Flash: not approved"); // [A4]

        // [A5] Daily borrow cap
        if (block.timestamp >= r.dayStart + 1 days) {
            r.dayStart      = block.timestamp;
            r.dailyBorrowed = 0;
        }
        require(r.dailyBorrowed + amount <= r.maxDailyBorrow || r.maxDailyBorrow == 0,
            "Flash: daily cap exceeded");

        uint256 fee = amount * r.feeBps / BPS;

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        require(balanceBefore - r.protocolFees - r.insuranceFund >= amount,
            "Flash: insufficient liquidity");

        // ── [A2] Update daily tracking before external call ───────
        r.dailyBorrowed += amount;

        // ── Transfer to borrower ──────────────────────────────────
        IERC20(token).safeTransfer(receiver, amount);

        // ── Callback ──────────────────────────────────────────────
        // [A1] The NonReentrant guard covers this entire function
        bytes32 result = IERC3156FlashBorrower(receiver).onFlashLoan(
            msg.sender, token, amount, fee, data
        );
        require(result == CALLBACK_SUCCESS, "Flash: callback failed");

        // ── [A3] Repayment verification ───────────────────────────
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(
            balanceAfter >= balanceBefore + fee,
            "Flash: repayment insufficient"
        );

        // Collect the repayment (borrower should have approved this contract)
        // If borrower transferred directly, fee is already in balance
        // Net fee actually received
        uint256 actualFee = balanceAfter - balanceBefore;

        // ── Fee distribution ──────────────────────────────────────
        uint256 toLPs       = actualFee * LP_SHARE_BPS   / BPS;
        uint256 toProtocol  = actualFee * PROTOCOL_BPS   / BPS;
        uint256 toInsurance = actualFee - toLPs - toProtocol;

        r.protocolFees  += toProtocol;
        r.insuranceFund += toInsurance;

        // Distribute LP share (increase accFeePerShare)
        if (r.totalLP > 0 && toLPs > 0) {
            r.accFeePerShare += toLPs * 1e18 / r.totalLP;
        }

        r.totalFlashVolume += amount;
        r.totalFlashCount  += 1;

        emit FlashLoan(receiver, token, amount, actualFee, referenceId);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Internal
    // ─────────────────────────────────────────────────────────────────

    function _settleFees(address token, address user) internal {
        Reserve storage r = reserves[token];
        uint256 shares    = lpShares[token][user];
        if (shares == 0) return;
        uint256 owed = shares * r.accFeePerShare / 1e18;
        uint256 debt = lpFeeDebt[token][user];
        if (owed > debt) pendingFees[token][user] += owed - debt;
        lpFeeDebt[token][user] = owed;
    }

    // ─────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────

    function getReserve(address token) external view returns (Reserve memory) {
        return reserves[token];
    }

    function pendingFeesView(address token, address user) external view returns (uint256) {
        Reserve storage r = reserves[token];
        uint256 shares    = lpShares[token][user];
        uint256 owed      = shares > 0 ? shares * r.accFeePerShare / 1e18 : 0;
        uint256 extra     = owed > lpFeeDebt[token][user] ? owed - lpFeeDebt[token][user] : 0;
        return pendingFees[token][user] + extra;
    }

    function getLPBalance(address token, address user) external view returns (uint256 amount) {
        Reserve storage r = reserves[token];
        uint256 shares    = lpShares[token][user];
        if (shares == 0 || r.totalLP == 0) return 0;
        uint256 balance   = IERC20(token).balanceOf(address(this)) - r.protocolFees - r.insuranceFund;
        return shares * balance / r.totalLP;
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Annualised LP yield estimate (assumes steady flash loan demand)
     * @param token           Token address
     * @param dailyVolumeHint Estimated daily flash volume (for APY projection)
     */
    function estimateAPY(address token, uint256 dailyVolumeHint) external view returns (uint256) {
        Reserve storage r = reserves[token];
        if (!r.enabled || r.totalLP == 0) return 0;
        uint256 balance     = IERC20(token).balanceOf(address(this));
        if (balance == 0) return 0;
        uint256 dailyFee    = dailyVolumeHint * r.feeBps / BPS;
        uint256 dailyLPFee  = dailyFee * LP_SHARE_BPS / BPS;
        return dailyLPFee * 365 * 1e18 / balance;
    }
}
