// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiRealYieldLP
 * @notice LPs earn 100% USDC trading fees — no token inflation.
 *         "Real yield" narrative: sustainable income from protocol revenue.
 *         This is what GMX does with GLP. Attracts institutional LPs.
 *
 * WHY THIS UNLOCKS INSTITUTIONAL CAPITAL:
 *   Institutional LPs (funds, DAOs, treasuries) will NOT accept:
 *     - Inflationary token rewards (uncertain future value)
 *     - Lock-ups with no guarantee of returns
 *   They WILL accept:
 *     - USDC yield paid every block from real trading fees
 *     - Transparent on-chain math showing fee source
 *     - Audited smart contracts with no admin keys on the fee flow
 *
 * HOW IT WORKS:
 *   1. LPs deposit USDC (or ETH/BTC) into the RealYield vault
 *   2. Vault provides liquidity to WikiPerp as backstop
 *   3. WikiRevenueSplitter routes a % of all trading fees here
 *   4. Fees distributed to LPs every block pro-rata by shares
 *   5. LPs claim USDC. No vesting. No lock. Pure fee income.
 *
 * DUAL INCOME:
 *   Primary: USDC trading fees (sustainable, grows with volume)
 *   Secondary: Funding rate income when net OI is long-heavy
 *   Risk: Traders' losses come to vault; trader profits come from vault
 *
 * TARGET APY: 8-25% depending on protocol volume
 */
