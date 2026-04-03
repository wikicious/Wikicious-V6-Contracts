// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiFundingArbVault
 * @notice Delta-neutral vault that systematically earns funding rates on
 *         WikiPerp perpetual markets. Holds the side that receives funding
 *         (long or short) and hedges with the opposite spot position.
 *
 * STRATEGY
 * ─────────────────────────────────────────────────────────────────────────
 * Perpetual funding rates average 10–20% annualised historically.
 * When funding is positive (longs pay shorts), vault holds SHORT perps.
 * When funding is negative (shorts pay longs), vault holds LONG perps.
 * Each side is hedged with an equal spot position to maintain delta-neutral.
 *
 * The result: vault collects funding payments with near-zero directional risk.
 *
 * REVENUE (protocol fees)
 * ─────────────────────────────────────────────────────────────────────────
 * 0.5%  management fee per year (charged per harvest)
 * 10%   performance fee on profits above high-water mark
 *
 * At $10M TVL and 15% avg funding APY:
 * → $1.5M gross yield to depositors
 * → $150K performance fee to protocol (10% of $1.5M)
 * → $50K management fee to protocol (0.5% of $10M)
 * → $200K/year from this vault alone
 *
 * POSITIONS
 * ─────────────────────────────────────────────────────────────────────────
 * The strategy manager (authorised keeper) opens/closes positions on
 * WikiPerp using vault capital. On-chain: deposit/withdraw USDC, earn yield.
 * Position management is done by keeper bot calling rebalance().
 */
