// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title WikiMarketRegistry â€” Single source of truth for all tradeable markets
///
/// MARKET CATEGORIES:
///   0 = CRYPTO      â€” 24/7, up to 125x
///   1 = FOREX_MAJOR â€” Mon 00:00 â€“ Fri 21:00 UTC, up to 50x
///   2 = FOREX_MINOR â€” same hours, up to 30x
///   3 = FOREX_EXOTICâ€” same hours, up to 20x
///   4 = METALS      â€” Mon 00:00 â€“ Fri 21:00 UTC (23h break Fri-Sun), up to 100x (gold), 50x (others)
///   5 = COMMODITIES â€” exchange hours, up to 20x
///
/// ORACLE PRIORITY (per market):
///   Source 0 = Chainlink (most trusted, ~40 pairs)
///   Source 1 = Pyth Network (~80 pairs, push-based)
///   Source 2 = Guardian   (custom, for remaining exotics)
///   Source 3 = Derived    (calculated from two other feeds, e.g. EUR/GBP)

contract WikiMarketRegistry is Ownable2Step {

    uint8 public constant CAT_CRYPTO       = 0;
    uint8 public constant CAT_FOREX_MAJOR  = 1;
    uint8 public constant CAT_FOREX_MINOR  = 2;
    uint8 public constant CAT_FOREX_EXOTIC = 3;
    uint8 public constant CAT_METALS       = 4;
    uint8 public constant CAT_COMMODITIES  = 5;

    uint8 public constant SRC_CHAINLINK = 0;
    uint8 public constant SRC_PYTH      = 1;
    uint8 public constant SRC_GUARDIAN  = 2;
    uint8 public constant SRC_DERIVED   = 3; // price = baseMarket / quoteMarket

    struct Market {
        uint256 id;
        string  symbol;          // e.g. "EUR/USD", "XAU/USD", "BTC/USD"
        string  baseAsset;       // e.g. "EUR", "XAU", "BTC"
        string  quoteAsset;      // always "USD" for direct pairs
        uint8   category;
        uint8   oracleSource;
        address oracleFeed;      // Chainlink feed address (or address(0) if Pyth/Guardian)
        bytes32 pythPriceId;     // Pyth price ID (bytes32(0) if not Pyth)
        uint256 baseMarketId;    // for derived pairs: numerator market
        uint256 quoteMarketId;   // for derived pairs: denominator market
        uint256 maxLeverageBps;  // e.g. 5000 = 50x (bps of 100)
        uint256 maintenanceMarginBps; // e.g. 50 = 0.5%
        uint256 takerFeeBps;     // e.g. 5 = 0.05%  (crypto), 2 = 0.02% (forex)
        uint256 makerFeeBps;
        uint256 maxOILong;       // max open interest long (USDC, 6 dec)
        uint256 maxOIShort;
        uint256 minPositionSize; // USDC
        uint256 maxPositionSize; // USDC
        uint256 spreadBps;       // base spread (wider for exotics)
        uint256 offHoursSpreadBps; // spread when market is "soft closed"
        bool    active;
        bool    reduceOnly;      // true = only closing trades allowed (circuit breaker)
        uint256 pricePrecision;  // decimal places for display
    }

    mapping(uint256 => Market) public markets;
    mapping(string  => uint256) public symbolToId;
    uint256[] public activeMarketIds;
    uint256 public totalMarkets;

    event MarketAdded(uint256 indexed id, string symbol, uint8 category);
    event MarketUpdated(uint256 indexed id, string symbol);
    event MarketPaused(uint256 indexed id, string symbol);
    event MarketResumed(uint256 indexed id, string symbol);

    // â”€â”€ Chainlink feed addresses (Arbitrum Mainnet) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Crypto
    address constant CL_BTC_USD  = 0x6ce185539aD4FDAbEb5E459F19E539FA48094C2a; // Arbitrum BTC/USD âœ…
    address constant CL_ETH_USD  = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CL_ARB_USD  = 0xb2A824043730Fe05F3Da2EFAfa1CbBe83Fa548d4;
    address constant CL_SOL_USD  = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address constant CL_BNB_USD  = 0x6970460aabF80C5BE983C6b74e5D06dEDCA95D4A;
    address constant CL_AVAX_USD = 0x8bf61728eeDCE2F32c456454d87B5d6eD6150208;
    address constant CL_LINK_USD = 0x86e53cF1B873786AC51581d7288629498b4b2B52;
    address constant CL_MATIC_USD= 0x52099D4523531f678Dfc568a7B1e5038aadcE1d6;
    address constant CL_DOGE_USD = 0x9A7FB1b3950837a8D9b40517626E11D4127C098C;
    // Forex majors
    address constant CL_EUR_USD  = 0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84;
    address constant CL_GBP_USD  = 0x9C4424Fd84C6661F97D8d6b3fc3C1aAc2BeDd137;
    address constant CL_JPY_USD  = 0x3dD6e51CB9caE717d5a8778CF79A04029f9cFDF8;
    address constant CL_CHF_USD  = 0xe32AccC8c4eC03F6E75bd3621BfC9Fbb234E1FC3;
    address constant CL_CAD_USD  = 0xf6DA27749484843c4F02f5Ad1378ceE723dD61d4;
    address constant CL_AUD_USD  = 0x9854e9a850e7C354c1de177eA953a6b1fba8Fc22;
    address constant CL_NZD_USD  = 0x0F82d66499C33cabe7F8Ad4f9Dad0c95cA36bAE0;
    // Metals
    address constant CL_XAU_USD  = 0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c;
    address constant CL_XAG_USD  = 0xC56765f04B248394CF1619D20dB8082Edbfa75b1; // Arbitrum XAG/USD âœ…

    constructor(address owner) Ownable(owner) {
        require(owner != address(0), "Wiki: zero owner");
        // Market list is now seeded post-deployment via addMarket() batches
        // to avoid constructor initcode-size deployment limits.
    }

// â”€â”€ Internal market registration â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    function _add(
        string memory symbol, string memory base, string memory quote,
        uint8 category, uint8 oracleSrc, address feed, bytes32 pythId,
        uint256 baseMarket, uint256 quoteMarket,
        uint256 maxLev, uint256 maintMargin,
        uint256 takerFee, uint256 makerFee,
        uint256 maxOIL, uint256 maxOIS,
        uint256 minPos, uint256 maxPos,
        uint256 spread, uint256 offHoursSpread,
        uint256 pricePrecision
    ) internal {
        uint256 id = ++totalMarkets;
        Market storage m = markets[id];

        m.id = id;
        m.symbol = symbol;
        m.baseAsset = base;
        m.quoteAsset = quote;
        m.category = category;
        m.oracleSource = oracleSrc;
        m.oracleFeed = feed;
        m.pythPriceId = pythId;
        m.baseMarketId = baseMarket;
        m.quoteMarketId = quoteMarket;
        m.maxLeverageBps = maxLev;
        m.maintenanceMarginBps = maintMargin;
        m.takerFeeBps = takerFee;
        m.makerFeeBps = makerFee;
        m.maxOILong = maxOIL;
        m.maxOIShort = maxOIS;
        m.minPositionSize = minPos;
        m.maxPositionSize = maxPos;
        m.spreadBps = spread;
        m.offHoursSpreadBps = offHoursSpread;
        m.active = true;
        m.reduceOnly = false;
        m.pricePrecision = pricePrecision;

        symbolToId[symbol] = id;
        activeMarketIds.push(id);
        emit MarketAdded(id, symbol, category);
    }

    // â”€â”€ Views â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    function getMarket(uint256 id) external view returns (Market memory) { return markets[id]; }
    function getMarketBySymbol(string calldata s) external view returns (Market memory) { return markets[symbolToId[s]]; }
    function getAllMarkets() external view returns (uint256[] memory) { return activeMarketIds; }

    function getMarketsByCategory(uint8 category) external view returns (uint256[] memory) {
        uint256 count;
        for (uint i = 0; i < activeMarketIds.length; i++)
            if (markets[activeMarketIds[i]].category == category) count++;
        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint i = 0; i < activeMarketIds.length; i++)
            if (markets[activeMarketIds[i]].category == category) result[j++] = activeMarketIds[i];
        return result;
    }

    function maxLeverage(uint256 id) external view returns (uint256) { return markets[id].maxLeverageBps / 100; }
    function isActive(uint256 id) external view returns (bool) { return markets[id].active; }
    
        struct MarketInput {
        string symbol;
        string base;
        string quote;
        uint8 category;
        uint8 oracleSrc;
        address feed;
        bytes32 pythId;
        uint256 baseM;
        uint256 quoteM;
        uint256 maxLev;
        uint256 maint;
        uint256 taker;
        uint256 maker;
        uint256 oiL;
        uint256 oiS;
        uint256 minP;
        uint256 maxP;
        uint256 spread;
        uint256 offH;
        uint256 prec;
    }

    uint256 public constant MAX_BATCH_ADD = 50;

    // â”€â”€ Admin â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    function addMarket(
        string calldata symbol, string calldata base, string calldata quote,
        uint8 category, uint8 oracleSrc, address feed, bytes32 pythId,
        uint256 baseM, uint256 quoteM, uint256 maxLev, uint256 maint,
        uint256 taker, uint256 maker, uint256 oiL, uint256 oiS,
        uint256 minP, uint256 maxP, uint256 spread, uint256 offH, uint256 prec
    ) external onlyOwner {
        _add(symbol, base, quote, category, oracleSrc, feed, pythId, baseM, quoteM, maxLev, maint, taker, maker, oiL, oiS, minP, maxP, spread, offH, prec);
    }

    function addMarkets(MarketInput[] calldata batch) external onlyOwner {
        require(batch.length > 0, "Wiki: empty batch");
        require(batch.length <= MAX_BATCH_ADD, "Wiki: batch too large");

        for (uint256 i = 0; i < batch.length; i++) {
            _addFromInput(batch[i]);
        }
    }

    function _addFromInput(MarketInput calldata m) internal {
        _add(
            m.symbol,
            m.base,
            m.quote,
            m.category,
            m.oracleSrc,
            m.feed,
            m.pythId,
            m.baseM,
            m.quoteM,
            m.maxLev,
            m.maint,
            m.taker,
            m.maker,
            m.oiL,
            m.oiS,
            m.minP,
            m.maxP,
            m.spread,
            m.offH,
            m.prec
        );
    }
    function pauseMarket(uint256 id) external onlyOwner {
        markets[id].reduceOnly = true;
        emit MarketPaused(id, markets[id].symbol);
    }

    function resumeMarket(uint256 id) external onlyOwner {
        markets[id].reduceOnly = false;
        emit MarketResumed(id, markets[id].symbol);
    }

    function deactivateMarket(uint256 id) external onlyOwner {
        markets[id].active = false;
    }

    function updateOILimits(uint256 id, uint256 maxL, uint256 maxS) external onlyOwner {
        markets[id].maxOILong  = maxL;
        markets[id].maxOIShort = maxS;
    }

    function updateFees(uint256 id, uint256 taker, uint256 maker) external onlyOwner {
        markets[id].takerFeeBps = taker;
        markets[id].makerFeeBps = maker;
    }

    function updateSpread(uint256 id, uint256 spread, uint256 offH) external onlyOwner {
        markets[id].spreadBps         = spread;
        markets[id].offHoursSpreadBps = offH;
    }

    function updateOracle(uint256 id, uint8 src, address feed, bytes32 pythId) external onlyOwner {
        markets[id].oracleSource = src;
        markets[id].oracleFeed   = feed;
        markets[id].pythPriceId  = pythId;
    }
}
