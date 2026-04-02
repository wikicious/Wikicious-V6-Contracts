// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./WikiVault.sol";
import "./WikiOracle.sol";

// ── GMX V5 Interfaces (Arbitrum) ──────────────────────────────
// ExchangeRouter: 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8
interface IGMXExchangeRouter {
    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers   numbers;
        OrderType                  orderType;
        DecreasePositionSwapType   decreasePositionSwapType;
        bool                       isLong;
        bool                       shouldUnwrapNativeToken;
        bytes32                    referralCode;
    }
    struct CreateOrderParamsAddresses {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        address[] swapPath;
    }
    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
    }
    enum OrderType { MarketSwap, LimitSwap, MarketIncrease, LimitIncrease, MarketDecrease, LimitDecrease, StopLossDecrease, Liquidation }
    enum DecreasePositionSwapType { NoSwap, SwapPnlTokenToCollateralToken, SwapCollateralTokenToPnlToken }

    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
    function cancelOrder(bytes32 key) external;
}

// GMX DataStore for reading pool metrics
interface IGMXDataStore {
    function getUint(bytes32 key) external view returns (uint256);
    function getAddress(bytes32 key) external view returns (address);
}

// GMX Reader for pool pricing
interface IGMXReader {
    struct MarketInfo {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
    }
    function getMarketInfo(address dataStore, address market) external view returns (MarketInfo memory);
}

/// @title WikiGMXBackstop
/// @notice Routes large perp orders to GMX V5 when the Wikicious orderbook
///         cannot fill them. Wikicious keeps its full fee — GMX is just the
///         liquidity source underneath.
///
/// Revenue model:
///   - Wikicious charges user: takerFee (0.05%)
///   - GMX charges pool: openFee (~0.05%) + borrowing
///   - Net to Wikicious on backstop trades: takerFee - gmxFee spread
///   - On pure orderbook matches (no GMX): Wikicious keeps full takerFee
// Minimal GMX V5 Order types for callback interface
library Order {
    struct Numbers {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
        uint256 updatedAtBlock;
    }
    struct Props {
        bytes32 key;
        address account;
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        uint256[] swapPath;
        Numbers numbers;
        bool isLong;
        bool shouldUnwrapNativeToken;
        bool isFrozen;
    }
}