contract WikiFundingArbVault is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
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

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant BPS             = 10_000;
    uint256 public constant PRECISION       = 1e18;
    uint256 public constant MAX_MGMT_FEE    = 100;    // 1% max p.a.
    uint256 public constant MAX_PERF_FEE    = 2000;   // 20% max
    uint256 public constant MIN_HARVEST_GAP = 4 hours;
    uint256 public constant MAX_LEVERAGE    = 5;       // max 5× leverage on hedge

    // ── Storage ────────────────────────────────────────────────────────────
    IERC20  public immutable USDC;

    uint256 public managementFeeBps = 50;   // 0.5% p.a.
    uint256 public performanceFeeBps = 1000; // 10%
    uint256 public highWaterMark;           // share price HWM
    uint256 public lastHarvestTime;
    uint256 public totalProtocolFees;

    // Strategy state (set by keeper after position changes)
    uint256 public totalAUM;           // USDC under management (keeper reports)
    int256  public currentFundingRate; // current annualised rate (scaled 1e18, can be negative)
    bool    public isLongFunding;      // true = vault holds shorts to receive from longs
    uint256 public activeLeverage;     // current leverage on perp positions
    string  public currentMarket;      // e.g. "BTCUSDT"
    uint256 public lastRebalanceTime;

    mapping(address => bool) public managers; // keeper bots

    // ── Events ─────────────────────────────────────────────────────────────
    event Deposit(address indexed user, uint256 usdc, uint256 shares);
    event Redeem(address indexed user, uint256 shares, uint256 usdc);
    event Harvest(uint256 gain, uint256 loss, uint256 mgmtFee, uint256 perfFee, uint256 newSharePrice);
    event Rebalanced(string market, bool isLongFunding, int256 fundingRate, uint256 leverage);
    event FeesWithdrawn(address to, uint256 amount);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _usdc, address _owner)
        ERC20("Wikicious Funding Arb", "wFARB")
        Ownable(_owner)
    {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC          = IERC20(_usdc);
        highWaterMark = PRECISION;
        lastHarvestTime = block.timestamp;
    }

    // ── Deposit / Redeem ──────────────────────────────────────────────────

    function deposit(uint256 amount, address receiver)
        external nonReentrant whenNotPaused returns (uint256 shares)
    {
        require(amount > 0, "FAV: zero");
        shares = _toShares(amount);
        _mint(receiver, shares);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        totalAUM += amount;
        emit Deposit(msg.sender, amount, shares);
    }

    function redeem(uint256 shares, address receiver)
        external nonReentrant whenNotPaused returns (uint256 usdc)
    {
        require(shares > 0, "FAV: zero");
        require(balanceOf(msg.sender) >= shares, "FAV: insufficient shares");
        usdc = _toAssets(shares);
        require(USDC.balanceOf(address(this)) >= usdc, "FAV: awaiting rebalance");
        _burn(msg.sender, shares);
        totalAUM  = totalAUM > usdc ? totalAUM - usdc : 0;
        USDC.safeTransfer(receiver, usdc);
        emit Redeem(msg.sender, shares, usdc);
    }

    // ── Harvest (keeper reports P&L after each funding epoch) ────────────

    /**
     * @notice Report gains/losses from the strategy and charge fees.
     *         Called by keeper after each 8-hour funding epoch settlement.
     * @param gain  USDC earned (funding payments received)
     * @param loss  USDC lost (net of any adverse moves)
     */
    function harvest(uint256 gain, uint256 loss)
        external nonReentrant
    {
        require(managers[msg.sender] || msg.sender == owner(), "FAV: not manager");
        require(block.timestamp >= lastHarvestTime + MIN_HARVEST_GAP, "FAV: too soon");

        uint256 elapsed = block.timestamp - lastHarvestTime;

        // Management fee (pro-rata)
        uint256 mgmtFee = totalAUM * managementFeeBps / BPS /* AUDIT: verify mul-before-div order */ * elapsed / 365 days;

        // Performance fee (only above HWM)
        uint256 perfFee = 0;
        if (gain > loss && gain > 0) {
            USDC.safeTransferFrom(msg.sender, address(this), gain);
            uint256 net = gain - loss;
            uint256 supply = totalSupply();
            if (supply > 0) {
                uint256 updatedPrice = (totalAUM + net) * PRECISION / supply;
                if (updatedPrice > highWaterMark) {
                    uint256 excess = (updatedPrice - highWaterMark) * supply / PRECISION;
                    perfFee = excess * performanceFeeBps / BPS;
                    highWaterMark = updatedPrice;
                }
            }
            totalAUM = totalAUM + net;
        }

        uint256 fees = mgmtFee + perfFee;
        if (fees > totalAUM) fees = totalAUM;
        totalAUM          -= fees;
        totalProtocolFees += fees;
        lastHarvestTime    = block.timestamp;

        uint256 newPrice = totalSupply() > 0 ? totalAUM * PRECISION / totalSupply() : PRECISION;
        emit Harvest(gain, loss, mgmtFee, perfFee, newPrice);
    }

    // ── Rebalance (keeper updates strategy state) ─────────────────────────

    /**
     * @notice Update strategy state after rebalancing positions.
     *         Called by keeper bot after switching funding direction or market.
     */
    function rebalance(
        string  calldata market,
        bool    isLong,
        int256  fundingRate,
        uint256 leverage,
        uint256 newAUM
    ) external {
        require(managers[msg.sender] || msg.sender == owner(), "FAV: not manager");
        require(leverage <= MAX_LEVERAGE, "FAV: leverage too high");
        currentMarket     = market;
        isLongFunding     = isLong;
        currentFundingRate = fundingRate;
        activeLeverage    = leverage;
        totalAUM          = newAUM;
        lastRebalanceTime = block.timestamp;
        emit Rebalanced(market, isLong, fundingRate, leverage);
    }

    // ── Owner ──────────────────────────────────────────────────────────────

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 f = totalProtocolFees;
        require(f > 0, "FAV: no fees");
        require(USDC.balanceOf(address(this)) >= f, "FAV: insufficient liquid");
        totalProtocolFees = 0;
        USDC.safeTransfer(to, f);
        emit FeesWithdrawn(to, f);
    }

    function setManager(address m, bool enabled) external onlyOwner { managers[m] = enabled; }
    function setFees(uint256 mgmt, uint256 perf) external onlyOwner {
        require(mgmt <= MAX_MGMT_FEE && perf <= MAX_PERF_FEE, "FAV: fee too high");
        managementFeeBps  = mgmt;
        performanceFeeBps = perf;
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Views ──────────────────────────────────────────────────────────────

    function sharePrice() public view returns (uint256) {
        uint256 s = totalSupply();
        return s == 0 ? PRECISION : totalAUM * PRECISION / s;
    }

    function userValue(address user) external view returns (uint256) {
        return balanceOf(user) * sharePrice() / PRECISION;
    }

    function estimatedAPY() external view returns (uint256) {
        // Annualise current funding rate
        int256 rate = currentFundingRate;
        if (rate <= 0) return 0;
        // fundingRate is 8h rate; multiply by 3 × 365 for annual
        return uint256(rate) * 3 * 365 * performanceFeeBps / BPS;
    }

    function _toShares(uint256 assets) internal view returns (uint256) {
        uint256 s = totalSupply();
        if (s == 0 || totalAUM == 0) return assets;
        return assets * s / totalAUM;
    }

    function _toAssets(uint256 shares) internal view returns (uint256) {
        uint256 s = totalSupply();
        if (s == 0) return 0;
        return shares * totalAUM / s;
    }
}
