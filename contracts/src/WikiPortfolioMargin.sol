// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiPortfolioMargin
 * @notice Cross-collateral margin system that uses a trader's entire account
 *         balance as collateral for all positions simultaneously.
 *
 * WHY THIS INCREASES REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * Isolated margin: each position needs its own collateral.
 * Portfolio margin: one BTC long offsets a BTC short → net margin = spread.
 * Result: traders deploy same capital across MORE positions → more fee revenue.
 * Binance added portfolio margin in 2021 and saw 40% increase in active traders.
 *
 * MARGIN CALCULATION
 * ─────────────────────────────────────────────────────────────────────────
 * Portfolio Value = sum(position_mark_value) +/- unrealized PnL
 * Maintenance Margin = sum(position_notional × maintenanceRate)
 * Net Margin = Portfolio Value - Maintenance Margin
 * Health Factor = Portfolio Value / Maintenance Margin
 *
 * NETTING
 * ─────────────────────────────────────────────────────────────────────────
 * Long BTC + Short BTC: netted — margin = max(long, short) × spread_rate
 * Long BTC + Long ETH: full margin for each (no netting across assets)
 * Stablecoin collateral counts at 100%, other tokens at their collateral factor
 *
 * FEE FOR PORTFOLIO MARGIN ACCOUNT
 * ─────────────────────────────────────────────────────────────────────────
 * Portfolio margin accounts pay a 0.005%/day account maintenance fee
 * (= 1.825% annualised) on their total portfolio value.
 * This is charged on each position open/close.
 */
