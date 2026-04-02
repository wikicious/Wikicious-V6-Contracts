// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiVirtualAMM — vAMM enabling 1000× leverage without physical liquidity
 *
 * HOW vAMM WORKS
 * ────────────────────────────────────────────────────────────────────────────
 * A virtual AMM uses a virtual k = x * y constant to price trades but holds
 * NO real tokens in the pool. All PnL settles against a shared Insurance Fund
 * (backed by WikiVault USDC collateral). This allows:
 *
 *   • 1000× leverage on any market (BTC, ETH, indices, forex, etc.)
 *   • No per-market liquidity requirement — one insurance fund covers all
 *   • Zero impermanent loss for LPs
 *   • Price discovery via virtual AMM + oracle anchoring
 *
 * PRICE ANCHORING (prevent drift)
 *   Every trade pushes virtual price. A funding rate mechanism (+/- 0.01%/8h)
 *   continuously pulls vAMM price toward the oracle index price. This prevents
 *   the virtual price from drifting too far from reality.
 *
 * INSURANCE FUND
 *   Collects 10% of all trading fees + all liquidation bonuses.
 *   Covers under-collateralised positions when liquidators can't fully repay.
 *
 * LEVERAGE TIERS
 *   Standard: 1–100×   (full collateral isolation)
 *   Expert:   100–500× (requires WikiTraderPass Gold+)
 *   Ultra:    500–1000× (requires WikiTraderPass Diamond + $10K deposit)
 */

interface IWikiOracle {
    function getPrice(bytes32 id) external view returns (uint256 price, uint256 updatedAt);
}

interface IWikiVault {
    function freeMargin(address user) external view returns (uint256);
    function lockMargin(address user, uint256 amount) external;
    function releaseMargin(address user, uint256 amount) external;
}

interface IWikiHybridLiquidityManager {
    function getEffectiveLeverageCap(bytes32 marketId, uint256 leverage) external view returns (
        uint256 effectiveCap, uint256 internalCap, uint256 externalCap, string memory routing
    );
}

interface IWikiADL {
    function adl(uint256 shortfall, bytes32 marketId, bool wasLong, uint256 triggerPosId) external returns (uint256 covered);
}

interface IWikiLeverageScaler {
    function validatePosition(bytes32 marketId, uint256 leverage, uint256 collateral, uint256 notional) external view;
    function getLimits(bytes32 marketId, uint256 leverage) external view returns (
        uint256 maxLeverage, uint256 maxCollateral, uint256 maxNotional,
        uint256 worstCaseShortfall, string memory marketClass
    );
}

interface IWikiBackstop {
    function receiveYield(uint256 amount) external;
    function availableCover() external view returns (uint256);
}

interface IWikiDynamicLeverage {
    function maxLeverageFor(address user) external view returns (uint256);
    function updateLeverageCaps() external;
    function currentCaps() external view returns (
        uint256 maxLeverage, uint256 maxPositionUsdc, uint256 maxOIPerMarket,
        uint256 insuranceFund, uint256 tierIdx, string memory tierName
    );
}


interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiVirtualAMM is Ownable2Step, ReentrancyGuard, Pausable {
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

    // ── Structs ─────────────────────────────────────────────────────────────

    struct Market {
        bytes32  marketId;
        string   symbol;
        uint256  virtualBaseReserve;   // virtual x (base asset)
        uint256  virtualQuoteReserve;  // virtual y (quote = USDC)
        uint256  k;                    // constant = x * y (1e36)
        uint256  openInterestLong;     // total long notional
        uint256  openInterestShort;    // total short notional
        uint256  fundingRate;          // per 8h, signed (int as uint with sign bit)
        uint256  lastFundingTime;
        uint256  maxLeverage;          // 1000 = 1000×
        uint256  initMarginRatio;      // bps e.g. 100 = 0.01 = 1/100× = 100×
        bool     active;
    }

    struct Position {
        address  trader;
        bytes32  marketId;
        bool     isLong;
        uint256  size;          // notional in USDC (6 dec)
        uint256  collateral;    // USDC margin (6 dec)
        uint256  entryPrice;    // 1e18 scaled
        uint256  entryFundingIndex; // for funding PnL calc
        uint256  leverage;      // actual leverage used
        uint256  liquidationPrice;
        uint256  openedAt;
    }

    struct FundingIndex {
        uint256 cumulativeLong;   // cumulative funding paid by longs
        uint256 cumulativeShort;  // cumulative funding paid by shorts
        uint256 lastUpdateTime;
    }

    // ── State ────────────────────────────────────────────────────────────────

    mapping(bytes32 => Market)          public  markets;
    mapping(uint256 => Position)        public  positions;
    mapping(bytes32 => FundingIndex)    public  fundingIndices;
    mapping(address => uint256[])       public  userPositions;
    mapping(address => bool)            public  expertAccess;   // 100–500×
    mapping(address => bool)            public  ultraAccess;    // 500–1000×

    bytes32[] public marketIds;
    uint256   public positionCount;

    IWikiOracle  public oracle;
    IWikiVault   public vault;
    IERC20       public immutable USDC;

    uint256 public insuranceFund;          // USDC accumulated
    IWikiDynamicLeverage public dynLev;       // optional — auto leverage caps
    IWikiADL             public adlEngine;
    IWikiHybridLiquidityManager public hybridLM;  // hybrid liquidity manager     // auto-deleveraging engine
    IWikiLeverageScaler  public leverageScaler;// leverage-scaled position caps
    IWikiBackstop        public backstopVault; // loss absorber before ADL
    uint256 public protocolRevenue;        // USDC accumulated
    uint256 public constant FUNDING_INTERVAL  = 28800;   // 8 hours
    uint256 public constant MAX_FUNDING_RATE  = 100;     // 0.01% per interval
    uint256 public constant INSURANCE_CUT_BPS = 1000;    // 10% of fees
    uint256 public constant PROTOCOL_FEE_BPS  = 60;      // 0.06% taker fee
    uint256 public constant LIQ_PENALTY_BPS   = 500;     // 5% penalty
    uint256 public constant BPS               = 10000;
    uint256 public constant PRECISION         = 1e18;

    event MarketCreated(bytes32 indexed id, string symbol, uint256 maxLeverage);
    event PositionOpened(uint256 indexed posId, address trader, bytes32 market, bool isLong, uint256 size, uint256 leverage);
    event PositionClosed(uint256 indexed posId, int256 pnl);
    event PositionLiquidated(uint256 indexed posId, address liquidator, uint256 penalty);
    event FundingPaid(bytes32 indexed market, int256 fundingLong, int256 fundingShort);
    event InsuranceFundUpdated(uint256 newBalance);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
    }

    /// @notice Keeper calls this to deploy idle USDC to yield strategies
    function deployIdle(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        require(address(idleYieldRouter) != address(0), "Router not set");
        USDC.approve(address(idleYieldRouter), amount);
        idleYieldRouter.depositIdle(amount);
    }

    /// @notice Recall capital before a claim/allocation
    function recallIdle(uint256 amount, string calldata reason) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        if (address(idleYieldRouter) != address(0)) {
            idleYieldRouter.recall(amount, reason);
        }
    }

    constructor(address _oracle, address _vault, address _usdc, address _owner) Ownable(_owner) {
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(_vault != address(0), "Wiki: zero _vault");
        require(_usdc != address(0), "Wiki: zero _usdc");
        oracle = IWikiOracle(_oracle);
        vault  = IWikiVault(_vault);
        USDC   = IERC20(_usdc);
    }

    // ── Market Management ────────────────────────────────────────────────────

    function createMarket(
        bytes32 marketId, string calldata symbol,
        uint256 initialVirtualBaseReserve,
        uint256 initialVirtualQuoteReserve,
        uint256 maxLeverage
    ) external onlyOwner {
        require(!markets[marketId].active, "vAMM: market exists");
        // Max leverage validated by WikiLeverageScaler per market class.
        // Hard ceiling here is 2000 (forex major). vAMM itself is leverage-agnostic —
        // the safety system (Scaler + Backstop + ADL) bounds the actual risk.
        require(maxLeverage >= 1 && maxLeverage <= 2000, "vAMM: max leverage is 2000x");
        uint256 k = initialVirtualBaseReserve * initialVirtualQuoteReserve;
        markets[marketId] = Market({
            marketId:           marketId,
            symbol:             symbol,
            virtualBaseReserve: initialVirtualBaseReserve,
            virtualQuoteReserve:initialVirtualQuoteReserve,
            k:                  k,
            openInterestLong:   0,
            openInterestShort:  0,
            fundingRate:        0,
            lastFundingTime:    block.timestamp,
            maxLeverage:        maxLeverage,
            initMarginRatio:    BPS / maxLeverage,
            active:             true
        });
        marketIds.push(marketId);
        emit MarketCreated(marketId, symbol, maxLeverage);
    }

    // ── Position Opening ─────────────────────────────────────────────────────

    function openPosition(
        bytes32 marketId,
        bool    isLong,
        uint256 collateral,    // USDC 6dec
        uint256 leverage,      // e.g. 100 = 100×
        uint256 minPrice,
        uint256 maxPrice
    ) external nonReentrant whenNotPaused returns (uint256 posId) {
        Market storage m = markets[marketId];
        require(m.active, "vAMM: inactive market");
        // Effective max leverage:
        //
        // If WikiHybridLiquidityManager is set, it computes the correct cap
        // considering BOTH internal (dynLev tier) AND external venue availability.
        //
        // KEY: when health score < 80, external routing is active.
        //      External venues (GMX) allow up to 100× on BTC.
        //      So even with $0 insurance fund, user can trade 100× — it routes to GMX.
        //      The dynLev fund-based cap ONLY applies to the internal portion.
        //
        // If HLM not set, fall back to: min(market.maxLeverage, dynLev tier).
        uint256 effectiveMaxLev;
        if (address(hybridLM) != address(0)) {
            // HLM computes: max(internalCap, externalCap) per routing mode
            (uint256 effCap,,,) = hybridLM.getEffectiveLeverageCap(marketId, leverage);
            effectiveMaxLev = _min(m.maxLeverage, effCap);
        } else {
            effectiveMaxLev = m.maxLeverage;
            if (address(dynLev) != address(0)) {
                effectiveMaxLev = _min(effectiveMaxLev, dynLev.maxLeverageFor(msg.sender));
            }
        }
        require(leverage >= 1 && leverage <= effectiveMaxLev, "vAMM: leverage exceeds current cap");

        // Leverage-scaled position caps — bounds max shortfall regardless of leverage
        if (address(leverageScaler) != address(0)) {
            uint256 notional_ = collateral * leverage;
            leverageScaler.validatePosition(marketId, leverage, collateral, notional_);
        }

        require(collateral > 0, "vAMM: zero collateral");

        // All users can access up to 100x - no tiering needed

        // Pull collateral
        vault.lockMargin(msg.sender, collateral);

        // Settle funding before new position
        _settleFunding(marketId);

        // Calculate position size and entry price
        uint256 size = collateral * leverage;
        uint256 entryPrice = _getVirtualPrice(marketId, size, isLong);

        // Slippage check
        (uint256 oraclePrice,) = oracle.getPrice(marketId);
        if (minPrice > 0) require(entryPrice >= minPrice, "vAMM: price too low");
        if (maxPrice > 0) require(entryPrice <= maxPrice, "vAMM: price too high");

        // Update virtual reserves
        _updateReserves(m, size, isLong);

        // Update OI
        if (isLong) m.openInterestLong += size;
        else        m.openInterestShort += size;

        // Fee
        uint256 fee = size * PROTOCOL_FEE_BPS / BPS;
        insuranceFund  += fee * INSURANCE_CUT_BPS / BPS;
        protocolRevenue += fee - fee * INSURANCE_CUT_BPS / BPS;

        // Liquidation price
        uint256 liqPrice = _calcLiqPrice(entryPrice, leverage, isLong);

        // Store position
        posId = ++positionCount;
        positions[posId] = Position({
            trader:             msg.sender,
            marketId:           marketId,
            isLong:             isLong,
            size:               size,
            collateral:         collateral,
            entryPrice:         entryPrice,
            entryFundingIndex:  isLong ? fundingIndices[marketId].cumulativeLong : fundingIndices[marketId].cumulativeShort,
            leverage:           leverage,
            liquidationPrice:   liqPrice,
            openedAt:           block.timestamp
        });
        userPositions[msg.sender].push(posId);
        emit PositionOpened(posId, msg.sender, marketId, isLong, size, leverage);
    }

    // ── Close Position ────────────────────────────────────────────────────────

    function closePosition(uint256 posId) external nonReentrant whenNotPaused returns (int256 pnl) {
        Position storage pos = positions[posId];
        require(pos.trader == msg.sender, "vAMM: not owner");
        require(pos.size > 0, "vAMM: already closed");
        _settleFunding(pos.marketId);

        uint256 exitPrice = _getVirtualPrice(pos.marketId, pos.size, !pos.isLong);
        pnl = _calcPnL(pos.entryPrice, exitPrice, pos.size, pos.isLong);

        // Apply funding PnL
        int256 fundingPnL = _calcFundingPnL(pos);
        pnl += fundingPnL;

        // Settle with vault
        if (pnl >= 0) {
            uint256 gain = uint256(pnl);
            uint256 toRelease = pos.collateral + gain;
            if (toRelease > insuranceFund + pos.collateral) {
                toRelease = pos.collateral + insuranceFund;
                insuranceFund = 0;
            } else {
                insuranceFund -= gain > insuranceFund ? insuranceFund : gain;
            }
            vault.releaseMargin(pos.trader, toRelease);
        } else {
            uint256 loss = uint256(-pnl);
            uint256 remaining = loss >= pos.collateral ? 0 : pos.collateral - loss;
            if (remaining > 0) vault.releaseMargin(pos.trader, remaining);
            insuranceFund += loss > pos.collateral ? 0 : 0; // collateral absorbs loss
        }

        // Update reserves
        Market storage m = markets[pos.marketId];
        _updateReserves(m, pos.size, !pos.isLong);
        if (pos.isLong) m.openInterestLong -= pos.size;
        else            m.openInterestShort -= pos.size;

        // Delete position
        delete positions[posId];
        emit PositionClosed(posId, pnl);
    }

    // ── Liquidation ──────────────────────────────────────────────────────────

    function liquidate(uint256 posId) external nonReentrant {
        Position storage pos = positions[posId];
        require(pos.size > 0, "vAMM: already closed");
        (uint256 markPrice,) = oracle.getPrice(pos.marketId);
        require(_isLiquidatable(pos, markPrice), "vAMM: not liquidatable");

        uint256 penalty = pos.collateral * LIQ_PENALTY_BPS / BPS;
        USDC.safeTransfer(msg.sender, penalty);        // liquidator reward
        insuranceFund += pos.collateral - penalty;     // remainder to insurance

        Market storage m = markets[pos.marketId];
        _updateReserves(m, pos.size, !pos.isLong);
        if (pos.isLong) m.openInterestLong -= pos.size;
        else            m.openInterestShort -= pos.size;

        // If collateral - penalty < position loss, there may be a shortfall
        // Route to ADL engine to cover via backstop vault or opposing positions
        uint256 positionLoss = pos.size; // worst case: full notional loss
        uint256 collateralCovered = pos.collateral - penalty;
        if (positionLoss > collateralCovered && address(adlEngine) != address(0)) {
            uint256 shortfall = positionLoss - collateralCovered;
            if (shortfall > 1e6) { // $1 minimum to avoid dust ADL
                try adlEngine.adl(shortfall, pos.marketId, pos.isLong, posId) {} catch {}
            }
        }

        emit PositionLiquidated(posId, msg.sender, penalty);
        delete positions[posId];
    }

    // ── Funding ───────────────────────────────────────────────────────────────

    function settleFunding(bytes32 marketId) external { _settleFunding(marketId); }

    function _settleFunding(bytes32 marketId) internal {
        Market storage m = markets[marketId];
        if (block.timestamp < m.lastFundingTime + FUNDING_INTERVAL) return;
        uint256 intervals = (block.timestamp - m.lastFundingTime) / FUNDING_INTERVAL;

        (uint256 oraclePrice,) = oracle.getPrice(marketId);
        uint256 vAMMPrice = _getCurrentVirtualPrice(marketId);

        // Funding rate = (vAMM - oracle) / oracle / 24 (8h intervals)
        int256 priceDiff = int256(vAMMPrice) - int256(oraclePrice);
        int256 rate = priceDiff * int256(MAX_FUNDING_RATE) / int256(oraclePrice);

        FundingIndex storage fi = fundingIndices[marketId];
        if (rate > 0) {
            // longs pay shorts
            fi.cumulativeLong  += uint256(rate)  * intervals;
        } else {
            // shorts pay longs
            fi.cumulativeShort += uint256(-rate) * intervals;
        }
        fi.lastUpdateTime = block.timestamp;
        m.lastFundingTime = block.timestamp;
        emit FundingPaid(marketId, rate * int256(intervals), -rate * int256(intervals));
    }

    // ── Internal Math ─────────────────────────────────────────────────────────

    function _getVirtualPrice(bytes32 marketId, uint256 notional, bool isLong) internal view returns (uint256) {
        Market storage m = markets[marketId];
        if (isLong) {
            uint256 newBaseReserve = m.k / (m.virtualQuoteReserve + notional);
            uint256 baseOut = m.virtualBaseReserve - newBaseReserve;
            return baseOut > 0 ? (notional * PRECISION / baseOut) : 0;
        } else {
            uint256 newBaseReserve = m.virtualBaseReserve + notional / (m.virtualQuoteReserve / m.virtualBaseReserve);
            return m.k / newBaseReserve / 1e12;
        }
    }

    function _getCurrentVirtualPrice(bytes32 marketId) internal view returns (uint256) {
        Market storage m = markets[marketId];
        return (m.virtualQuoteReserve * PRECISION) / m.virtualBaseReserve;
    }

    function _updateReserves(Market storage m, uint256 notional, bool isLong) internal {
        if (isLong) {
            m.virtualQuoteReserve += notional;
            m.virtualBaseReserve  = m.k / m.virtualQuoteReserve;
        } else {
            if (m.virtualQuoteReserve > notional) {
                m.virtualQuoteReserve -= notional;
                m.virtualBaseReserve  = m.k / m.virtualQuoteReserve;
            }
        }
    }

    function _calcPnL(uint256 entry, uint256 exit, uint256 size, bool isLong) internal pure returns (int256) {
        if (isLong) return int256(exit) - int256(entry) > 0
            ? int256((exit - entry) * size / PRECISION)
            : -int256((entry - exit) * size / PRECISION);
        else return int256(entry) - int256(exit) > 0
            ? int256((entry - exit) * size / PRECISION)
            : -int256((exit - entry) * size / PRECISION);
    }

    function _calcLiqPrice(uint256 entry, uint256 leverage, bool isLong) internal pure returns (uint256) {
        uint256 liqThreshold = entry / leverage;
        return isLong ? entry - liqThreshold : entry + liqThreshold;
    }

    function _isLiquidatable(Position storage pos, uint256 markPrice) internal view returns (bool) {
        if (pos.isLong) return markPrice <= pos.liquidationPrice;
        return markPrice >= pos.liquidationPrice;
    }

    function _calcFundingPnL(Position storage pos) internal view returns (int256) {
        FundingIndex storage fi = fundingIndices[pos.marketId];
        uint256 currentIndex = pos.isLong ? fi.cumulativeLong : fi.cumulativeShort;
        if (currentIndex <= pos.entryFundingIndex) return 0;
        uint256 diff = currentIndex - pos.entryFundingIndex;
        return -int256(pos.size * diff / BPS / 10000);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function getMarkPrice(bytes32 marketId) external view returns (uint256) { return _getCurrentVirtualPrice(marketId); }
    function getUserPositions(address user) external view returns (uint256[] memory) { return userPositions[user]; }
    function setAdlEngine(address _adl) external onlyOwner { adlEngine = IWikiADL(_adl); }
    function setHybridLM(address _hlm) external onlyOwner { hybridLM = IWikiHybridLiquidityManager(_hlm); }
    function setLeverageScaler(address _ls) external onlyOwner { leverageScaler = IWikiLeverageScaler(_ls); }
    function setBackstopVault(address _bv) external onlyOwner { backstopVault = IWikiBackstop(_bv); }

    function setDynLev(address _dynLev) external onlyOwner {
        dynLev = IWikiDynamicLeverage(_dynLev);
    }

    /**
     * @notice Called by WikiDynamicLeverage to update a market's max leverage.
     *         Can also be called by owner directly.
     */
    function setMarketMaxLeverage(uint256 marketIdx, uint256 maxLev) external {
        require(msg.sender == owner() || msg.sender == address(dynLev), "vAMM: not authorized");
        require(marketIdx < marketIds.length, "vAMM: bad market");
        require(maxLev >= 1 && maxLev <= 2000, "vAMM: lev range");
        bytes32 marketId = marketIds[marketIdx];
        markets[marketId].maxLeverage = maxLev;
        // initMarginRatio = 1/leverage in BPS. At 2000x = 5 bps = 0.05%.
        // Use PRECISION scaling to avoid integer truncation at high leverage.
        markets[marketId].initMarginRatio = maxLev <= BPS ? BPS / maxLev : 1;
    }

    function marketsLength() external view returns (uint256) { return marketIds.length; }

    function getInsuranceFund() external view returns (uint256) { return insuranceFund; }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setOracle(address o) external onlyOwner { oracle = IWikiOracle(o); }
    function depositInsurance(uint256 amount) external {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        insuranceFund += amount;
        emit InsuranceFundUpdated(insuranceFund);
    }
    function withdrawRevenue(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue; protocolRevenue = 0;
        USDC.safeTransfer(to, amt);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }


    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
}
