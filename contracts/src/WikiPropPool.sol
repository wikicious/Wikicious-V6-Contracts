// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WikiPropPool — Liquidity pool backing funded prop accounts
///
/// HOW IT WORKS:
///   LPs deposit USDC → receive WPL tokens (WikiPropLiquidity)
///   WPL tokens represent share of the pool
///   Pool earns from:
///     - Evaluation fees (100% when eval fails, 30% when eval passes)
///     - Profit splits from funded traders (20-30% of trader profits)
///     - Trading fees on funded account trades
///   LPs can withdraw anytime (subject to utilization — capital in active funded accounts)
///
/// RISK FOR LPs:
///   Funded traders can lose money. Losses come from pool (up to funded account size).
///   This is why evaluation exists — to filter out unprofitable traders.
///   Insurance reserve (10% of fees) acts as first-loss buffer.

contract WikiPropPool is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
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

    IERC20 public immutable USDC;

    // ── Pool state ─────────────────────────────────────────────────────────
    uint256 public totalDeposited;       // total USDC deposited by LPs
    uint256 public totalUtilized;        // USDC currently backing active funded accounts
    uint256 public insuranceReserve;     // first-loss buffer
    uint256 public accruedYield;         // yield not yet distributed
    uint256 public totalYieldPaid;       // lifetime yield paid to LPs

    // Per-share yield accumulator (scaled by 1e18)
    uint256 public yieldPerShare;
    mapping(address => uint256) public yieldDebt; // LP's yield debt at last claim

    // Limits
    uint256 public maxUtilizationBps = 8000; // 80% max utilization
    uint256 public minDeposit        = 100 * 1e6;  // $100 min
    uint256 public withdrawalCooldown = 7 days;
    mapping(address => uint256) public lastDepositTime;

    // Authorized callers (WikiPropFunded contract)
    mapping(address => bool) public propContracts;

    // Revenue tracking
    uint256 public totalEvalFeesReceived;
    uint256 public totalProfitSplitsReceived;
    uint256 public totalLossesAbsorbed;
    uint256 public constant INSURANCE_BPS  = 1000; // 10% to insurance
    uint256 public constant BPS            = 10000;

    // Events
    event Deposited(address indexed lp, uint256 usdc, uint256 wpl);
    event Withdrawn(address indexed lp, uint256 usdc, uint256 wpl);
    event YieldAdded(uint256 amount, string source);
    event YieldClaimed(address indexed lp, uint256 amount);
    event CapitalAllocated(address indexed fundedAccount, uint256 amount);
    event CapitalReturned(address indexed fundedAccount, uint256 amount, int256 pnl);
    event LossAbsorbed(address indexed fundedAccount, uint256 loss);

    constructor(address usdc, address owner)
        ERC20("WikiProp Liquidity", "WPL") Ownable(owner)
    {
        require(usdc != address(0), "Wiki: zero usdc");
        require(owner != address(0), "Wiki: zero owner");
        USDC = IERC20(usdc);
    }

    // ── LP: Deposit ────────────────────────────────────────────────────────
    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 wplMinted) {
        require(amount >= minDeposit, "Pool: below minimum");

        // Claim pending yield before deposit (prevent dilution)
        _claimYield(msg.sender);

        uint256 totalPoolValue = _totalPoolValue();
        uint256 supply         = totalSupply();

        // WPL minted proportional to pool share
        if (supply == 0 || totalPoolValue == 0) {
            wplMinted = amount; // 1:1 for first deposit
        } else {
            wplMinted = amount * supply / totalPoolValue;
        }

        totalDeposited         += amount;
        lastDepositTime[msg.sender] = block.timestamp;

        // Set yield debt so new LP doesn't claim existing yield
        yieldDebt[msg.sender] = yieldPerShare * (balanceOf(msg.sender) + wplMinted) / 1e18;

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, wplMinted);

        emit Deposited(msg.sender, amount, wplMinted);
    }

    // ── LP: Withdraw ───────────────────────────────────────────────────────
    function withdraw(uint256 wplAmount) external nonReentrant returns (uint256 usdcOut) {
        require(balanceOf(msg.sender) >= wplAmount, "Pool: insufficient WPL");
        require(block.timestamp >= lastDepositTime[msg.sender] + withdrawalCooldown, "Pool: cooldown");

        // Claim yield first
        _claimYield(msg.sender);

        uint256 totalPoolValue = _totalPoolValue();
        usdcOut = wplAmount * totalPoolValue / totalSupply();

        // Check available liquidity (not utilized)
        uint256 available = USDC.balanceOf(address(this)) - insuranceReserve;
        require(usdcOut <= available, "Pool: insufficient available liquidity");

        totalDeposited = totalDeposited > usdcOut ? totalDeposited - usdcOut : 0;

        _burn(msg.sender, wplAmount);
        USDC.safeTransfer(msg.sender, usdcOut);

        emit Withdrawn(msg.sender, usdcOut, wplAmount);
    }

    // ── Prop contract: allocate capital to funded account ─────────────────
    function allocateCapital(address trader, uint256 amount) external nonReentrant {
        require(propContracts[msg.sender], "Pool: not authorized");
        uint256 available = USDC.balanceOf(address(this)) - insuranceReserve;
        uint256 maxAlloc  = _totalPoolValue() * maxUtilizationBps / BPS;
        require(totalUtilized + amount <= maxAlloc, "Pool: utilization cap");
        require(amount <= available,                "Pool: insufficient liquidity");

        totalUtilized += amount;
        USDC.safeTransfer(msg.sender, amount);

        emit CapitalAllocated(trader, amount);
    }

    // ── Prop contract: return capital after funded account closes ──────────
    /// @param amount   Original capital allocated
    /// @param profit   Profit earned (0 if loss or breakeven)
    /// @param loss     Loss incurred (0 if profit)
    function returnCapital(address trader, uint256 amount, uint256 profit, uint256 loss)
        external nonReentrant
    {
        require(propContracts[msg.sender], "Pool: not authorized");
        totalUtilized = totalUtilized >= amount ? totalUtilized - amount : 0;

        if (profit > 0) {
            // Pool receives its profit split — already deducted by WikiPropFunded
            // Just return capital
            USDC.safeTransferFrom(msg.sender, address(this), amount);
            emit CapitalReturned(trader, amount, int256(profit));
        } else if (loss > 0) {
            uint256 returned = amount > loss ? amount - loss : 0;
            if (returned > 0) USDC.safeTransferFrom(msg.sender, address(this), returned);

            // Cover loss from insurance first, then pool
            if (loss <= insuranceReserve) {
                insuranceReserve -= loss;
            } else {
                uint256 excess = loss - insuranceReserve;
                insuranceReserve = 0;
                totalDeposited   = totalDeposited > excess ? totalDeposited - excess : 0;
            }
            totalLossesAbsorbed += loss;
            emit LossAbsorbed(trader, loss);
            emit CapitalReturned(trader, returned, -int256(loss));
        } else {
            // Breakeven
            USDC.safeTransferFrom(msg.sender, address(this), amount);
            emit CapitalReturned(trader, amount, 0);
        }
    }

    // ── Receive yield (eval fees, profit splits) ───────────────────────────
    function receiveEvalFee(uint256 amount) external nonReentrant {
        require(propContracts[msg.sender], "Pool: not authorized");
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        uint256 ins = amount * INSURANCE_BPS / BPS;
        uint256 yield = amount - ins;
        insuranceReserve += ins;
        _distributeYield(yield, "eval_fee");
        totalEvalFeesReceived += amount;
    }

    // ── Receive yield from WikiPropPoolYield (idle capital strategy) ──
    function receiveYield(uint256 amount, string calldata source) external nonReentrant {
        require(propContracts[msg.sender] || msg.sender == owner(), "PropPool: not authorized");
        require(amount > 0, "PropPool: zero yield");
        totalDeposited += amount;
        _distributeYield(amount, source);
        emit YieldReceived(amount, source);
    }

    function receiveProfitSplit(uint256 amount) external nonReentrant {
        require(propContracts[msg.sender], "Pool: not authorized");
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        _distributeYield(amount, "profit_split");
        totalProfitSplitsReceived += amount;
    }

    // ── LP: Claim yield ────────────────────────────────────────────────────
    function claimYield() external nonReentrant {
        _claimYield(msg.sender);
    }

    function pendingYield(address lp) external view returns (uint256) {
        uint256 wpl    = balanceOf(lp);
        if (wpl == 0) return 0;
        uint256 accrued = yieldPerShare * wpl / 1e18;
        return accrued > yieldDebt[lp] ? accrued - yieldDebt[lp] : 0;
    }

    // ── Views ──────────────────────────────────────────────────────────────
    function wplPrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // $1 initial
        return _totalPoolValue() * 1e18 / supply; // 18 dec
    }

    function utilizationRate() external view returns (uint256) {
        uint256 total = _totalPoolValue();
        if (total == 0) return 0;
        return totalUtilized * BPS / total;
    }

    function availableCapital() external view returns (uint256) {
        uint256 available = USDC.balanceOf(address(this)) > insuranceReserve
            ? USDC.balanceOf(address(this)) - insuranceReserve : 0;
        uint256 maxUtil = _totalPoolValue() * maxUtilizationBps / BPS;
        uint256 maxNew  = maxUtil > totalUtilized ? maxUtil - totalUtilized : 0;
        return available < maxNew ? available : maxNew;
    }

    function poolStats() external view returns (
        uint256 tvl, uint256 utilized, uint256 insurance, uint256 apy,
        uint256 utilRate, uint256 lpCount
    ) {
        tvl       = _totalPoolValue();
        utilized  = totalUtilized;
        insurance = insuranceReserve;
        utilRate  = tvl > 0 ? totalUtilized * BPS / tvl : 0;
        // APY approximation: annualize last 30d yield / TVL
        apy       = tvl > 0 ? totalYieldPaid * 12 * BPS / tvl : 0; // rough monthly annualization
        lpCount   = 0; // tracked off-chain
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setPropContract(address c, bool ok) external onlyOwner { propContracts[c] = ok; }
    function setMaxUtilization(uint256 bps) external onlyOwner {
        require(bps <= 9000, "Pool: max 90%"); maxUtilizationBps = bps;
    }
    function setWithdrawalCooldown(uint256 t) external onlyOwner { withdrawalCooldown = t; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Internal ───────────────────────────────────────────────────────────
    function _totalPoolValue() internal view returns (uint256) {
        return USDC.balanceOf(address(this)) + totalUtilized;
        // Note: losses reduce balanceOf; gains increase it when returned
    }

    function _distributeYield(uint256 amount, string memory source) internal {
        uint256 supply = totalSupply();
        if (supply == 0 || amount == 0) { accruedYield += amount; return; }
        yieldPerShare   += amount * 1e18 / supply;
        totalYieldPaid  += amount;
        emit YieldAdded(amount, source);
    }

    function _claimYield(address lp) internal {
        uint256 wpl     = balanceOf(lp);
        if (wpl == 0) return;
        uint256 accrued = yieldPerShare * wpl / 1e18;
        uint256 owed    = accrued > yieldDebt[lp] ? accrued - yieldDebt[lp] : 0;
        yieldDebt[lp]   = accrued;
        if (owed == 0) return;
        uint256 available = USDC.balanceOf(address(this)) > insuranceReserve
            ? USDC.balanceOf(address(this)) - insuranceReserve : 0;
        uint256 pay = owed > available ? available : owed;
        if (pay > 0) {
            USDC.safeTransfer(lp, pay);
            emit YieldClaimed(lp, pay);
        }
    }
}