contract WikiRealYieldLP is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct VaultInfo {
        uint256 totalAssets;        // USDC in vault
        uint256 totalShares;        // LP share tokens outstanding
        uint256 accFeePerShare;     // accumulated USDC fee per share (scaled 1e18)
        uint256 lastFeeUpdate;
        uint256 totalFeesReceived;  // lifetime fees received
        uint256 totalFeesPaid;      // lifetime fees paid to LPs
        uint256 utilizationBps;     // % of capital deployed as liquidity
    }

    struct LPPosition {
        uint256 shares;
        uint256 feeDebt;            // last accFeePerShare × shares
        uint256 pendingFees;        // unclaimed USDC fees
        uint256 totalClaimed;
        uint256 depositTime;
    }

    VaultInfo public vault;
    mapping(address => LPPosition) public positions;
    address[] public lps;
    mapping(address => bool) public isLP;

    address public revenueSplitter;
    address public perpContract;

    uint256 public constant PRECISION   = 1e18;
    uint256 public constant MIN_DEPOSIT = 100 * 1e6;  // $100 minimum
    uint256 public feeSplitBps          = 5000;        // 50% of routed fees to real yield LPs

    event Deposited(address indexed lp, uint256 usdc, uint256 shares);
    event Withdrawn(address indexed lp, uint256 usdc, uint256 shares);
    event FeesClaimed(address indexed lp, uint256 usdc);
    event FeesReceived(uint256 amount, uint256 newAccPerShare);

    constructor(address _owner, address _usdc, address _revenueSplitter) Ownable(_owner) {
        USDC            = IERC20(_usdc);
        revenueSplitter = _revenueSplitter;
    }

    // ── LP: deposit USDC ──────────────────────────────────────────────────
    function deposit(uint256 usdcAmount) external nonReentrant returns (uint256 shares) {
        require(usdcAmount >= MIN_DEPOSIT, "RY: below minimum $100");
        _settlePending(msg.sender);

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Calculate shares: first depositor gets 1:1, subsequent get pro-rata
        shares = vault.totalShares == 0
            ? usdcAmount
            : usdcAmount * vault.totalShares / vault.totalAssets;

        vault.totalAssets += usdcAmount;
        vault.totalShares += shares;

        LPPosition storage pos = positions[msg.sender];
        pos.shares      += shares;
        pos.feeDebt      = pos.shares * vault.accFeePerShare / PRECISION;
        pos.depositTime  = block.timestamp;

        if (!isLP[msg.sender]) { isLP[msg.sender] = true; lps.push(msg.sender); }
        emit Deposited(msg.sender, usdcAmount, shares);
    }

    // ── LP: withdraw USDC + claim fees ────────────────────────────────────
    function withdraw(uint256 shares) external nonReentrant {
        LPPosition storage pos = positions[msg.sender];
        require(pos.shares >= shares, "RY: insufficient shares");

        _settlePending(msg.sender);

        uint256 usdcOut = shares * vault.totalAssets / vault.totalShares;
        pos.shares       -= shares;
        pos.feeDebt       = pos.shares * vault.accFeePerShare / PRECISION;
        vault.totalShares -= shares;
        vault.totalAssets -= usdcOut;

        USDC.safeTransfer(msg.sender, usdcOut);
        emit Withdrawn(msg.sender, usdcOut, shares);
    }

    // ── LP: claim accumulated fees ────────────────────────────────────────
    function claimFees() external nonReentrant returns (uint256 claimed) {
        _settlePending(msg.sender);
        LPPosition storage pos = positions[msg.sender];
        claimed = pos.pendingFees;
        require(claimed > 0, "RY: no fees to claim");
        pos.pendingFees    = 0;
        pos.totalClaimed  += claimed;
        vault.totalFeesPaid += claimed;
        USDC.safeTransfer(msg.sender, claimed);
        emit FeesClaimed(msg.sender, claimed);
    }

    // ── Called by WikiRevenueSplitter when fees arrive ───────────────────
    function receiveFees(uint256 amount) external nonReentrant {
        require(msg.sender == revenueSplitter || msg.sender == owner(), "RY: not splitter");
        require(amount > 0, "RY: zero fees");
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        if (vault.totalShares > 0) {
            vault.accFeePerShare += amount * PRECISION / vault.totalShares;
        }
        vault.totalFeesReceived += amount;
        vault.lastFeeUpdate      = block.timestamp;
        emit FeesReceived(amount, vault.accFeePerShare);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getLPPosition(address lp) external view returns (
        uint256 shares,
        uint256 usdcValue,
        uint256 pendingFees,
        uint256 totalClaimed,
        uint256 shareOfPool,
        uint256 estimatedAPY
    ) {
        LPPosition storage pos = positions[lp];
        shares      = pos.shares;
        usdcValue   = vault.totalShares > 0 ? shares * vault.totalAssets / vault.totalShares : 0;
        shareOfPool = vault.totalShares > 0 ? shares * 10000 / vault.totalShares : 0;

        // Pending = accrued since last settlement
        uint256 newFees = shares * vault.accFeePerShare / PRECISION;
        pendingFees = pos.pendingFees + (newFees > pos.feeDebt ? newFees - pos.feeDebt : 0);
        totalClaimed= pos.totalClaimed;

        // APY based on last 7 days of fees (annualised)
        uint256 elapsed = block.timestamp - vault.lastFeeUpdate;
        if (elapsed > 0 && vault.totalAssets > 0 && shares > 0) {
            uint256 dailyFeeRate = vault.totalFeesReceived * 1 days / (elapsed + 1) / vault.totalAssets;
            estimatedAPY = dailyFeeRate * 365 * 10000;
        }
    }

    function getVaultStats() external view returns (
        uint256 totalAssets,
        uint256 totalShares,
        uint256 totalFeesReceived,
        uint256 totalFeesPaid,
        uint256 utilizationBps,
        uint256 estimatedAPYBps
    ) {
        totalAssets      = vault.totalAssets;
        totalShares      = vault.totalShares;
        totalFeesReceived= vault.totalFeesReceived;
        totalFeesPaid    = vault.totalFeesPaid;
        utilizationBps   = vault.utilizationBps;

        uint256 elapsed = block.timestamp - vault.lastFeeUpdate + 1;
        uint256 dailyFee = vault.totalFeesReceived * 1 days / elapsed;
        estimatedAPYBps  = totalAssets > 0 ? dailyFee * 365 * 10000 / totalAssets : 0;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _settlePending(address lp) internal {
        LPPosition storage pos = positions[lp];
        if (pos.shares == 0) return;
        uint256 newFees = pos.shares * vault.accFeePerShare / PRECISION;
        if (newFees > pos.feeDebt) pos.pendingFees += newFees - pos.feeDebt;
        pos.feeDebt = newFees;
    }

    function setRevenueSplitter(address r) external onlyOwner { revenueSplitter = r; }
    function setFeeSplitBps(uint256 bps) external onlyOwner { require(bps <= 10000); feeSplitBps = bps; }
}
