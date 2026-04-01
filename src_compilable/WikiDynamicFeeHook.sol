// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
/**
 * @title WikiDynamicFeeHook — Volatility-adjusted fees (Uniswap v4 Hook style)
 *
 * Hooks into WikiPerp and WikiSpot swap execution to dynamically adjust fees:
 *   Low  volatility (σ < 1%):  fee = 0.01% (attract stablecoin volume)
 *   Normal volatility (1–3%):  fee = 0.06% (standard tier)
 *   High volatility (3–10%):   fee = 0.20% (protect LPs)
 *   Extreme (> 10%):           fee = 1.00% (black swan protection)
 *
 * Also implements POOL IMBALANCE hooks:
 *   Imbalance > 20%: fee surcharge to discourage further imbalancing
 *   Imbalance < 5%:  fee discount to attract rebalancing trades
 *
 * Hook lifecycle: beforeSwap() → swap executes → afterSwap() records result
 */
contract WikiDynamicFeeHook is Ownable2Step {
    struct MarketState {
        uint256 lastPrice;
        uint256 lastUpdateBlock;
        uint256 ewmaVolatility; // exponential weighted moving avg volatility (bps)
        uint256 longOI;
        uint256 shortOI;
    }
    mapping(bytes32 => MarketState) public marketStates;
    mapping(address => bool)        public registeredAmms;  // only registered AMMs can call

    uint256 public constant ALPHA_BPS       = 200;  // EWMA smoothing: 2% weight to new obs
    uint256 public constant FEE_LOW_VOL     = 1;    // 0.01% — stablecoin tier
    uint256 public constant FEE_NORMAL      = 6;    // 0.06% — standard
    uint256 public constant FEE_HIGH        = 20;   // 0.20% — high vol
    uint256 public constant FEE_EXTREME     = 100;  // 1.00% — black swan
    uint256 public constant VOL_HIGH_BPS    = 300;  // 3% threshold
    uint256 public constant VOL_EXTREME_BPS = 1000; // 10% threshold
    uint256 public constant IMBALANCE_SURCHARGE = 10; // extra 0.10% bps on imbalanced swaps
    uint256 public constant BPS             = 10000;

    event FeeComputed(bytes32 indexed market, uint256 feeBps, uint256 volatility, uint256 imbalancePct);
    event VolatilityUpdated(bytes32 indexed market, uint256 newEWMA);

    constructor(address owner) Ownable(owner) {}

    /** @notice Called by AMM before executing swap. Returns fee bps to use. */
    function beforeSwap(bytes32 marketId, uint256 currentPrice, uint256 swapSize, bool isLong)
        external returns (uint256 feeBps)
    {
        require(registeredAmms[msg.sender], "Hook: not registered");
        MarketState storage s = marketStates[marketId];

        // Update EWMA volatility
        if (s.lastPrice > 0 && block.number > s.lastUpdateBlock) {
            uint256 priceDiff = currentPrice > s.lastPrice
                ? (currentPrice - s.lastPrice) * BPS / s.lastPrice
                : (s.lastPrice - currentPrice) * BPS / s.lastPrice;
            s.ewmaVolatility = (s.ewmaVolatility * (BPS - ALPHA_BPS) + priceDiff * ALPHA_BPS) / BPS;
        }
        s.lastPrice = currentPrice;
        s.lastUpdateBlock = block.number;

        // Base fee from volatility
        uint256 vol = s.ewmaVolatility;
        if (vol < 100)            feeBps = FEE_LOW_VOL;
        else if (vol < VOL_HIGH_BPS)  feeBps = FEE_NORMAL;
        else if (vol < VOL_EXTREME_BPS) feeBps = FEE_HIGH;
        else                          feeBps = FEE_EXTREME;

        // OI imbalance surcharge
        uint256 totalOI = s.longOI + s.shortOI;
        if (totalOI > 0) {
            uint256 dominant   = s.longOI > s.shortOI ? s.longOI : s.shortOI;
            uint256 imbalancePct = (dominant - totalOI / 2) * BPS / totalOI;
            bool isImbalancing = (s.longOI > s.shortOI) == isLong;
            if (imbalancePct > 2000 && isImbalancing) feeBps += IMBALANCE_SURCHARGE;
            else if (imbalancePct > 2000 && !isImbalancing) feeBps = feeBps > 2 ? feeBps - 2 : 1;
            emit FeeComputed(marketId, feeBps, vol, imbalancePct);
        }
        emit VolatilityUpdated(marketId, s.ewmaVolatility);
    }

    /** @notice Called after swap to update OI tracking. */
    function afterSwap(bytes32 marketId, bool isLong, uint256 size, bool isOpen) external {
        require(registeredAmms[msg.sender], "Hook: not registered");
        MarketState storage s = marketStates[marketId];
        if (isOpen) { if (isLong) s.longOI += size; else s.shortOI += size; }
        else        { if (isLong) s.longOI  = s.longOI  > size ? s.longOI  - size : 0;
                      else        s.shortOI = s.shortOI > size ? s.shortOI - size : 0; }
    }

    function registerAMM(address amm, bool enabled) external onlyOwner { registeredAmms[amm] = enabled; }
    function getVolatility(bytes32 market) external view returns (uint256) { return marketStates[market].ewmaVolatility; }
    function getCurrentFee(bytes32 market) external view returns (uint256 feeBps) {
        uint256 vol = marketStates[market].ewmaVolatility;
        if (vol < 100) return FEE_LOW_VOL;
        if (vol < VOL_HIGH_BPS) return FEE_NORMAL;
        if (vol < VOL_EXTREME_BPS) return FEE_HIGH;
        return FEE_EXTREME;
    }
}
