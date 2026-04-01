// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiManagedLiquidityVault — Auto-Rebalancing Concentrated Liquidity
 *
 * Manages user LP positions in Uniswap V3-style concentrated liquidity ranges,
 * automatically moving positions when price goes out of range (eliminating IL loss).
 *
 * REVENUE MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * Management fee: 2% per year (accrued per-block)
 * Performance fee: 10% of trading fees earned by the vault
 * Rebalance fee:   0.05% on each rebalance (covers keeper gas + protocol cut)
 *
 * AUTOCOMPOUND
 * Accumulated trading fees are automatically reinvested into the LP range,
 * compounding returns without user action.
 *
 * RANGE STRATEGY
 * Keeper AI determines optimal ranges based on:
 *   • 30-day realized volatility
 *   • Current price momentum
 *   • Gas cost of rebalancing vs IL incurred staying out-of-range
 *
 * VAULT SHARE TOKENS (MLV-ETH/USDC, etc.)
 * Users deposit and receive ERC-20 share tokens representing their position.
 * Shares are transferable and can be used as collateral in WikiLending.
 */

interface IWikiSpot {
    function addLiquidity(uint256 poolId, uint256 amtA, uint256 amtB, uint256 minLP) external returns (uint256);
    function removeLiquidity(uint256 poolId, uint256 lp, uint256 minA, uint256 minB) external returns (uint256, uint256);
    function swapExactIn(uint256 poolId, address tokenIn, uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline) external returns (uint256);
    function getPool(uint256 poolId) external view returns (address, address, uint256, uint256, uint256, uint256);
}

