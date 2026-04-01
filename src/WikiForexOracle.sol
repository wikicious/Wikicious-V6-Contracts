// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WikiForexOracle — Triple-source oracle for all markets
///
/// ORACLE PRIORITY:
///   1. Chainlink  — direct feed, most decentralised (~40 pairs)
///   2. Pyth       — push-based, needs on-chain update (~80 pairs)
///   3. Guardian   — permissioned multisig, exotic pairs only
///
/// DERIVED PAIRS:
///   EUR/GBP = EUR/USD price / GBP/USD price
///   Calculated trustlessly from two direct feeds
///
/// MARKET HOURS (UTC):
///   FOREX + METALS: Monday 00:00 → Friday 21:00
///     Hard close: Friday 21:00 → Sunday 22:00
///     Can open positions only during market hours
///     Closing positions always allowed
///   CRYPTO:         Always open 24/7/365
///   COMMODITIES:    Monday 01:00 → Friday 22:00
///
/// SPREAD MODEL:
///   During hours:     base spread (e.g. 1 pip for EUR/USD)
///   Off-hours:        wider spread (5x) — soft liquidity
///   Exotic pairs:     always wider (5-10 pips)

interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

interface IPythOracle {
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }
    struct PriceFeed {
        bytes32 id;
        Price   price;
        Price   emaPrice;
    }
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);
}

interface IWikiMarketRegistry {
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
    function getMarket(uint256 id) external view returns (Market memory);
}

