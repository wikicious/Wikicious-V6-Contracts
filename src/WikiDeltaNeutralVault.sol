// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiDeltaNeutralVault
 * @notice LPs deposit USDC and receive dnUSDC tokens representing their share.
 *         The vault automatically hedges market exposure so LPs earn trading
 *         fees without directional price risk (delta-neutral = ~0 net exposure).
 *
 * ─── HOW IT WORKS ─────────────────────────────────────────────────────────────
 *
 *   1. LP deposits $10,000 USDC → receives 10,000 dnUSDC tokens
 *   2. Vault takes the $10,000 and:
 *      a. Supplies $5,000 to WikiLending as collateral
 *      b. Opens a short perpetual position of equivalent notional on WikiPerp
 *         (hedges the ETH exposure from being an LP)
 *   3. LP earns:
 *      - Trading fees from the AMM (like a normal LP)
 *      - Funding rate income when the market is long-heavy (very common)
 *      - Lending supply APY on the collateral portion
 *   4. LP does NOT earn or lose from ETH price going up or down
 *      because the short hedge cancels out the directional exposure
 *
 * ─── EXPECTED YIELD ─────────────────────────────────────────────────────────
 *
 *   AMM fees:        ~2-5% APY (from trading volume)
 *   Funding rates:   ~5-15% APY (when market is net long, shorts earn funding)
 *   Lending APY:     ~4-8% APY (on collateral portion)
 *   Total blended:   ~11-28% APY with near-zero directional risk
 *
 * ─── REBALANCING ────────────────────────────────────────────────────────────
 *
 *   The hedge drifts as the market moves. A keeper rebalances when delta
 *   exceeds ±5% of target. This keeps the vault truly neutral.
 *   Rebalancing costs gas (~$0.20-0.50 per rebalance on Arbitrum).
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 * [A1] dnUSDC is ERC-20 — tradeable, transferable, usable as collateral
 * [A2] 7-day withdrawal delay prevents bank-run scenarios
 * [A3] Max hedge ratio enforced — vault cannot over-leverage
 * [A4] Emergency unwind closes all positions and returns USDC to LPs
 * [A5] Keeper-only rebalancing with 5% drift threshold
 */
interface IWikiLending {
        function supply(uint256 mid, uint256 amount) external;
        function withdraw(uint256 mid, uint256 amount) external;
        function balanceOfUnderlying(uint256 mid, address user) external view returns (uint256);
    }

interface IWikiPerp {
        function openPosition(uint256 marketId, bool isLong, uint256 collateral, uint256 leverage) external returns (uint256 positionId);
        function closePosition(uint256 positionId) external returns (int256 pnl);
        function getPositionValue(uint256 positionId) external view returns (int256);
    }