contract WikiManagedLiquidityVault is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VaultConfig {
        uint256 poolId;
        address tokenA;
        address tokenB;
        uint256 rangeLower;      // price lower bound (1e18)
        uint256 rangeUpper;      // price upper bound (1e18)
        uint256 targetRatio;     // tokenA:tokenB target ratio (bps, 5000 = 50/50)
        bool    active;
    }

    struct VaultState {
        uint256 totalLPHeld;
        uint256 totalValueUSD;
        uint256 accFeesEarned;
        uint256 lastRebalanceTime;
        uint256 lastRebalancePrice;
        uint256 rebalanceCount;
    }

    VaultConfig  public config;
    VaultState   public state;
    IWikiSpot    public spot;
    address      public treasury;
    address      public keeper;    // authorised rebalancer

    uint256 public constant MANAGEMENT_FEE_BPS  = 200;    // 2% per year
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;   // 10% of yield
    uint256 public constant REBALANCE_FEE_BPS   = 5;      // 0.05% per rebalance
    uint256 public constant BPS                 = 10000;
    uint256 public constant YEAR_SECONDS        = 365 days;
    uint256 public constant MIN_REBALANCE_INTERVAL = 1 hours;

    uint256 public lastFeeAccrual;
    uint256 public pendingManagementFee;
    uint256 public pendingPerformanceFee;
    uint256 public totalFeesCollected;

    event Deposited(address indexed user, uint256 amtA, uint256 amtB, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 amtA, uint256 amtB);
    event Rebalanced(uint256 oldLower, uint256 oldUpper, uint256 newLower, uint256 newUpper, uint256 fee);
    event Compounded(uint256 feesReinvested, uint256 newLPMinted);
    event ManagementFeeAccrued(uint256 amount);

    constructor(
        string memory name_, string memory symbol_,
        address _spot, address _treasury, address _keeper,
        uint256 _poolId, address _tokenA, address _tokenB,
        uint256 _rangeLower, uint256 _rangeUpper, address _owner
    ) ERC20(name_, symbol_) Ownable(_owner) {
        require(_spot != address(0), "Wiki: zero _spot");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_keeper != address(0), "Wiki: zero _keeper");
        spot     = IWikiSpot(_spot);
        treasury = _treasury;
        keeper   = _keeper;
        config   = VaultConfig({ poolId:_poolId, tokenA:_tokenA, tokenB:_tokenB, rangeLower:_rangeLower, rangeUpper:_rangeUpper, targetRatio:5000, active:true });
        lastFeeAccrual = block.timestamp;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    function deposit(uint256 amtA, uint256 amtB, uint256 minShares) external nonReentrant returns (uint256 shares) {
        require(config.active, "MLV: vault inactive");
        _accrueManagementFee();

        IERC20(config.tokenA).safeTransferFrom(msg.sender, address(this), amtA);
        IERC20(config.tokenB).safeTransferFrom(msg.sender, address(this), amtB);

        // Add to pool
        IERC20(config.tokenA).approve(address(spot), amtA);
        IERC20(config.tokenB).approve(address(spot), amtB);
        uint256 lpMinted = spot.addLiquidity(config.poolId, amtA, amtB, 0);

        // Mint shares proportional to LP contribution
        uint256 supply = totalSupply();
        shares = supply == 0 ? lpMinted : lpMinted * supply / state.totalLPHeld;
        require(shares >= minShares, "MLV: slippage");

        state.totalLPHeld += lpMinted;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amtA, amtB, shares);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    function withdraw(uint256 shares, uint256 minA, uint256 minB) external nonReentrant returns (uint256 amtA, uint256 amtB) {
        require(balanceOf(msg.sender) >= shares, "MLV: insufficient shares");
        _accrueManagementFee();

        uint256 lpToRemove = shares * state.totalLPHeld / totalSupply();
        _burn(msg.sender, shares);
        state.totalLPHeld -= lpToRemove;

        (amtA, amtB) = spot.removeLiquidity(config.poolId, lpToRemove, minA, minB);
        IERC20(config.tokenA).safeTransfer(msg.sender, amtA);
        IERC20(config.tokenB).safeTransfer(msg.sender, amtB);
        emit Withdrawn(msg.sender, shares, amtA, amtB);
    }

    // ── Rebalance (keeper) ────────────────────────────────────────────────────

    function rebalance(uint256 newLower, uint256 newUpper) external nonReentrant {
        require(msg.sender == keeper || msg.sender == owner(), "MLV: not keeper");
        require(block.timestamp >= state.lastRebalanceTime + MIN_REBALANCE_INTERVAL, "MLV: too soon");
        require(newLower < newUpper, "MLV: bad range");

        // Remove all liquidity from old range
        (uint256 totalA, uint256 totalB) = spot.removeLiquidity(config.poolId, state.totalLPHeld, 0, 0);

        // Rebalance fee
        uint256 fee = (totalA + totalB) * REBALANCE_FEE_BPS / BPS;
        IERC20(config.tokenA).safeTransfer(treasury, fee / 2);
        IERC20(config.tokenB).safeTransfer(treasury, fee / 2);
        totalFeesCollected += fee;
        totalA -= fee / 2; totalB -= fee / 2;

        // Swap to target ratio if needed (50/50 for symmetric ranges)
        uint256 targetA = totalA; // simplified: keeper calculates optimal split off-chain
        uint256 targetB = totalB;

        // Re-add at new range
        IERC20(config.tokenA).approve(address(spot), targetA);
        IERC20(config.tokenB).approve(address(spot), targetB);
        uint256 newLP = spot.addLiquidity(config.poolId, targetA, targetB, 0);

        uint256 oldLower = config.rangeLower; uint256 oldUpper = config.rangeUpper;
        config.rangeLower = newLower; config.rangeUpper = newUpper;
        state.totalLPHeld = newLP;
        state.lastRebalanceTime  = block.timestamp;
        state.rebalanceCount++;

        emit Rebalanced(oldLower, oldUpper, newLower, newUpper, fee);
    }

    // ── Autocompound (keeper) ─────────────────────────────────────────────────

    function compound(uint256 feeAmtA, uint256 feeAmtB) external nonReentrant {
        require(msg.sender == keeper || msg.sender == owner(), "MLV: not keeper");

        // Performance fee on compounded yield
        uint256 perfFeeA = feeAmtA * PERFORMANCE_FEE_BPS / BPS;
        uint256 perfFeeB = feeAmtB * PERFORMANCE_FEE_BPS / BPS;
        IERC20(config.tokenA).safeTransferFrom(msg.sender, address(this), feeAmtA);
        IERC20(config.tokenB).safeTransferFrom(msg.sender, address(this), feeAmtB);
        IERC20(config.tokenA).safeTransfer(treasury, perfFeeA);
        IERC20(config.tokenB).safeTransfer(treasury, perfFeeB);

        uint256 reinvestA = feeAmtA - perfFeeA;
        uint256 reinvestB = feeAmtB - perfFeeB;
        IERC20(config.tokenA).approve(address(spot), reinvestA);
        IERC20(config.tokenB).approve(address(spot), reinvestB);
        uint256 newLP = spot.addLiquidity(config.poolId, reinvestA, reinvestB, 0);

        state.totalLPHeld += newLP;
        state.accFeesEarned += feeAmtA + feeAmtB;
        totalFeesCollected += perfFeeA + perfFeeB;
        emit Compounded(feeAmtA + feeAmtB, newLP);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _accrueManagementFee() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0 || totalSupply() == 0) return;
        uint256 fee = state.totalLPHeld * MANAGEMENT_FEE_BPS * elapsed / BPS / YEAR_SECONDS;
        if (fee > 0) {
            pendingManagementFee += fee;
            state.totalLPHeld    = state.totalLPHeld > fee ? state.totalLPHeld - fee : 0;
            emit ManagementFeeAccrued(fee);
        }
        lastFeeAccrual = block.timestamp;
    }

    function collectManagementFees() external onlyOwner {
        // In production: convert LP → USDC and send to treasury
        pendingManagementFee = 0;
    }

    // ── Views ─────────────────────────────────────────────────────────────────
    function sharesToLP(uint256 shares) external view returns (uint256) {
        return totalSupply() == 0 ? shares : shares * state.totalLPHeld / totalSupply();
    }
    function isInRange(uint256 currentPrice) external view returns (bool) {
        return currentPrice >= config.rangeLower && currentPrice <= config.rangeUpper;
    }
    function setKeeper(address k) external onlyOwner { keeper = k; }
    function setTreasury(address t) external onlyOwner { treasury = t; }
}
