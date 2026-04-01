// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiIndexPerp
 * @notice Defines and prices basket perpetual markets (index products).
 *         Traders get single-position exposure to a diversified basket.
 *
 * INDICES
 * ─────────────────────────────────────────────────────────────────────────
 * WDEFI   — DeFi index: UNI 25%, AAVE 20%, LINK 20%, GMX 15%, ARB 20%
 * WL2     — Layer 2 index: ARB 40%, OP 30%, MATIC 30%
 * WTOP5   — Top 5 crypto: BTC 40%, ETH 30%, BNB 15%, SOL 10%, ARB 5%
 * WGAMING — Gaming/Metaverse: custom basket
 *
 * HOW INDEX PRICE IS COMPUTED
 * ─────────────────────────────────────────────────────────────────────────
 * IndexPrice = Σ (weight[i] × oracle_price[i]) for each component
 * Weights are in BPS (e.g. 2500 = 25%).
 * WikiOracle provides individual component prices via getPrice().
 *
 * INTEGRATION WITH WikiPerp
 * ─────────────────────────────────────────────────────────────────────────
 * WikiIndexPerp registers index markets in WikiMarketRegistry.
 * When WikiPerp needs the price for an index market, it calls
 * WikiIndexPerp.getIndexPrice() instead of WikiOracle.getPrice().
 * All other perp mechanics (funding, liquidation, settlement) are identical.
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * Same 0.06% taker fee as individual markets.
 * Basket products attract larger position sizes (macro exposure seekers).
 * Historically index products generate 2–3× TVL per market vs single assets.
 */
interface IWikiOracle {
    function getPrice(bytes32 marketId) external view returns (uint256 price, uint256 updatedAt);
}

