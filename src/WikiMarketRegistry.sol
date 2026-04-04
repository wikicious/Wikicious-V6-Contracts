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
    uint8 public constant SRC_DERIVED   = 3;

    struct Market {
        uint256 id;
        string  symbol;
        string  baseAsset;
        string  quoteAsset;
        uint8   category;
        uint8   oracleSource;
        address oracleFeed;
        bytes32 pythPriceId;
        uint256 baseMarketId;
        uint256 quoteMarketId;
        uint256 maxLeverageBps;
        uint256 maintenanceMarginBps;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
        uint256 maxOILong;
        uint256 maxOIShort;
        uint256 minPositionSize;
        uint256 maxPositionSize;
        uint256 spreadBps;
        uint256 offHoursSpreadBps;
        bool    active;
        bool    reduceOnly;
        uint256 pricePrecision;
    }

    /// @dev Input struct used by addMarket() and addMarkets().
    ///      Using a struct instead of 21 bare parameters keeps the
    ///      Yul stack depth inside the 16-slot EVM limit.
    struct MarketInput {
        string  symbol;
        string  base;
        string  quote;
        uint8   category;
        uint8   oracleSrc;
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

    mapping(uint256 => Market)  public markets;
    mapping(string  => uint256) public symbolToId;
    uint256[] public activeMarketIds;
    uint256   public totalMarkets;

    uint256 public constant MAX_BATCH_ADD = 50;

    event MarketAdded(uint256 indexed id, string symbol, uint8 category);
    event MarketUpdated(uint256 indexed id, string symbol);
    event MarketPaused(uint256 indexed id, string symbol);
    event MarketResumed(uint256 indexed id, string symbol);

    // â”€â”€ Chainlink feed addresses (Arbitrum Mainnet) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    address constant CL_BTC_USD   = 0x6ce185539aD4FDAbEb5E459F19E539FA48094C2a;
    address constant CL_ETH_USD   = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CL_ARB_USD   = 0xb2A824043730Fe05F3Da2EFAfa1CbBe83Fa548d4;
    address constant CL_SOL_USD   = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address constant CL_BNB_USD   = 0x6970460aabF80C5BE983C6b74e5D06dEDCA95D4A;
    address constant CL_AVAX_USD  = 0x8bf61728eeDCE2F32c456454d87B5d6eD6150208;
    address constant CL_LINK_USD  = 0x86e53cF1B873786AC51581d7288629498b4b2B52;
    address constant CL_MATIC_USD = 0x52099D4523531f678Dfc568a7B1e5038aadcE1d6;
    address constant CL_EUR_USD   = 0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84;
    address constant CL_GBP_USD   = 0x9C4424Fd84C6661F97D8d6b3fc3C1aAc2BeDd137;
    address constant CL_JPY_USD   = 0x3dD6e51CB9caE717d5a8778CF79A04029f9cFDF8;
    address constant CL_CHF_USD   = 0xe32AccC8c4eC03F6E75bd3621BfC9Fbb234E1FC3;
    address constant CL_CAD_USD   = 0xf6DA27749484843c4F02f5Ad1378ceE723dD61d4;
    address constant CL_AUD_USD   = 0x9854e9a850e7C354c1de177eA953a6b1fba8Fc22;
    address constant CL_NZD_USD   = 0x0F82d66499C33cabe7F8Ad4f9Dad0c95cA36bAE0;
    address constant CL_XAU_USD   = 0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c;
    address constant CL_XAG_USD   = 0xC56765f04B248394CF1619D20dB8082Edbfa75b1;

    constructor(address owner) Ownable(owner) {
        require(owner != address(0), "Wiki: zero owner");
        // Markets seeded post-deployment via addMarket() / addMarkets() batches.
    }

    // â”€â”€ Internal registration â€” takes a struct to avoid stack-too-deep â”€â”€â”€â”€â”€
    function _add(MarketInput memory inp) internal {
        uint256 id = ++totalMarkets;
        Market storage m = markets[id];
        m.id                  = id;
        m.symbol              = inp.symbol;
        m.baseAsset           = inp.base;
        m.quoteAsset          = inp.quote;
        m.category            = inp.category;
        m.oracleSource        = inp.oracleSrc;
        m.oracleFeed          = inp.feed;
        m.pythPriceId         = inp.pythId;
        m.baseMarketId        = inp.baseM;
        m.quoteMarketId       = inp.quoteM;
        m.maxLeverageBps      = inp.maxLev;
        m.maintenanceMarginBps= inp.maint;
        m.takerFeeBps         = inp.taker;
        m.makerFeeBps         = inp.maker;
        m.maxOILong           = inp.oiL;
        m.maxOIShort          = inp.oiS;
        m.minPositionSize     = inp.minP;
        m.maxPositionSize     = inp.maxP;
        m.spreadBps           = inp.spread;
        m.offHoursSpreadBps   = inp.offH;
        m.active              = true;
        m.reduceOnly          = false;
        m.pricePrecision      = inp.prec;
        symbolToId[inp.symbol] = id;
        activeMarketIds.push(id);
        emit MarketAdded(id, inp.symbol, inp.category);
    }

    // â”€â”€ Admin: add one market â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    function addMarket(MarketInput calldata inp) external onlyOwner {
        _add(inp);
    }

    // â”€â”€ Admin: add up to MAX_BATCH_ADD markets in one tx â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    function addMarkets(MarketInput[] calldata batch) external onlyOwner {
        require(batch.length > 0,             "Wiki: empty batch");
        require(batch.length <= MAX_BATCH_ADD,"Wiki: batch too large");
        for (uint256 i = 0; i < batch.length; i++) {
            _add(batch[i]);
        }
    }

    // â”€â”€ Views â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    function getMarket(uint256 id) external view returns (Market memory) {
        return markets[id];
    }
    function getMarketBySymbol(string calldata s) external view returns (Market memory) {
        return markets[symbolToId[s]];
    }
    function getAllMarkets() external view returns (uint256[] memory) {
        return activeMarketIds;
    }
    function getMarketsByCategory(uint8 category) external view returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = 0; i < activeMarketIds.length; i++)
            if (markets[activeMarketIds[i]].category == category) count++;
        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < activeMarketIds.length; i++)
            if (markets[activeMarketIds[i]].category == category) result[j++] = activeMarketIds[i];
        return result;
    }
    function maxLeverage(uint256 id) external view returns (uint256) {
        return markets[id].maxLeverageBps / 100;
    }
    function isActive(uint256 id) external view returns (bool) {
        return markets[id].active;
    }

    // â”€â”€ Admin: update market params â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
        markets[id].spreadBps        = spread;
        markets[id].offHoursSpreadBps = offH;
    }
    function updateOracle(uint256 id, uint8 src, address feed, bytes32 pythId) external onlyOwner {
        markets[id].oracleSource = src;
        markets[id].oracleFeed   = feed;
        markets[id].pythPriceId  = pythId;
    }
}