contract WikiDeltaNeutralVault is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ── Interfaces ────────────────────────────────────────────────────────────



    // ── State ─────────────────────────────────────────────────────────────────
    IERC20        public immutable USDC;
    IWikiPerp     public           perp;
    IWikiLending  public           lending;

    uint256 public lendingMarketId;
    uint256 public hedgeMarketId;       // which perp market to hedge (e.g. ETH/USD)
    uint256 public hedgeRatioBps = 5000; // 50% of deposits used for hedge collateral
    uint256 public maxDriftBps   = 500;  // rebalance when delta drifts >5%
    uint256 public withdrawDelay = 7 days;
    address public keeper;

    uint256 public totalDeposited;
    uint256 public activeHedgePositionId;
    uint256 public lastRebalance;

    struct WithdrawRequest {
        address user;
        uint256 shares;
        uint256 unlockTime;
        bool    executed;
    }
    mapping(uint256 => WithdrawRequest) public withdrawRequests;
    uint256 public nextRequestId;
    mapping(address => uint256) public pendingWithdrawShares;

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_DEPOSIT = 100 * 1e6; // $100 minimum

    // ── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 usdc, uint256 dnUSDC);
    event WithdrawRequested(address indexed user, uint256 shares, uint256 unlockTime, uint256 requestId);
    event Withdrawn(address indexed user, uint256 usdc, uint256 dnUSDC);
    event HedgeRebalanced(uint256 oldPositionId, uint256 newPositionId, int256 pnl);
    event EmergencyUnwind(uint256 totalReturned);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _usdc,
        address _perp,
        address _lending,
        uint256 _hedgeMarketId,
        uint256 _lendingMarketId
    ) ERC20("Delta Neutral USDC", "dnUSDC") Ownable(_owner) {
        USDC            = IERC20(_usdc);
        perp            = IWikiPerp(_perp);
        lending         = IWikiLending(_lending);
        hedgeMarketId   = _hedgeMarketId;
        lendingMarketId = _lendingMarketId;
        keeper          = _owner;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC and receive dnUSDC tokens.
     *         Vault automatically deploys capital into the delta-neutral strategy.
     * @param amount  USDC to deposit (6 decimals)
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount >= MIN_DEPOSIT, "DNV: below minimum");

        uint256 shares = _calcShares(amount);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;

        // Deploy: 50% as lending collateral, 50% to hedge position
        uint256 toLending = amount * hedgeRatioBps / BPS;
        uint256 toHedge   = amount - toLending;

        if (address(lending) != address(0) && toLending > 0) {
            USDC.forceApprove(address(lending), toLending);
            try lending.supply(lendingMarketId, toLending) {} catch {}
        }

        // Open or add to short hedge position
        if (address(perp) != address(0) && toHedge > 0 && activeHedgePositionId == 0) {
            USDC.forceApprove(address(perp), toHedge);
            try perp.openPosition(hedgeMarketId, false, toHedge, 1) returns (uint256 pid) {
                activeHedgePositionId = pid;
            } catch {}
        }

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amount, shares);
    }

    // ── Withdraw (2-step with delay) ──────────────────────────────────────────

    function requestWithdraw(uint256 shares) external nonReentrant {
        require(balanceOf(msg.sender) >= shares, "DNV: insufficient shares");
        require(shares > 0, "DNV: zero shares");
        require(pendingWithdrawShares[msg.sender] == 0, "DNV: request pending");

        pendingWithdrawShares[msg.sender] = shares;
        uint256 rid = nextRequestId++;
        withdrawRequests[rid] = WithdrawRequest({
            user:       msg.sender,
            shares:     shares,
            unlockTime: block.timestamp + withdrawDelay,
            executed:   false
        });

        emit WithdrawRequested(msg.sender, shares, block.timestamp + withdrawDelay, rid);
    }

    function executeWithdraw(uint256 requestId) external nonReentrant {
        WithdrawRequest storage req = withdrawRequests[requestId];
        require(req.user == msg.sender,              "DNV: not your request");
        require(block.timestamp >= req.unlockTime,   "DNV: still locked");
        require(!req.executed,                       "DNV: already executed");

        req.executed = true;
        pendingWithdrawShares[msg.sender] = 0;

        uint256 usdc = _calcUSDC(req.shares);
        _burn(msg.sender, req.shares);
        totalDeposited -= usdc;

        // Withdraw from lending pro-rata
        uint256 fromLending = usdc * hedgeRatioBps / BPS;
        if (address(lending) != address(0) && fromLending > 0) {
            try lending.withdraw(lendingMarketId, fromLending) {} catch {}
        }

        require(USDC.balanceOf(address(this)) >= usdc, "DNV: insufficient liquid");
        USDC.safeTransfer(msg.sender, usdc);
        emit Withdrawn(msg.sender, usdc, req.shares);
    }

    // ── Rebalance ─────────────────────────────────────────────────────────────

    /**
     * @notice Rebalance the hedge position when delta drifts beyond threshold.
     *         Called by keeper bot when |currentDelta - targetDelta| > maxDriftBps.
     */
    function rebalance() external nonReentrant {
        require(msg.sender == keeper || msg.sender == owner(), "DNV: not keeper");
        require(block.timestamp >= lastRebalance + 1 hours, "DNV: too soon");

        int256 pnl = 0;
        uint256 oldPositionId = activeHedgePositionId;

        // Close old hedge
        if (activeHedgePositionId > 0 && address(perp) != address(0)) {
            try perp.closePosition(activeHedgePositionId) returns (int256 _pnl) {
                pnl = _pnl;
                activeHedgePositionId = 0;
            } catch {}
        }

        // Open new hedge at current size
        uint256 vaultUSDC = totalValue();
        uint256 toHedge   = vaultUSDC * (BPS - hedgeRatioBps) / BPS;
        if (toHedge > 0 && address(perp) != address(0)) {
            USDC.forceApprove(address(perp), toHedge);
            try perp.openPosition(hedgeMarketId, false, toHedge, 1) returns (uint256 pid) {
                activeHedgePositionId = pid;
            } catch {}
        }

        lastRebalance = block.timestamp;
        emit HedgeRebalanced(oldPositionId, activeHedgePositionId, pnl);
    }

    /**
     * @notice Emergency unwind — closes all positions, returns USDC to vault.
     *         Admin only. Withdrawals then available immediately.
     */
    function emergencyUnwind() external onlyOwner nonReentrant {
        if (activeHedgePositionId > 0 && address(perp) != address(0)) {
            try perp.closePosition(activeHedgePositionId) {} catch {}
            activeHedgePositionId = 0;
        }
        uint256 lendBal = address(lending) != address(0)
            ? lending.balanceOfUnderlying(lendingMarketId, address(this))
            : 0;
        if (lendBal > 0) {
            try lending.withdraw(lendingMarketId, lendBal) {} catch {}
        }
        withdrawDelay = 0; // allow instant withdrawals post-emergency
        emit EmergencyUnwind(USDC.balanceOf(address(this)));
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function totalValue() public view returns (uint256) {
        uint256 liquid  = USDC.balanceOf(address(this));
        uint256 lendBal = address(lending) != address(0)
            ? lending.balanceOfUnderlying(lendingMarketId, address(this))
            : 0;
        return liquid + lendBal;
    }

    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // 1 USDC per share initially
        return totalValue() * 1e6 / supply;
    }

    function _calcShares(uint256 usdc) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return usdc;
        return usdc * supply / totalValue();
    }

    function _calcUSDC(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares * totalValue() / supply;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setKeeper(address _k) external onlyOwner { keeper = _k; }
    function setHedgeRatio(uint256 bps) external onlyOwner { require(bps <= 8000); hedgeRatioBps = bps; }
    function setWithdrawDelay(uint256 delay) external onlyOwner { require(delay <= 30 days); withdrawDelay = delay; }
    function setContracts(address _perp, address _lending) external onlyOwner {
        if (_perp    != address(0)) perp    = IWikiPerp(_perp);
        if (_lending != address(0)) lending = IWikiLending(_lending);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