contract WikiIndexPerp is Ownable2Step, ReentrancyGuard {

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant BPS        = 10_000;
    uint256 public constant PRECISION  = 1e18;
    uint256 public constant MAX_COMPONENTS = 10;

    // ── Structs ────────────────────────────────────────────────────────────

    struct Component {
        bytes32 oracleId;   // WikiOracle market ID (e.g. keccak256("ETHUSD"))
        string  symbol;     // human-readable (e.g. "ETHUSD")
        uint256 weightBps;  // weight in BPS, sum must = 10000
    }

    struct Index {
        string      name;         // e.g. "DeFi Index"
        string      symbol;       // e.g. "WDEFI"
        bytes32     marketId;     // keccak256(symbol) — used in WikiPerp
        Component[] components;
        uint256     lastPrice;    // last computed price (1e18)
        uint256     lastUpdate;
        uint256     maxLeverage;
        uint256     makerFeeBps;
        uint256     takerFeeBps;
        bool        active;
    }

    // ── State ──────────────────────────────────────────────────────────────
    Index[]  public indices;
    address  public oracle;         // WikiOracle address
    address  public perpRegistry;   // WikiMarketRegistry — to register new markets

    mapping(bytes32 => uint256) public marketIdToIndex; // marketId → index id+1

    // ── Events ─────────────────────────────────────────────────────────────
    event IndexCreated(uint256 indexed id, string symbol, bytes32 marketId);
    event IndexPriceUpdated(uint256 indexed id, uint256 price, uint256 timestamp);
    event ComponentUpdated(uint256 indexed id, uint256 componentIdx, uint256 newWeight);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _oracle, address _owner) Ownable(_owner) {
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(_owner != address(0), "Wiki: zero _owner");
        oracle = _oracle;
        _createDefaultIndices();
    }

    // ── Create Indices ─────────────────────────────────────────────────────

    function createIndex(
        string   calldata name,
        string   calldata symbol,
        string[] calldata componentSymbols,
        bytes32[] calldata oracleIds,
        uint256[] calldata weightsBps,
        uint256   maxLeverage,
        uint256   takerFeeBps
    ) external onlyOwner returns (uint256 id) {
        require(componentSymbols.length == oracleIds.length, "IX: length mismatch");
        require(componentSymbols.length == weightsBps.length, "IX: length mismatch");
        require(componentSymbols.length <= MAX_COMPONENTS, "IX: too many components");

        // Validate weights sum to 10000
        uint256 weightSum;
        for (uint i; i < weightsBps.length; i++) weightSum += weightsBps[i];
        require(weightSum == BPS, "IX: weights must sum to 10000");

        id = indices.length;
        bytes32 marketId = keccak256(abi.encodePacked(symbol));

        indices.push();
        Index storage idx = indices[id];
        idx.name        = name;
        idx.symbol      = symbol;
        idx.marketId    = marketId;
        idx.maxLeverage = maxLeverage;
        idx.makerFeeBps = 0;
        idx.takerFeeBps = takerFeeBps;
        idx.active      = true;

        for (uint i; i < componentSymbols.length; i++) {
            idx.components.push(Component({
                oracleId:  oracleIds[i],
                symbol:    componentSymbols[i],
                weightBps: weightsBps[i]
            }));
        }

        marketIdToIndex[marketId] = id + 1;
        emit IndexCreated(id, symbol, marketId);
    }

    // ── Price Computation ─────────────────────────────────────────────────

    /**
     * @notice Compute the current index price from component oracle prices.
     * @param id   Index id
     * @return price  Weighted basket price (1e18 scaled)
     */
    function computeIndexPrice(uint256 id) public view returns (uint256 price) {
        Index storage idx = indices[id];
        require(idx.active, "IX: inactive");

        IWikiOracle ora = IWikiOracle(oracle);
        for (uint i; i < idx.components.length; i++) {
            Component storage c = idx.components[i];
            (uint256 compPrice,) = ora.getPrice(c.oracleId);
            price += compPrice * c.weightBps / BPS;
        }
    }

    /**
     * @notice Update stored price for an index (called by keeper).
     */
    function updatePrice(uint256 id) external nonReentrant returns (uint256 price) {
        price = computeIndexPrice(id);
        indices[id].lastPrice  = price;
        indices[id].lastUpdate = block.timestamp;
        emit IndexPriceUpdated(id, price, block.timestamp);
    }

    /**
     * @notice Get the latest price for a market ID (called by WikiPerp).
     */
    function getIndexPrice(bytes32 marketId) external view returns (uint256 price, uint256 updatedAt) {
        uint256 idx = marketIdToIndex[marketId];
        require(idx > 0, "IX: market not found");
        Index storage i = indices[idx - 1];
        price     = i.lastPrice > 0 ? i.lastPrice : computeIndexPrice(idx - 1);
        updatedAt = i.lastUpdate;
    }

    // ── Default Indices ────────────────────────────────────────────────────

    function _createDefaultIndices() internal {
        // WDEFI: DeFi Index
        indices.push();
        Index storage defi = indices[0];
        defi.name = "DeFi Index"; defi.symbol = "WDEFI";
        defi.marketId = keccak256("WDEFI");
        defi.maxLeverage = 50; defi.takerFeeBps = 6; defi.active = true;
        defi.components.push(Component(keccak256("UNIUSD"),  "UNIUSDT",  2500));
        defi.components.push(Component(keccak256("AAVEUSD"), "AAVEUSDT", 2000));
        defi.components.push(Component(keccak256("LINKUSD"), "LINKUSDT", 2000));
        defi.components.push(Component(keccak256("GMXUSD"),  "GMXUSDT",  1500));
        defi.components.push(Component(keccak256("ARBUSD"),  "ARBUSDT",  2000));
        marketIdToIndex[defi.marketId] = 1;

        // WL2: Layer 2 Index
        indices.push();
        Index storage l2 = indices[1];
        l2.name = "Layer 2 Index"; l2.symbol = "WL2";
        l2.marketId = keccak256("WL2");
        l2.maxLeverage = 50; l2.takerFeeBps = 6; l2.active = true;
        l2.components.push(Component(keccak256("ARBUSD"),   "ARBUSDT",  4000));
        l2.components.push(Component(keccak256("OPUSD"),    "OPUSDT",   3000));
        l2.components.push(Component(keccak256("MATICUSD"), "MATICUSDT",3000));
        marketIdToIndex[l2.marketId] = 2;

        // WTOP5: Top 5 Crypto
        indices.push();
        Index storage top5 = indices[2];
        top5.name = "Top 5 Crypto"; top5.symbol = "WTOP5";
        top5.marketId = keccak256("WTOP5");
        top5.maxLeverage = 100; top5.takerFeeBps = 5; top5.active = true;
        top5.components.push(Component(keccak256("BTCUSD"),  "BTCUSDT",  4000));
        top5.components.push(Component(keccak256("ETHUSD"),  "ETHUSDT",  3000));
        top5.components.push(Component(keccak256("BNBUSD"),  "BNBUSDT",  1500));
        top5.components.push(Component(keccak256("SOLUSD"),  "SOLUSDT",  1000));
        top5.components.push(Component(keccak256("ARBUSD"),  "ARBUSDT",   500));
        marketIdToIndex[top5.marketId] = 3;

        emit IndexCreated(0, "WDEFI",  defi.marketId);
        emit IndexCreated(1, "WL2",    l2.marketId);
        emit IndexCreated(2, "WTOP5",  top5.marketId);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function indexCount() external view returns (uint256) { return indices.length; }
    function getIndex(uint256 id) external view returns (
        string memory name, string memory symbol, bytes32 marketId,
        uint256 lastPrice, uint256 lastUpdate, bool active
    ) {
        Index storage i = indices[id];
        return (i.name, i.symbol, i.marketId, i.lastPrice, i.lastUpdate, i.active);
    }
    function getComponents(uint256 id) external view returns (Component[] memory) {
        return indices[id].components;
    }

    function setOracle(address _oracle) external onlyOwner { oracle = _oracle; }
    function setIndexActive(uint256 id, bool active) external onlyOwner { indices[id].active = active; }
}