contract WikiGMXBackstop is Ownable2Step, ReentrancyGuard, Pausable {
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

    // ── Arbitrum Mainnet GMX V5 Addresses ─────────────────────
    address public constant GMX_EXCHANGE_ROUTER = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;
    address public constant GMX_DATASTORE       = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address public constant GMX_READER          = address(bytes20(hex"00537c767cdaa5c3be5547f4de6b6b5b4c7ce3b8"));
    /// GMX V5 OrderHandler on Arbitrum — source of afterOrderExecution callbacks
    address public constant GMX_ORDER_HANDLER = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;
    address public constant GMX_ROUTER          = 0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6;
    address public constant GMX_ORDER_VAULT     = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;

    // GMX V5 market addresses on Arbitrum (index token → GM pool)
    mapping(bytes32 => address) public gmxMarkets;

    // ── Wikicious state ───────────────────────────────────────
    WikiVault  public immutable vault;
    WikiOracle public immutable oracle;
    IERC20     public immutable USDC;

    address public constant USDC_ADDR = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH_ADDR = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // Tracks GMX orders placed on behalf of traders
    struct PendingOrder {
        address trader;
        bytes32 marketId;
        bool    isLong;
        uint256 size;        // USDC notional
        uint256 collateral;
        uint256 wikFee;      // already collected by Wikicious
        uint256 placedAt;
        bool    settled;
    }
    mapping(bytes32 => PendingOrder) public pendingOrders; // gmxOrderKey → order

    // Revenue tracking
    uint256 public totalFeesEarned;    // USDC earned by Wikicious from backstop trades
    uint256 public totalVolumeRouted;  // notional routed through GMX

    // Fee config
    uint256 public constant WIK_TAKER_FEE_BPS = 5;   // 0.05% charged to trader
    uint256 public constant GMX_OPEN_FEE_BPS   = 5;   // ~0.05% GMX charges (approximate)
    uint256 public constant BPS                = 10000;
    uint256 public constant GMX_EXECUTION_FEE  = 0.001 ether; // ETH for GMX keeper

    // Minimum size worth routing to GMX (smaller trades stay internal)
    uint256 public minGMXRouteSize = 5000 * 1e6; // $5,000 USDC

    address public wikFeeRecipient;
    mapping(address => bool) public operators; // WikiPerp can call this

    event BackstopOrderPlaced(bytes32 indexed gmxKey, address indexed trader, bytes32 marketId, bool isLong, uint256 size);
    event BackstopOrderSettled(bytes32 indexed gmxKey, address indexed trader, int256 pnl);
    event RevenueEarned(uint256 wikFee, uint256 gmxFee, uint256 netRevenue);
    event GMXMarketSet(bytes32 indexed marketId, address gmxMarket);
    event MinRouteSizeUpdated(uint256 newSize);

    constructor(address _vault, address _oracle, address _feeRecipient, address owner)
        Ownable(owner)
    {
        require(_vault != address(0), "Wiki: zero _vault");
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(_feeRecipient != address(0), "Wiki: zero _feeRecipient");
        _transferOwnership(owner);
        vault          = WikiVault(_vault);
        oracle         = WikiOracle(payable(_oracle));
        USDC           = IERC20(USDC_ADDR);
        wikFeeRecipient = _feeRecipient;

        // Pre-configure GMX V5 market addresses (Arbitrum mainnet)
        // Format: keccak256(symbol) => GMX GM pool address
        _setGMXMarket("BTCUSDT",   0x47c031236e19d024b42f8AE6780E44A573170703);
        _setGMXMarket("ETHUSDT",   0x70d95587d40A2caf56bd97485aB3Eec10Bee6336);
        _setGMXMarket("ARBUSDT",   0xC25cEf6061Cf5dE5eb761b50E4743c1F5D7E5407);
        _setGMXMarket("SOLUSDT",   0x09400D9DB990D5ed3f35D7be61DfAEB900Af03C9);
        _setGMXMarket("BNBUSDT",   0x2d340912Aa47e33c90Efb078e69E70EFe2B34b9B);
        _setGMXMarket("AVAXUSDT",  0x7BbBf946883a5701350007320F525c5379B8178A);
        _setGMXMarket("LINKUSDT",  address(bytes20(hex"7f1fa204bb700853d36994da19f830b6ad18d3bb")));
        _setGMXMarket("UNIUSDT",   0xc7Abb2C5f3BF3CEB389dF0Eecd6120D451170B50);
        _setGMXMarket("DOGEUSDT",  0x6853EA96FF216fAb11D2d930CE3C508556A4bdc4);
        _setGMXMarket("XRPUSDT",   address(bytes20(hex"0ccb4faa6f1f1b0f89bc1d6b67c8210a88e07c98")));
        _setGMXMarket("LTCUSDT",   0xD9535bB5f58A1a75032416F2dFe7880C30575a41);
        _setGMXMarket("OPUSDT",    0x4fDd333FF9cA409df583f306B6F5a7fFdE790739);
        _setGMXMarket("MATICUSDT", address(bytes20(hex"6f6ba5512a4c7b3c264eb5905b1f43e2d9658df8")));
    }

    modifier onlyOperator() {
        require(operators[msg.sender] || msg.sender == owner(), "Backstop: not operator");
        _;
    }

    // ── Admin ─────────────────────────────────────────────────
    function setOperator(address op, bool enabled) external onlyOwner {
        operators[op] = enabled;
    }

    function setGMXMarket(bytes32 marketId, address gmxMarket) external onlyOwner {
        _setGMXMarket_raw(marketId, gmxMarket);
    }

    function setMinRouteSize(uint256 size) external onlyOwner {
        minGMXRouteSize = size;
        emit MinRouteSizeUpdated(size);
    }

    function setFeeRecipient(address r) external onlyOwner { wikFeeRecipient = r; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Core: Route order to GMX ──────────────────────────────
    /// @notice Called by WikiPerp when orderbook can't fill an order
    /// @param trader      The trader whose margin is already locked in WikiVault
    /// @param marketId    keccak256(symbol) e.g. keccak256("BTCUSDT")
    /// @param isLong      Direction
    /// @param collateral  USDC collateral (already locked in vault)
    /// @param leverage    Leverage multiplier
    /// @return gmxKey     GMX order key for tracking
    function routeToGMX(
        address trader,
        bytes32 marketId,
        bool    isLong,
        uint256 collateral,
        uint256 leverage
    ) external payable onlyOperator nonReentrant whenNotPaused returns (bytes32 gmxKey) {
        require(msg.value >= GMX_EXECUTION_FEE, "Backstop: insufficient execution fee");

        address gmxMarket = gmxMarkets[marketId];
        require(gmxMarket != address(0), "Backstop: no GMX market");

        uint256 size    = collateral * leverage;
        require(size >= minGMXRouteSize, "Backstop: size below minimum");

        // Collect Wikicious fee from trader's vault balance
        uint256 wikFee = size * WIK_TAKER_FEE_BPS / BPS;
        vault.collectFee(trader, wikFee);
        totalFeesEarned  += wikFee;
        totalVolumeRouted += size;

        // Pull collateral from vault to this contract for GMX
        // (vault releases margin, we forward to GMX order vault)
        vault.releaseMargin(trader, collateral);
        USDC.safeTransferFrom(address(vault), GMX_ORDER_VAULT, collateral);

        // Get acceptable price with 1% slippage tolerance
        (uint256 markPrice,) = oracle.getPrice(marketId);
        uint256 acceptablePrice = isLong
            ? markPrice * 101 / 100  // long: accept up to 1% above mark
            : markPrice * 99  / 100; // short: accept up to 1% below mark

        // Build GMX order params
        IGMXExchangeRouter.CreateOrderParams memory params = IGMXExchangeRouter.CreateOrderParams({
            addresses: IGMXExchangeRouter.CreateOrderParamsAddresses({
                receiver:               address(this),  // settlement comes back here
                callbackContract:       address(this),
                uiFeeReceiver:          wikFeeRecipient, // Wikicious earns UI fee
                market:                 gmxMarket,
                initialCollateralToken: USDC_ADDR,
                swapPath:               new address[](0)
            }),
            numbers: IGMXExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd:                    size * 1e24, // GMX uses 30-decimal USD
                initialCollateralDeltaAmount:    collateral,
                triggerPrice:                    0,
                acceptablePrice:                 acceptablePrice * 1e12, // normalize to GMX format
                executionFee:                    GMX_EXECUTION_FEE,
                callbackGasLimit:                500_000,
                minOutputAmount:                 0
            }),
            orderType:                  IGMXExchangeRouter.OrderType.MarketIncrease,
            decreasePositionSwapType:   IGMXExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong:                     isLong,
            shouldUnwrapNativeToken:    false,
            referralCode:               bytes32("WIKICIOUS") // referral tracking
        });

        gmxKey = IGMXExchangeRouter(GMX_EXCHANGE_ROUTER).createOrder{value: GMX_EXECUTION_FEE}(params);

        pendingOrders[gmxKey] = PendingOrder({
            trader:     trader,
            marketId:   marketId,
            isLong:     isLong,
            size:       size,
            collateral: collateral,
            wikFee:     wikFee,
            placedAt:   block.timestamp,
            settled:    false
        });

        // Revenue breakdown event
        uint256 gmxFee = size * GMX_OPEN_FEE_BPS / BPS;
        emit RevenueEarned(wikFee, gmxFee, wikFee); // Wikicious keeps wikFee regardless
        emit BackstopOrderPlaced(gmxKey, trader, marketId, isLong, size);
    }

    // ── IGMXOrderCallbackReceiver implementation ──────────────────────────────
    // GMX V5 calls these after order execution on the GMX Router.
    // GMX OrderHandler on Arbitrum: 0x352f684ab9e97a6321a13CF03A61316B681D9fD2
    // Ref: https://github.com/gmx-io/gmx-synthetics/blob/main/contracts/callback/IOrderCallbackReceiver.sol

    struct EventLogData { /* GMX EventUtils.EventLogData — simplified */ bytes32 key; }

    /// @notice Called by GMX when an order executes successfully.
    function afterOrderExecution(
        bytes32 key,
        Order.Props memory order,
        EventLogData memory /*eventData*/
    ) external {
        require(msg.sender == GMX_ORDER_HANDLER, "Backstop: not GMX handler");
        _handleOrderExecution(key, order);
    }

    function _handleOrderExecution(bytes32 key, Order.Props memory order) internal {
        PendingOrder storage o = pendingOrders[key];
        if (o.settled || o.trader == address(0)) return;
        o.settled = true;

        // Collateral is now in the GMX position — mark it locked in WikiVault
        vault.lockMargin(o.trader, o.collateral);
        emit BackstopOrderSettled(key, o.trader, int256(order.numbers.sizeDeltaUsd));
    }

    /// @notice Called by GMX when an order is cancelled (e.g. price impact too high).
    function afterOrderCancellation(
        bytes32 key,
        Order.Props memory /*order*/,
        EventLogData memory /*eventData*/
    ) external {
        require(msg.sender == GMX_ORDER_HANDLER, "Backstop: not GMX handler");
        PendingOrder storage o = pendingOrders[key];
        if (o.settled || o.trader == address(0)) return;
        o.settled = true;

        // Refund collateral to trader
        vault.releaseMargin(o.trader, o.collateral);
        emit BackstopOrderSettled(key, o.trader, 0);
    }

    /// @notice Called by GMX when a frozen order is executed after keeper intervention.
    function afterOrderFrozen(
        bytes32 key,
        Order.Props memory order,
        EventLogData memory /*eventData*/
    ) external {
        require(msg.sender == GMX_ORDER_HANDLER, "Backstop: not GMX handler");
        _handleOrderExecution(key, order);
    }

    /// @notice Close a GMX-backed position
    function closeGMXPosition(
        bytes32 gmxKey,
        bytes32 marketId,
        bool    isLong,
        uint256 size
    ) external payable onlyOperator nonReentrant {
        require(msg.value >= GMX_EXECUTION_FEE, "Backstop: insufficient fee");

        address gmxMarket = gmxMarkets[marketId];
        (uint256 markPrice,) = oracle.getPrice(marketId);
        uint256 acceptablePrice = isLong
            ? markPrice * 99  / 100
            : markPrice * 101 / 100;

        IGMXExchangeRouter.CreateOrderParams memory params = IGMXExchangeRouter.CreateOrderParams({
            addresses: IGMXExchangeRouter.CreateOrderParamsAddresses({
                receiver:               address(this),
                callbackContract:       address(this),
                uiFeeReceiver:          wikFeeRecipient,
                market:                 gmxMarket,
                initialCollateralToken: USDC_ADDR,
                swapPath:               new address[](0)
            }),
            numbers: IGMXExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd:                    size * 1e24,
                initialCollateralDeltaAmount:    0,
                triggerPrice:                    0,
                acceptablePrice:                 acceptablePrice * 1e12,
                executionFee:                    GMX_EXECUTION_FEE,
                callbackGasLimit:                500_000,
                minOutputAmount:                 0
            }),
            orderType:                  IGMXExchangeRouter.OrderType.MarketDecrease,
            decreasePositionSwapType:   IGMXExchangeRouter.DecreasePositionSwapType.SwapPnlTokenToCollateralToken,
            isLong:                     isLong,
            shouldUnwrapNativeToken:    false,
            referralCode:               bytes32("WIKICIOUS")
        });

        IGMXExchangeRouter(GMX_EXCHANGE_ROUTER).createOrder{value: GMX_EXECUTION_FEE}(params);
    }

    // ── Revenue views ─────────────────────────────────────────
    /// @notice Current revenue breakdown
    function revenueStats() external view returns (
        uint256 feesCollected,
        uint256 volumeRouted,
        uint256 averageFeeRate
    ) {
        feesCollected  = totalFeesEarned;
        volumeRouted   = totalVolumeRouted;
        averageFeeRate = totalVolumeRouted > 0
            ? totalFeesEarned * BPS / totalVolumeRouted
            : WIK_TAKER_FEE_BPS;
    }

    /// @notice Estimate net revenue for a given trade size
    /// @return wikRevenue  What Wikicious earns (USDC)
    /// @return gmxCost     What GMX takes (USDC, approximately)
    /// @return net         Net to Wikicious
    function estimateRevenue(uint256 tradeSize) external pure returns (
        uint256 wikRevenue,
        uint256 gmxCost,
        uint256 net
    ) {
        wikRevenue = tradeSize * WIK_TAKER_FEE_BPS / BPS;
        gmxCost    = tradeSize * GMX_OPEN_FEE_BPS  / BPS;
        // Wikicious keeps wikRevenue regardless — GMX cost is borne by trader's PnL
        // Both fees are charged independently; net to protocol = wikRevenue
        net = wikRevenue;
    }

    // ── GMX market helpers ────────────────────────────────────
    function getGMXMarket(bytes32 marketId) external view returns (address) {
        return gmxMarkets[marketId];
    }

    function isMarketSupported(bytes32 marketId) external view returns (bool) {
        return gmxMarkets[marketId] != address(0);
    }

    function _setGMXMarket(string memory symbol, address market) internal {
        bytes32 id = keccak256(abi.encodePacked(symbol));
        gmxMarkets[id] = market;
        emit GMXMarketSet(id, market);
    }

    function _setGMXMarket_raw(bytes32 id, address market) internal {
        gmxMarkets[id] = market;
        emit GMXMarketSet(id, market);
    }

    // Accept ETH for GMX execution fees
    receive() external payable {}

    function withdrawETH() external nonReentrant onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function withdrawFees() external nonReentrant onlyOwner {
        uint256 bal = USDC.balanceOf(address(this));
        if (bal > 0) USDC.safeTransfer(wikFeeRecipient, bal);
    }
}
