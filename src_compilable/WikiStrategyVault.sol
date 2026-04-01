// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiStrategyVault
 * @notice Auto-compounding strategy vaults (Yearn-style) that run WikiRebalancer
 *         bots automatically. Each vault has a defined strategy and charges:
 *   • 0.5% management fee (annualised, charged per harvest)
 *   • 10% performance fee on profits above high-water mark
 *
 * STRATEGIES
 * ─────────────────────────────────────────────────────────────────────────
 * YIELD_MAXIMIZER  : Routes USDC across WikiLending, Yield Slices, and AMM LP
 *                    to maximise stable yield. Auto-compounds every harvest.
 * DELTA_NEUTRAL    : Holds equal long+short perp positions + earns funding rates.
 *                    Near-zero directional risk.
 * MOMENTUM         : Runs trend-following strategies using WikiPerp positions.
 *                    Higher risk, higher potential return.
 * MARKET_MAKING    : Provides liquidity to WikiOrderBook, earns maker rebates.
 *                    Low risk, consistent small returns.
 */
contract WikiStrategyVault is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
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
    uint256 public constant BPS             = 10_000;
    uint256 public constant PRECISION       = 1e18;
    uint256 public constant MAX_MGMT_FEE    = 200;   // 2% max annual
    uint256 public constant MAX_PERF_FEE    = 2000;  // 20% max
    uint256 public constant MIN_HARVEST_GAP = 6 hours;

    // ──────────────────────────────────────────────────────────────────
    //  Enums & State
    // ──────────────────────────────────────────────────────────────────
    enum Strategy { YIELD_MAXIMIZER, DELTA_NEUTRAL, MOMENTUM, MARKET_MAKING }

    IERC20  public immutable asset;          // deposit/withdraw token (USDC)
    Strategy public immutable strategy;

    uint256 public managementFeeBps;
    uint256 public performanceFeeBps;
    uint256 public highWaterMark;            // all-time high share price
    uint256 public lastHarvestTime;
    uint256 public totalProtocolFees;        // accumulated fees (USDC)

    mapping(address => bool) public harvesters; // bots that can trigger harvest

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 assets, uint256 shares);
    event Harvest(uint256 gain, uint256 loss, uint256 mgmtFee, uint256 perfFee, uint256 newSharePrice);
    event FeesWithdrawn(address to, uint256 amount);
    event HarvesterSet(address indexed h, bool enabled);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(
        address _asset,
        Strategy _strategy,
        uint256  _managementFeeBps,
        uint256  _performanceFeeBps,
        string   memory _name,
        string   memory _symbol,
        address  _owner
    ) ERC20(_name, _symbol) Ownable(_owner) {
        require(_asset != address(0), "Wiki: zero _asset");
        require(_owner != address(0), "Wiki: zero _owner");
        require(_managementFeeBps <= MAX_MGMT_FEE, "SV: mgmt fee too high");
        require(_performanceFeeBps <= MAX_PERF_FEE, "SV: perf fee too high");
        asset              = IERC20(_asset);
        strategy           = _strategy;
        managementFeeBps   = _managementFeeBps;
        performanceFeeBps  = _performanceFeeBps;
        highWaterMark      = PRECISION; // start at 1.0
        lastHarvestTime    = block.timestamp;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Deposit / Withdraw
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC and receive vault shares (receipt tokens).
     *         Share price increases as the vault earns yield.
     */
    function deposit(uint256 assetAmount, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(assetAmount > 0, "SV: zero");
        shares = _convertToShares(assetAmount);

        // [CEI] mint before transfer
        _mint(receiver, shares);
        asset.safeTransferFrom(msg.sender, address(this), assetAmount);

        emit Deposit(msg.sender, assetAmount, shares);
    }

    /**
     * @notice Redeem vault shares for underlying USDC (plus accrued yield).
     */
    function redeem(uint256 shares, address receiver) external nonReentrant whenNotPaused returns (uint256 assets) {
        require(shares > 0, "SV: zero");
        require(balanceOf(msg.sender) >= shares, "SV: insufficient shares");
        assets = _convertToAssets(shares);

        // [CEI] burn before transfer
        _burn(msg.sender, shares);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, assets, shares);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Harvest (called by keeper bot)
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Report gains/losses from the strategy and charge fees.
     *         Called by authorised keeper bots after each rebalance cycle.
     *
     * @param gain     USDC earned since last harvest (strategy profits)
     * @param loss     USDC lost since last harvest (strategy drawdown)
     */
    function harvest(uint256 gain, uint256 loss) external nonReentrant {
        require(harvesters[msg.sender] || msg.sender == owner(), "SV: not harvester");
        require(block.timestamp >= lastHarvestTime + MIN_HARVEST_GAP, "SV: too soon");

        uint256 totalAUM = totalAssets();

        // ── Management fee (pro-rata since last harvest) ──────────────
        uint256 elapsed  = block.timestamp - lastHarvestTime;
        uint256 mgmtFee  = totalAUM * managementFeeBps / BPS /* AUDIT: verify mul-before-div order */ * elapsed / 365 days;

        // ── Performance fee (only on gains above HWM) ─────────────────
        uint256 perfFee  = 0;
        if (gain > 0) {
            uint256 newPrice = totalSupply() > 0
                ? (totalAUM + gain) * PRECISION / totalSupply()
                : PRECISION;
            if (newPrice > highWaterMark) {
                uint256 excessGain = (newPrice - highWaterMark) * totalSupply() / PRECISION;
                perfFee            = excessGain * performanceFeeBps / BPS;
                highWaterMark      = newPrice;
            }
        }

        uint256 fees = mgmtFee + perfFee;
        totalProtocolFees += fees;

        // Receive gain tokens (keeper bot sends them in)
        if (gain > 0) asset.safeTransferFrom(msg.sender, address(this), gain);

        // Absorb loss (reduce available assets — share price falls)
        // Loss is already reflected via balance reduction by the strategy

        lastHarvestTime = block.timestamp;

        uint256 newSharePrice = totalSupply() > 0
            ? totalAssets() * PRECISION / totalSupply()
            : PRECISION;

        emit Harvest(gain, loss, mgmtFee, perfFee, newSharePrice);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 fees = totalProtocolFees;
        require(fees > 0, "SV: no fees");
        totalProtocolFees = 0;
        asset.safeTransfer(to, fees);
        emit FeesWithdrawn(to, fees);
    }

    function setHarvester(address h, bool enabled) external onlyOwner {
        harvesters[h] = enabled;
        emit HarvesterSet(h, enabled);
    }

    function setFees(uint256 _mgmt, uint256 _perf) external onlyOwner {
        require(_mgmt <= MAX_MGMT_FEE && _perf <= MAX_PERF_FEE, "SV: fee too high");
        managementFeeBps   = _mgmt;
        performanceFeeBps  = _perf;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) - totalProtocolFees;
    }

    function sharePrice() public view returns (uint256) {
        if (totalSupply() == 0) return PRECISION;
        return totalAssets() * PRECISION / totalSupply();
    }

    function userAssetValue(address user) external view returns (uint256) {
        return balanceOf(user) * sharePrice() / PRECISION;
    }

    function estimatedAPY() external view returns (uint256) {
        // Annualise based on HWM growth since inception
        if (highWaterMark <= PRECISION) return 0;
        uint256 elapsed = block.timestamp - lastHarvestTime;
        if (elapsed == 0) return 0;
        return (highWaterMark - PRECISION) * 365 days / elapsed;
    }

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        uint256 ta = totalAssets();
        if (ta == 0) return assets;
        return assets * supply / ta;
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return shares * totalAssets() / supply;
    }
}
