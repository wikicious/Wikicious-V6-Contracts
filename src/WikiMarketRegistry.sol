// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title WikiMarketRegistry — Single source of truth for all tradeable markets
///
/// MARKET CATEGORIES:
///   0 = CRYPTO      — 24/7, up to 125x
///   1 = FOREX_MAJOR — Mon 00:00 – Fri 21:00 UTC, up to 50x
///   2 = FOREX_MINOR — same hours, up to 30x
///   3 = FOREX_EXOTIC— same hours, up to 20x
///   4 = METALS      — Mon 00:00 – Fri 21:00 UTC (23h break Fri-Sun), up to 100x (gold), 50x (others)
///   5 = COMMODITIES — exchange hours, up to 20x
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

    // ── Chainlink feed addresses (Arbitrum Mainnet) ────────────────────────
    // Crypto
    address constant CL_BTC_USD  = 0x6ce185539ad4fdAbeb5E459f19E539fa48094C2a; // Arbitrum BTC/USD ✅
    address constant CL_ETH_USD  = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CL_ARB_USD  = 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D4;
    address constant CL_SOL_USD  = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address constant CL_BNB_USD  = 0x6970460aabF80C5BE983C6b74e5D06dEDCA95D4A;
    address constant CL_AVAX_USD = 0x8bf61728eeDCE2F32c456454d87B5d6eD6150208;
    address constant CL_LINK_USD = 0x86E53CF1B873786aC51581d7288629498b4b2b52;
    address constant CL_MATIC_USD= 0x52099D4523531f678Dfc568a7B1e5038aadcE1d6;
    address constant CL_DOGE_USD = 0x9A7FB1b3950837a8D9b40517626E11D4127C098C;
    // Forex majors
    address constant CL_EUR_USD  = 0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84;
    address constant CL_GBP_USD  = 0x9C4424Fd84C6661F97D8d6b3fc3C1aAc2BeDd137;
    address constant CL_JPY_USD  = 0x3dD6e51CB9caE717d5a8778CF79A04029f9cFDF8;
    address constant CL_CHF_USD  = 0xe32AccC8c4eC03F6E75bd3621BfC9Fbb234E1FC3;
    address constant CL_CAD_USD  = 0xf6DA27749484843c4F02f5Ad1378ceE723dD61d4;
    address constant CL_AUD_USD  = 0x9854e9a850e7C354c1de177eA953a6b1fba8Fc22;
    address constant CL_NZD_USD  = 0x0f82d66499C33cAbE7F8aD4F9dAD0c95ca36BaE0;
    // Metals
    address constant CL_XAU_USD  = 0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c;
    address constant CL_XAG_USD  = 0xC56765f04B248394CF1619D20dB8082Edbfa75b1; // Arbitrum XAG/USD ✅

    constructor(address owner) Ownable(owner) {
        require(owner != address(0), "Wiki: zero owner");
        _registerAllMarkets();
    }

    // ── Register all markets on deploy ─────────────────────────────────────
    function _registerAllMarkets() internal {
        // ── CRYPTO ────────────────────────────────────────────────────────
        _add("BTC/USD",  "BTC", "USD", CAT_CRYPTO, SRC_CHAINLINK, 0x6ce185539ad4fdAbeb5E459f19E539fa48094C2a, bytes32(0), 0, 0, 12500, 50,  5, 2, 50_000_000e6, 50_000_000e6, 10e6,  10_000_000e6, 2, 10, 2);
        _add("ETH/USD",  "ETH", "USD", CAT_CRYPTO, SRC_CHAINLINK, CL_ETH_USD,  bytes32(0), 0, 0, 12500, 50,  5, 2, 30_000_000e6, 30_000_000e6, 10e6,  5_000_000e6,  2, 10, 2);
        _add("SOL/USD",  "SOL", "USD", CAT_CRYPTO, SRC_CHAINLINK, CL_SOL_USD,  bytes32(0), 0, 0, 12500, 100, 5, 2, 10_000_000e6, 10_000_000e6, 10e6,  1_000_000e6,  2, 10, 2);
        _add("ARB/USD",  "ARB", "USD", CAT_CRYPTO, SRC_CHAINLINK, CL_ARB_USD,  bytes32(0), 0, 0, 12500, 100, 6, 3, 5_000_000e6,  5_000_000e6,  10e6,  500_000e6,   2, 10, 4);
        _add("BNB/USD",  "BNB", "USD", CAT_CRYPTO, SRC_CHAINLINK, CL_BNB_USD,  bytes32(0), 0, 0, 12500, 100, 5, 2, 10_000_000e6, 10_000_000e6, 10e6,  1_000_000e6,  2, 10, 2);
        _add("AVAX/USD", "AVAX","USD", CAT_CRYPTO, SRC_CHAINLINK, CL_AVAX_USD, bytes32(0), 0, 0, 12500, 100, 6, 3, 5_000_000e6,  5_000_000e6,  10e6,  500_000e6,   2, 10, 2);
        _add("LINK/USD", "LINK","USD", CAT_CRYPTO, SRC_CHAINLINK, CL_LINK_USD, bytes32(0), 0, 0, 12500, 100, 6, 3, 5_000_000e6,  5_000_000e6,  10e6,  500_000e6,   2, 10, 4);
        _add("MATIC/USD","MATIC","USD",CAT_CRYPTO, SRC_CHAINLINK, CL_MATIC_USD,bytes32(0), 0, 0, 12500, 100, 6, 3, 3_000_000e6,  3_000_000e6,  10e6,  300_000e6,   2, 10, 4);
        _add("DOGE/USD", "DOGE","USD", CAT_CRYPTO, SRC_PYTH,      address(0),  0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 0, 0, 7500, 150, 8, 4, 3_000_000e6, 3_000_000e6, 10e6, 300_000e6, 3, 15, 5);
        _add("PEPE/USD", "PEPE","USD", CAT_CRYPTO, SRC_PYTH,      address(0),  0xd69731a2e74ac1ce884fc3890f7ee324b6deb66147055249568869ed700882e4, 0, 0, 5000, 200, 10,5, 1_000_000e6, 1_000_000e6, 10e6, 100_000e6,  4, 20, 8);
        _add("WIF/USD",  "WIF", "USD", CAT_CRYPTO, SRC_PYTH,      address(0),  0x4ca4beeca86f0d164160323817a4e42b10010a724c2217c6ee41b54cd4cc61fc, 0, 0, 5000, 200, 10,5, 500_000e6,  500_000e6,  10e6, 50_000e6,   4, 20, 4);
        _add("WIK/USD",  "WIK", "USD", CAT_CRYPTO, SRC_GUARDIAN,  address(0),  bytes32(0), 0, 0, 5000, 200, 8, 4, 500_000e6,  500_000e6,  10e6, 50_000e6,   3, 15, 4);

        // ── FOREX MAJORS ──────────────────────────────────────────────────
        _add("EUR/USD","EUR","USD",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_EUR_USD, bytes32(0),0,0,5000,20,2,1,100_000_000e6,100_000_000e6,100e6,10_000_000e6,1,5,5);
        _add("GBP/USD","GBP","USD",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_GBP_USD, bytes32(0),0,0,5000,20,2,1,100_000_000e6,100_000_000e6,100e6,10_000_000e6,1,5,5);
        _add("USD/JPY","USD","JPY",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_JPY_USD, bytes32(0),0,0,5000,20,2,1,100_000_000e6,100_000_000e6,100e6,10_000_000e6,1,5,3);
        _add("USD/CHF","USD","CHF",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_CHF_USD, bytes32(0),0,0,5000,20,2,1,50_000_000e6, 50_000_000e6, 100e6,5_000_000e6, 1,5,5);
        _add("USD/CAD","USD","CAD",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_CAD_USD, bytes32(0),0,0,5000,20,2,1,50_000_000e6, 50_000_000e6, 100e6,5_000_000e6, 1,5,5);
        _add("AUD/USD","AUD","USD",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_AUD_USD, bytes32(0),0,0,5000,20,2,1,50_000_000e6, 50_000_000e6, 100e6,5_000_000e6, 1,5,5);
        _add("NZD/USD","NZD","USD",CAT_FOREX_MAJOR,SRC_CHAINLINK,CL_NZD_USD, bytes32(0),0,0,5000,20,2,1,30_000_000e6, 30_000_000e6, 100e6,3_000_000e6, 1,5,5);

        // ── FOREX MINORS (derived cross pairs) ────────────────────────────
        // EUR/GBP = EUR/USD ÷ GBP/USD  (market IDs 14 ÷ 15, 1-indexed)
        _add("EUR/GBP","EUR","GBP",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),14,15,3000,30,3,1,30_000_000e6,30_000_000e6,100e6,3_000_000e6,2,8,5);
        _add("EUR/JPY","EUR","JPY",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),14,16,3000,30,3,1,30_000_000e6,30_000_000e6,100e6,3_000_000e6,2,8,3);
        _add("GBP/JPY","GBP","JPY",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),15,16,3000,30,3,1,20_000_000e6,20_000_000e6,100e6,2_000_000e6,2,8,3);
        _add("EUR/CHF","EUR","CHF",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),14,17,3000,30,3,1,20_000_000e6,20_000_000e6,100e6,2_000_000e6,2,8,5);
        _add("EUR/CAD","EUR","CAD",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),14,18,3000,30,3,1,20_000_000e6,20_000_000e6,100e6,2_000_000e6,2,8,5);
        _add("GBP/CHF","GBP","CHF",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),15,17,3000,30,3,1,20_000_000e6,20_000_000e6,100e6,2_000_000e6,2,8,5);
        _add("GBP/CAD","GBP","CAD",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),15,18,3000,30,3,1,20_000_000e6,20_000_000e6,100e6,2_000_000e6,2,8,5);
        _add("AUD/JPY","AUD","JPY",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),19,16,3000,30,3,1,20_000_000e6,20_000_000e6,100e6,2_000_000e6,2,8,3);
        _add("AUD/CAD","AUD","CAD",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),19,18,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,5);
        _add("AUD/NZD","AUD","NZD",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),19,20,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,5);
        _add("CAD/JPY","CAD","JPY",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),18,16,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,3);
        _add("CHF/JPY","CHF","JPY",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),17,16,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,3);
        _add("NZD/JPY","NZD","JPY",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),20,16,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,3);
        _add("NZD/CAD","NZD","CAD",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),20,18,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,5);
        _add("NZD/CHF","NZD","CHF",CAT_FOREX_MINOR,SRC_DERIVED,address(0),bytes32(0),20,17,3000,30,3,1,10_000_000e6,10_000_000e6,100e6,1_000_000e6,2,8,5);

        // ── FOREX EXOTICS (Pyth + Guardian) ──────────────────────────────
        // USD/TRY — Turkish Lira
        _add("USD/TRY","USD","TRY",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0xb7a8eba68a997cd0210c2e1e4ee811ad2d174b3611c22d9ebf16f4cb7e9ba850,0,0,2000,50,8,4,5_000_000e6,5_000_000e6,100e6,500_000e6,5,25,3);
        // USD/ZAR — South African Rand
        _add("USD/ZAR","USD","ZAR",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0x389d889017db82bf42141f23b61b8de938a4e2d156e7460f2ca5b306ca997df,0,0,2000,50,8,4,5_000_000e6,5_000_000e6,100e6,500_000e6,5,25,3);
        // USD/MXN — Mexican Peso
        _add("USD/MXN","USD","MXN",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca,0,0,2000,50,8,4,5_000_000e6,5_000_000e6,100e6,500_000e6,5,25,3);
        // USD/BRL — Brazilian Real
        _add("USD/BRL","USD","BRL",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0x6c75e52531ec5fd3ef253f6062956a8508a2f03fa0a209fb7fbc51ebea3cb2d0,0,0,2000,50,8,4,5_000_000e6,5_000_000e6,100e6,500_000e6,5,25,3);
        // USD/INR — Indian Rupee
        _add("USD/INR","USD","INR",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0x9dd2f5e5ca7bdc09b82696c31e866b807a1b44c45e3ee0d9db22b6da8dbca31c,0,0,2000,50,8,4,5_000_000e6,5_000_000e6,100e6,500_000e6,5,25,3);
        // USD/SGD — Singapore Dollar
        _add("USD/SGD","USD","SGD",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0x396a969a9c1480fa15ed50bc59149e2c0075a72fe8f458ed941ddec48bdb4918,0,0,2000,50,5,2,5_000_000e6,5_000_000e6,100e6,500_000e6,3,15,5);
        // USD/HKD — Hong Kong Dollar
        _add("USD/HKD","USD","HKD",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0x7254abad1770cabc0a58617e79b20e0de38f41cee77bd93e3c0b3e8b3d56e02,0,0,2000,50,5,2,5_000_000e6,5_000_000e6,100e6,500_000e6,3,15,4);
        // USD/KRW — South Korean Won (Guardian)
        _add("USD/KRW","USD","KRW",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,3_000_000e6,3_000_000e6,100e6,300_000e6,6,30,2);
        // USD/THB — Thai Baht (Guardian)
        _add("USD/THB","USD","THB",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,3_000_000e6,3_000_000e6,100e6,300_000e6,6,30,3);
        // USD/NGN — Nigerian Naira (Guardian)
        _add("USD/NGN","USD","NGN",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,1000,100,10,5,1_000_000e6,1_000_000e6,100e6,100_000e6,10,50,2);
        // USD/EGP — Egyptian Pound (Guardian)
        _add("USD/EGP","USD","EGP",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,1000,100,10,5,1_000_000e6,1_000_000e6,100e6,100_000e6,10,50,3);
        // USD/PKR — Pakistani Rupee (Guardian)
        _add("USD/PKR","USD","PKR",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,1000,100,10,5,1_000_000e6,1_000_000e6,100e6,100_000e6,10,50,2);
        // USD/IDR — Indonesian Rupiah (Pyth)
        _add("USD/IDR","USD","IDR",CAT_FOREX_EXOTIC,SRC_PYTH,address(0),0x1100000000000000000000000000000000000000000000000000000000000001,0,0,2000,50,8,4,3_000_000e6,3_000_000e6,100e6,300_000e6,6,30,2);
        // USD/MYR — Malaysian Ringgit (Guardian)
        _add("USD/MYR","USD","MYR",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,3_000_000e6,3_000_000e6,100e6,300_000e6,6,30,4);
        // USD/PHP — Philippine Peso (Guardian)
        _add("USD/PHP","USD","PHP",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,3_000_000e6,3_000_000e6,100e6,300_000e6,6,30,3);
        // USD/AED — UAE Dirham (Guardian — USD-pegged, low vol)
        _add("USD/AED","USD","AED",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,1000,100,5,2,2_000_000e6,2_000_000e6,100e6,200_000e6,3,15,4);
        // USD/SAR — Saudi Riyal (Guardian)
        _add("USD/SAR","USD","SAR",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,1000,100,5,2,2_000_000e6,2_000_000e6,100e6,200_000e6,3,15,4);
        // USD/CZK, PLN, HUF — Eastern Europe (Guardian)
        _add("USD/CZK","USD","CZK",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,2_000_000e6,2_000_000e6,100e6,200_000e6,6,30,3);
        _add("USD/PLN","USD","PLN",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,2_000_000e6,2_000_000e6,100e6,200_000e6,6,30,4);
        _add("USD/HUF","USD","HUF",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,2000,50,8,4,2_000_000e6,2_000_000e6,100e6,200_000e6,6,30,2);
        // USD/RUB — Russian Ruble (Guardian — high risk)
        _add("USD/RUB","USD","RUB",CAT_FOREX_EXOTIC,SRC_GUARDIAN,address(0),bytes32(0),0,0,500,200,15,8,500_000e6,500_000e6,100e6,50_000e6,15,60,2);

        // ── METALS ────────────────────────────────────────────────────────
        _add("XAU/USD","XAU","USD",CAT_METALS,SRC_CHAINLINK,CL_XAU_USD,bytes32(0),0,0,10000,10,3,1,50_000_000e6,50_000_000e6,100e6,5_000_000e6,2,10,2);
        _add("XAG/USD","XAG","USD",CAT_METALS,SRC_CHAINLINK,CL_XAG_USD,bytes32(0),0,0,5000, 20,4,2,20_000_000e6,20_000_000e6,100e6,2_000_000e6,3,12,4);
        // Platinum + Palladium via Pyth
        _add("XPT/USD","XPT","USD",CAT_METALS,SRC_PYTH,address(0),0x9f4e8c5d6b3a1e7f2a8d4c0b9e6f3a2b5c8d1e4f7a0b3c6d9e2f5a8b1c4d7e0f3,0,0,5000,20,5,2,10_000_000e6,10_000_000e6,100e6,1_000_000e6,4,15,2);
        _add("XPD/USD","XPD","USD",CAT_METALS,SRC_PYTH,address(0),0xa8b1c4d7e0f3a6b9c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b3c6d9e2f5a8b1,0,0,5000,20,5,2,5_000_000e6, 5_000_000e6, 100e6,500_000e6,  5,20,2);

        // ── COMMODITIES ───────────────────────────────────────────────────
        _add("WTI/USD","WTI","USD",CAT_COMMODITIES,SRC_PYTH,address(0),0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a,0,0,2000,50,5,2,20_000_000e6,20_000_000e6,100e6,2_000_000e6,3,15,2);
        _add("BRENT/USD","BRENT","USD",CAT_COMMODITIES,SRC_PYTH,address(0),0xc96458d393fe9deb7a7d63a0ac41e2898a67a7750dbd166673279e06c868df8a,0,0,2000,50,5,2,20_000_000e6,20_000_000e6,100e6,2_000_000e6,3,15,2);
        _add("NG/USD","NG","USD",CAT_COMMODITIES,SRC_PYTH,address(0),0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b,0,0,1000,100,8,4,10_000_000e6,10_000_000e6,100e6,1_000_000e6,5,25,4);
    }

    // ── Internal market registration ───────────────────────────────────────
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
        markets[id] = Market({
            id: id, symbol: symbol, baseAsset: base, quoteAsset: quote,
            category: category, oracleSource: oracleSrc,
            oracleFeed: feed, pythPriceId: pythId,
            baseMarketId: baseMarket, quoteMarketId: quoteMarket,
            maxLeverageBps: maxLev, maintenanceMarginBps: maintMargin,
            takerFeeBps: takerFee, makerFeeBps: makerFee,
            maxOILong: maxOIL, maxOIShort: maxOIS,
            minPositionSize: minPos, maxPositionSize: maxPos,
            spreadBps: spread, offHoursSpreadBps: offHoursSpread,
            active: true, reduceOnly: false, pricePrecision: pricePrecision
        });
        symbolToId[symbol] = id;
        activeMarketIds.push(id);
        emit MarketAdded(id, symbol, category);
    }

    // ── Views ──────────────────────────────────────────────────────────────
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

    // ── Admin ──────────────────────────────────────────────────────────────
    function addMarket(
        string calldata symbol, string calldata base, string calldata quote,
        uint8 category, uint8 oracleSrc, address feed, bytes32 pythId,
        uint256 baseM, uint256 quoteM, uint256 maxLev, uint256 maint,
        uint256 taker, uint256 maker, uint256 oiL, uint256 oiS,
        uint256 minP, uint256 maxP, uint256 spread, uint256 offH, uint256 prec
    ) external onlyOwner {
        _add(symbol, base, quote, category, oracleSrc, feed, pythId, baseM, quoteM, maxLev, maint, taker, maker, oiL, oiS, minP, maxP, spread, offH, prec);
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