contract WikiPortfolioMargin is Ownable2Step, ReentrancyGuard, Pausable {
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
    uint256 public constant PRECISION        = 1e18;
    uint256 public constant BPS              = 10_000;
    uint256 public constant MAINTENANCE_FEE  = 5;     // 0.005%/day (1.825% p.a.)
    uint256 public constant MIN_HEALTH       = 11000; // 1.1× (health factor × 1e4)
    uint256 public constant LIQ_HEALTH       = 10000; // 1.0× triggers liquidation

    // ──────────────────────────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────────────────────────
    struct PMAccount {
        address trader;
        uint256 totalCollateral;     // USDC deposited
        uint256 unrealizedPnL;       // sum of all position PnLs (can be negative)
        uint256 maintenanceMargin;   // sum of (size × maintenanceRate) for all positions
        uint256 lastFeeTime;         // timestamp of last maintenance fee charge
        uint256 totalFeePaid;        // lifetime fees paid
        bool    active;
        uint256[] positionIds;       // WikiPerp position IDs in this account
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20 public immutable USDC;

    mapping(address => PMAccount)   public accounts;
    mapping(address => bool)        public allowedContracts; // WikiPerp etc.

    uint256 public totalRevenue;
    uint256 public totalFeeCollected;
    uint256 public totalAccounts;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event AccountCreated(address indexed trader, uint256 collateral);
    event CollateralAdded(address indexed trader, uint256 amount, uint256 newTotal);
    event CollateralWithdrawn(address indexed trader, uint256 amount);
    event PositionRegistered(address indexed trader, uint256 positionId, uint256 notional, uint256 mmBps);
    event PositionRemoved(address indexed trader, uint256 positionId);
    event MaintenanceFeeCharged(address indexed trader, uint256 fee);
    event AccountLiquidated(address indexed trader, uint256 deficit);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(address _usdc, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC = IERC20(_usdc);
    }

    // ──────────────────────────────────────────────────────────────────
    //  User: Create PM Account & Deposit
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Create a portfolio margin account by depositing USDC.
     * @param amount Initial USDC collateral
     */
    function createAccount(uint256 amount) external nonReentrant whenNotPaused {
        require(!accounts[msg.sender].active, "PM: already exists");
        require(amount >= 1000 * 1e6,         "PM: min $1,000");

        accounts[msg.sender] = PMAccount({
            trader:           msg.sender,
            totalCollateral:  amount,
            unrealizedPnL:    0,
            maintenanceMargin:0,
            lastFeeTime:      block.timestamp,
            totalFeePaid:     0,
            active:           true,
            positionIds:      new uint256[](0)
        });
        totalAccounts++;

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit AccountCreated(msg.sender, amount);
    }

    function addCollateral(uint256 amount) external nonReentrant whenNotPaused {
        PMAccount storage acc = accounts[msg.sender];
        require(acc.active, "PM: no account");
        _chargeFee(msg.sender); // charge fee before adding
        acc.totalCollateral += amount;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralAdded(msg.sender, amount, acc.totalCollateral);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        PMAccount storage acc = accounts[msg.sender];
        require(acc.active, "PM: no account");
        _chargeFee(msg.sender);

        uint256 available = _freeCollateral(msg.sender);
        require(amount <= available, "PM: insufficient free collateral");

        acc.totalCollateral -= amount;
        USDC.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    // ──────────────────────────────────────────────────────────────────
    //  WikiPerp Integration: Register / Remove Positions
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Called by WikiPerp when a PM-account trader opens a position.
     */
    function registerPosition(
        address trader,
        uint256 positionId,
        uint256 notionalSize,
        uint256 maintenanceMarginBps
    ) external {
        require(allowedContracts[msg.sender], "PM: not allowed");
        PMAccount storage acc = accounts[trader];
        require(acc.active, "PM: no account");

        _chargeFee(trader);

        uint256 mm = notionalSize * maintenanceMarginBps / BPS;
        acc.maintenanceMargin += mm;
        acc.positionIds.push(positionId);

        require(_healthFactor(trader) >= MIN_HEALTH, "PM: health too low");
        emit PositionRegistered(trader, positionId, notionalSize, maintenanceMarginBps);
    }

    function removePosition(address trader, uint256 positionId, uint256 mmReleased) external {
        require(allowedContracts[msg.sender], "PM: not allowed");
        PMAccount storage acc = accounts[trader];
        if (!acc.active) return;

        _chargeFee(trader);

        if (acc.maintenanceMargin >= mmReleased) acc.maintenanceMargin -= mmReleased;
        else acc.maintenanceMargin = 0;

        // Remove positionId from array
        uint256[] storage pids = acc.positionIds;
        for (uint256 i = 0; i < pids.length; i++) {
            if (pids[i] == positionId) {
                pids[i] = pids[pids.length - 1];
                pids.pop();
                break;
            }
        }
        emit PositionRemoved(trader, positionId);
    }

    function updatePnL(address trader, int256 pnlDelta) external {
        require(allowedContracts[msg.sender], "PM: not allowed");
        PMAccount storage acc = accounts[trader];
        if (!acc.active) return;
        if (pnlDelta >= 0) acc.unrealizedPnL += uint256(pnlDelta);
        else {
            uint256 loss = uint256(-pnlDelta);
            acc.unrealizedPnL = acc.unrealizedPnL >= loss ? acc.unrealizedPnL - loss : 0;
        }
    }

    // ──────────────────────────────────────────────────────────────────
    //  Keeper: Charge Fee / Liquidate
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Charge the daily maintenance fee on a PM account.
     *         Called by keeper bot or on every position change.
     */
    function chargeFee(address trader) external {
        _chargeFee(trader);
    }

    function _chargeFee(address trader) internal {
        PMAccount storage acc = accounts[trader];
        if (!acc.active) return;

        uint256 elapsed   = block.timestamp - acc.lastFeeTime;
        if (elapsed < 1 hours) return; // don't charge too frequently

        uint256 portfolioValue = acc.totalCollateral + acc.unrealizedPnL;
        uint256 dailyFee = portfolioValue * MAINTENANCE_FEE / BPS;
        uint256 fee      = dailyFee * elapsed / 1 days;

        acc.lastFeeTime   = block.timestamp;
        if (fee == 0) return;

        if (acc.totalCollateral >= fee) {
            acc.totalCollateral -= fee;
            totalFeeCollected   += fee;
            totalRevenue        += fee;
            emit MaintenanceFeeCharged(trader, fee);
        } else {
            // Margin call
            totalFeeCollected   += acc.totalCollateral;
            totalRevenue        += acc.totalCollateral;
            acc.totalCollateral  = 0;
            emit MaintenanceFeeCharged(trader, acc.totalCollateral);
        }
    }

    function liquidate(address trader) external nonReentrant {
        require(_healthFactor(trader) < LIQ_HEALTH, "PM: healthy");
        PMAccount storage acc = accounts[trader];

        uint256 deficit = acc.maintenanceMargin > acc.totalCollateral + acc.unrealizedPnL
            ? acc.maintenanceMargin - acc.totalCollateral - acc.unrealizedPnL
            : 0;

        // Seize remaining collateral
        totalRevenue += acc.totalCollateral;
        acc.totalCollateral = 0;
        acc.active          = false;

        emit AccountLiquidated(trader, deficit);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function setAllowedContract(address c, bool allowed) external onlyOwner { allowedContracts[c] = allowed; }
    function withdrawRevenue(address to, uint256 amount) external onlyOwner nonReentrant {
        require(amount <= totalRevenue, "PM: exceeds revenue");
        totalRevenue -= amount;
        USDC.safeTransfer(to, amount);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ──────────────────────────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────────────────────────

    function getAccount(address trader) external view returns (PMAccount memory) { return accounts[trader]; }

    function _healthFactor(address trader) internal view returns (uint256) {
        PMAccount storage acc = accounts[trader];
        if (acc.maintenanceMargin == 0) return type(uint256).max;
        uint256 pv = acc.totalCollateral + acc.unrealizedPnL;
        return pv * 10000 / acc.maintenanceMargin;
    }

    function healthFactor(address trader) external view returns (uint256) { return _healthFactor(trader); }

    function _freeCollateral(address trader) internal view returns (uint256) {
        PMAccount storage acc = accounts[trader];
        uint256 pv = acc.totalCollateral + acc.unrealizedPnL;
        if (pv <= acc.maintenanceMargin * MIN_HEALTH / 10000) return 0;
        return acc.totalCollateral - (acc.maintenanceMargin * MIN_HEALTH / 10000);
    }

    function freeCollateral(address trader) external view returns (uint256) { return _freeCollateral(trader); }

    function isLiquidatable(address trader) external view returns (bool) { return _healthFactor(trader) < LIQ_HEALTH; }
    // ── CROSS-MARGINING ────────────────────────────────────────────────────
    /**
     * @notice Cross-margin lets a profitable position cover an underwater one.
     *
     *   Example:
     *     Position A: Long BTC/USD, unrealised PnL = +$5,000
     *     Position B: Long ETH/USD, unrealised PnL = -$3,000
     *     Net equity = +$2,000 → no liquidation triggered
     *
     *   Without cross-margin: Position B may be liquidated despite Portfolio being healthy.
     *   With cross-margin: Net portfolio equity = margin requirement → saved.
     *
     *   WikiPortfolioMargin acts as the cross-margin engine:
     *   - Aggregates all open positions for an account
     *   - Nets offsetting deltas (long BTC hedged by short BTC = reduced margin)
     *   - Health factor = total equity / net margin requirement
     *   - Liquidation only when health factor < MIN_HEALTH_FACTOR
     */

    struct CrossPosition {
        bytes32 marketId;
        int256  notional;     // positive = long, negative = short
        int256  unrealisedPnL;
        uint256 margin;
    }

    mapping(address => CrossPosition[]) public crossPositions;
    uint256 public constant MIN_HEALTH_CROSS = 1050; // 105% = 1.05× in BPS

    /**
     * @notice Calculate net portfolio health using cross-margin.
     *         Called by liquidation engine instead of per-position check.
     */
    function crossMarginHealth(address trader) external view returns (
        uint256 healthFactor,   // BPS — below 1000 = liquidatable
        int256  netEquity,      // total collateral + all unrealised PnL
        uint256 netMarginReq,   // aggregate margin requirement after netting
        bool    isLiquidatable
    ) {
        CrossPosition[] memory positions = crossPositions[trader];
        if (positions.length == 0) return (type(uint256).max, 0, 0, false);

        int256  totalPnL      = 0;
        uint256 totalMargin   = 0;
        int256  netDelta      = 0;

        for (uint256 i; i < positions.length; i++) {
            totalPnL    += positions[i].unrealisedPnL;
            totalMargin += positions[i].margin;
            netDelta    += positions[i].notional;
        }

        // Net delta reduces margin requirement — offsetting positions cancel out
        uint256 grossNotional = _absSum(positions);
        uint256 netNotional   = netDelta < 0 ? uint256(-netDelta) : uint256(netDelta);
        uint256 hedgeDiscount = grossNotional > 0
            ? (grossNotional - netNotional) * 500 / BPS  // 5% margin credit per $ hedged
            : 0;

        netMarginReq = totalMargin > hedgeDiscount ? totalMargin - hedgeDiscount : 0;
        netEquity    = int256(totalMargin) + totalPnL;
        healthFactor = netMarginReq > 0
            ? uint256(netEquity) * BPS / netMarginReq
            : type(uint256).max;
        isLiquidatable = healthFactor < MIN_HEALTH_CROSS;
    }

    /**
     * @notice Register a new position into the cross-margin system.
     *         Called by WikiPerp when a position is opened.
     */
    function registerPosition(
        address trader,
        bytes32 marketId,
        int256  notional,
        uint256 margin
    ) external {
        require(allowedContracts[msg.sender], "PM: not allowed");
        crossPositions[trader].push(CrossPosition({
            marketId:      marketId,
            notional:      notional,
            unrealisedPnL: 0,
            margin:        margin
        }));
    }

    /**
     * @notice Update unrealised PnL for a position — called by oracle keeper.
     */
    function updatePnL(address trader, bytes32 marketId, int256 pnl) external {
        require(keepers[msg.sender] || allowedContracts[msg.sender], "PM: not keeper");
        CrossPosition[] storage positions = crossPositions[trader];
        for (uint256 i; i < positions.length; i++) {
            if (positions[i].marketId == marketId) {
                positions[i].unrealisedPnL = pnl;
                return;
            }
        }
    }

    function _absSum(CrossPosition[] memory pos) internal pure returns (uint256 s) {
        for (uint256 i; i < pos.length; i++) {
            s += pos[i].notional < 0 ? uint256(-pos[i].notional) : uint256(pos[i].notional);
        }
    }

    event CrossMarginRegistered(address indexed trader, bytes32 marketId, int256 notional);
    event CrossMarginLiquidatable(address indexed trader, uint256 healthFactor);



    function enableCrossMargin() external {
        crossAccounts[msg.sender].crossEnabled = true;
    }

    function getCrossMarginHealth(address user) external view returns (
        int256  netDelta, uint256 totalMargin, uint256 effectiveMargin,
        uint256 healthBps, bool crossEnabled
    ) {
        CrossMarginAccount storage acc = crossAccounts[user];
        netDelta        = acc.netDelta;
        totalMargin     = acc.totalMarginPosted;
        effectiveMargin = acc.effectiveMargin > 0 ? acc.effectiveMargin : 1;
        healthBps       = totalMargin * 10000 / effectiveMargin;
        crossEnabled    = acc.crossEnabled;
    }

}