contract WikiForexOracle is Ownable2Step, Pausable {

    IPythOracle public pyth;
    address     public guardianSigner;  // multisig for exotic pairs
    IWikiMarketRegistry public registry;

    // Arbitrum sequencer uptime feed
    address public constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint256 public constant SEQUENCER_GRACE = 3600; // 1hr after sequencer restart

    uint256 public constant CHAINLINK_STALE = 3600;   // 1hr staleness for forex (updated ~1/hr)
    uint256 public constant PYTH_STALE      = 60;     // 60s for Pyth (push model)
    uint256 public constant GUARDIAN_STALE  = 300;    // 5min for guardian

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

    // Guardian price store (exotic pairs updated by multisig keeper)
    struct GuardianPrice {
        uint256 price;      // 8 decimal places
        uint256 updatedAt;
        uint256 confidence; // max deviation from reference (bps)
    }
    mapping(uint256 => GuardianPrice) public guardianPrices; // marketId → price

    // Market hours circuit breaker overrides
    mapping(uint256 => bool) public marketForceOpen;  // admin override
    mapping(uint256 => bool) public marketForceClosed;

    // Price result
    struct PriceResult {
        uint256 price;      // 8 decimal places, e.g. 1.08500 = 108500000
        uint256 timestamp;
        uint256 confidence; // bps deviation
        uint8   source;
        bool    marketOpen;
        uint256 effectiveSpreadBps; // spread to apply
    }

    event GuardianPriceUpdated(uint256 indexed marketId, uint256 price, uint256 confidence);
    event MarketHoursOverride(uint256 indexed marketId, bool forceOpen);

    constructor(address _pyth, address _guardian, address _registry, address owner)
        Ownable(owner)
    {
        require(_pyth != address(0), "Wiki: zero _pyth");
        require(_guardian != address(0), "Wiki: zero _guardian");
        require(_registry != address(0), "Wiki: zero _registry");
        pyth           = IPythOracle(_pyth);
        guardianSigner = _guardian;
        registry       = IWikiMarketRegistry(_registry);
    }

    // ── Main price getter ──────────────────────────────────────────────────
    /// @notice Get current price for a market with full context
    function getPrice(uint256 marketId) external view returns (PriceResult memory result) {
        IWikiMarketRegistry.Market memory m = registry.getMarket(marketId);
        require(m.active, "Oracle: market not active");
        _checkSequencer();

        result.marketOpen = _isMarketOpen(m.category);

        if (m.oracleSource == SRC_CHAINLINK) {
            (result.price, result.timestamp, result.confidence) = _getChainlinkPrice(m.oracleFeed);
            result.source = SRC_CHAINLINK;
        } else if (m.oracleSource == SRC_PYTH) {
            (result.price, result.timestamp, result.confidence) = _getPythPrice(m.pythPriceId);
            result.source = SRC_PYTH;
        } else if (m.oracleSource == SRC_GUARDIAN) {
            (result.price, result.timestamp, result.confidence) = _getGuardianPrice(marketId);
            result.source = SRC_GUARDIAN;
        } else if (m.oracleSource == SRC_DERIVED) {
            (result.price, result.timestamp, result.confidence) = _getDerivedPrice(m.baseMarketId, m.quoteMarketId);
            result.source = SRC_DERIVED;
        }

        require(result.price > 0, "Oracle: zero price");

        // Effective spread — wider off-hours
        result.effectiveSpreadBps = result.marketOpen
            ? m.spreadBps
            : m.offHoursSpreadBps;
    }

    /// @notice Simpler getter for WikiPerp compatibility
    function getPriceSimple(uint256 marketId) external view returns (uint256 price, uint256 timestamp) {
        PriceResult memory r = this.getPrice(marketId);
        return (r.price, r.timestamp);
    }

    /// @notice Check if market is open for NEW positions
    function isMarketOpen(uint256 marketId) external view returns (bool) {
        IWikiMarketRegistry.Market memory m = registry.getMarket(marketId);
        return _isMarketOpen(m.category);
    }

    /// @notice Get price for derived pair (e.g. EUR/GBP = EUR/USD / GBP/USD)
    function getDerivedPrice(uint256 baseId, uint256 quoteId)
        external view returns (uint256 price, uint256 timestamp)
    {
        (price, timestamp,) = _getDerivedPrice(baseId, quoteId);
    }

    // ── Market hours logic ─────────────────────────────────────────────────
    // All times in UTC. Forex week: Mon 00:00 → Fri 21:00
    // Day of week: 0=Sun, 1=Mon, ..., 5=Fri, 6=Sat
    function _isMarketOpen(uint8 category) internal view returns (bool) {
        if (category == CAT_CRYPTO) return true; // 24/7

        uint256 ts    = block.timestamp;
        uint256 dow   = ((ts / 86400) + 4) % 7; // days since epoch, Thu=0 → +4 → Mon=0... let's use Sun=0
        // Correct: epoch day 0 = Thu Jan 1 1970
        // (ts / 86400 + 4) % 7 gives 0=Mon, 1=Tue, ..., 6=Sun
        uint256 dayOfWeek = (ts / 86400 + 4) % 7; // 0=Mon,1=Tue,2=Wed,3=Thu,4=Fri,5=Sat,6=Sun
        uint256 timeOfDay = ts % 86400;            // seconds since midnight UTC

        if (category == CAT_FOREX_MAJOR || category == CAT_FOREX_MINOR
            || category == CAT_FOREX_EXOTIC || category == CAT_METALS)
        {
            // Open: Mon 00:00 → Fri 21:00 UTC
            if (dayOfWeek == 5 || dayOfWeek == 6) return false; // Sat, Sun
            if (dayOfWeek == 4 && timeOfDay >= 75600) return false; // Fri after 21:00
            return true;
        }

        if (category == CAT_COMMODITIES) {
            // Open: Mon 01:00 → Fri 22:00 UTC
            if (dayOfWeek == 5 || dayOfWeek == 6) return false;
            if (dayOfWeek == 0 && timeOfDay < 3600)  return false; // Mon before 01:00
            if (dayOfWeek == 4 && timeOfDay >= 79200) return false; // Fri after 22:00
            return true;
        }

        return true;
    }

    // ── Chainlink ──────────────────────────────────────────────────────────
    function _getChainlinkPrice(address feed)
        internal view returns (uint256 price, uint256 ts, uint256 conf)
    {
        IChainlinkFeed cl = IChainlinkFeed(feed);
        (, int256 answer,, uint256 updatedAt,) = cl.latestRoundData();
        require(answer > 0,                               "Oracle: CL negative");
        require(block.timestamp - updatedAt < CHAINLINK_STALE, "Oracle: CL stale");
        uint8 dec = cl.decimals();
        // Normalise to 8 decimals
        if (dec < 8) price = uint256(answer) * (10 ** (8 - dec));
        else if (dec > 8) price = uint256(answer) / (10 ** (dec - 8));
        else price = uint256(answer);
        ts   = updatedAt;
        conf = 5; // Chainlink ~0.05% deviation threshold
    }

    // ── Pyth ──────────────────────────────────────────────────────────────
    function _getPythPrice(bytes32 pythId)
        internal view returns (uint256 price, uint256 ts, uint256 conf)
    {
        IPythOracle.Price memory p = pyth.getPriceNoOlderThan(pythId, PYTH_STALE);
        require(p.price > 0, "Oracle: Pyth negative");
        // Pyth price: price × 10^expo, normalise to 8 dec
        int32 expo = p.expo;
        uint256 raw = uint256(int256(p.price));
        if (expo < -8) {
            price = raw / (10 ** uint32(-expo - 8));
        } else if (expo > -8) {
            price = raw * (10 ** uint32(8 + expo));
        } else {
            price = raw;
        }
        ts   = p.publishTime;
        // Confidence interval as bps of price
        conf = p.conf * 10000 / uint64(p.price); // approximate
    }

    // ── Guardian ──────────────────────────────────────────────────────────
    function _getGuardianPrice(uint256 marketId)
        internal view returns (uint256 price, uint256 ts, uint256 conf)
    {
        GuardianPrice storage gp = guardianPrices[marketId];
        require(gp.price > 0,                                "Oracle: no guardian price");
        require(block.timestamp - gp.updatedAt < GUARDIAN_STALE, "Oracle: guardian stale");
        price = gp.price;
        ts    = gp.updatedAt;
        conf  = gp.confidence;
    }

    // ── Derived pairs (EUR/GBP etc) ────────────────────────────────────────
    function _getDerivedPrice(uint256 baseId, uint256 quoteId)
        internal view returns (uint256 price, uint256 ts, uint256 conf)
    {
        IWikiMarketRegistry.Market memory bm = registry.getMarket(baseId);
        IWikiMarketRegistry.Market memory qm = registry.getMarket(quoteId);

        uint256 basePrice; uint256 baseTs; uint256 baseConf;
        uint256 quotPrice; uint256 quotTs; uint256 quotConf;

        if (bm.oracleSource == SRC_CHAINLINK)
            (basePrice, baseTs, baseConf) = _getChainlinkPrice(bm.oracleFeed);
        else if (bm.oracleSource == SRC_PYTH)
            (basePrice, baseTs, baseConf) = _getPythPrice(bm.pythPriceId);
        else
            (basePrice, baseTs, baseConf) = _getGuardianPrice(baseId);

        if (qm.oracleSource == SRC_CHAINLINK)
            (quotPrice, quotTs, quotConf) = _getChainlinkPrice(qm.oracleFeed);
        else if (qm.oracleSource == SRC_PYTH)
            (quotPrice, quotTs, quotConf) = _getPythPrice(qm.pythPriceId);
        else
            (quotPrice, quotTs, quotConf) = _getGuardianPrice(quoteId);

        require(quotPrice > 0, "Oracle: zero quote price");

        // EUR/GBP = EUR/USD ÷ GBP/USD, scaled to 8 dec
        price = basePrice * 1e8 / quotPrice;
        ts    = baseTs < quotTs ? baseTs : quotTs; // oldest timestamp
        conf  = baseConf + quotConf;               // combined uncertainty
    }

    // ── Sequencer uptime check ─────────────────────────────────────────────
    function _checkSequencer() internal view {
        IChainlinkFeed seq = IChainlinkFeed(SEQUENCER_FEED);
        (, int256 answer,, uint256 startedAt,) = seq.latestRoundData();
        require(answer == 0, "Oracle: sequencer down");
        require(block.timestamp - startedAt > SEQUENCER_GRACE, "Oracle: sequencer grace");
    }

    // ── Guardian updater (called by keeper bot) ───────────────────────────
    /// @notice Multisig keeper updates exotic pair prices
    function updateGuardianPrice(
        uint256   marketId,
        uint256   price,
        uint256   confidence,
        bytes calldata signature
    ) external {
        // Verify signature from guardianSigner
        bytes32 hash = keccak256(abi.encodePacked(marketId, price, confidence, block.timestamp / 300)); // 5min buckets
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        address signer  = _recover(ethHash, signature);
        require(signer == guardianSigner, "Oracle: invalid guardian sig");
        require(price > 0,               "Oracle: zero price");
        require(confidence <= 500,       "Oracle: confidence too wide"); // max 5% spread

        guardianPrices[marketId] = GuardianPrice({
            price:      price,
            updatedAt:  block.timestamp,
            confidence: confidence
        });
        emit GuardianPriceUpdated(marketId, price, confidence);
    }

    /// @notice Batch update multiple guardian prices in one tx
    function batchUpdateGuardian(
        uint256[] calldata marketIds,
        uint256[] calldata prices,
        uint256[] calldata confidences,
        bytes     calldata signature
    ) external {
        require(marketIds.length == prices.length && prices.length == confidences.length, "Oracle: length mismatch");
        // Verify batch signature
        bytes32 hash    = keccak256(abi.encodePacked(marketIds, prices, confidences, block.timestamp / 300));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        require(_recover(ethHash, signature) == guardianSigner, "Oracle: invalid sig");

        for (uint i = 0; i < marketIds.length; i++) {
            require(prices[i] > 0, "Oracle: zero price");
            guardianPrices[marketIds[i]] = GuardianPrice({
                price:      prices[i],
                updatedAt:  block.timestamp,
                confidence: confidences[i]
            });
            emit GuardianPriceUpdated(marketIds[i], prices[i], confidences[i]);
        }
    }

    /// @notice Update Pyth price feeds on-chain (permissionless, anyone pays gas)
    function updatePythPrices(bytes[] calldata updateData) external payable {
        uint fee = pyth.getUpdateFee(updateData);
        pyth.updatePriceFeeds{value: fee}(updateData);
    }

    // ── Admin ──────────────────────────────────────────────────────────────
    function setPyth(address p)          external onlyOwner { pyth = IPythOracle(p); }
    function setGuardianSigner(address g)external onlyOwner { guardianSigner = g; }
    function setRegistry(address r)      external onlyOwner { registry = IWikiMarketRegistry(r); }
    function setMarketForceOpen(uint256 id, bool open) external onlyOwner {
        marketForceOpen[id]   = open;
        marketForceClosed[id] = false;
        emit MarketHoursOverride(id, open);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── ECDSA recovery ─────────────────────────────────────────────────────
    function _recover(bytes32 hash, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "Oracle: bad sig length");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return ecrecover(hash, v, r, s);
    }

    receive() external payable {}
}
