// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiOracle v2 — Chainlink + Pyth dual-source oracle
 *
 * PRICING HIERARCHY (per market):
 *  1. Chainlink (top 15 markets)  — auto-updated, 24h heartbeat
 *  2. Pyth Network (all 241)      — pull model, keeper pushes before trades
 *  3. Guardian fallback           — keeper-submitted, TWAP-validated
 *
 * Pyth interface IPyth {
    struct Price { int64 price; uint64 conf; int32 expo; uint publishTime; }

contract on Arbitrum: 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C
 * Hermes (price update API):  https://hermes.pyth.network
 *
 * ATTACK MITIGATIONS:
 * [A1] Flash loan manipulation  → 5-min TWAP blocks single-block spikes
 * [A2] Stale Chainlink          → heartbeat staleness check
 * [A3] CL circuit breaker       → min/max price bounds
 * [A4] Incomplete CL round      → answeredInRound >= roundId
 * [A5] Arbitrum sequencer down  → L2 sequencer uptime feed + grace period
 * [A6] Pyth staleness           → reject if older than MAX_PYTH_AGE (2 min)
 * [A7] Pyth wide confidence     → reject if conf/price > 2%
 * [A8] Source disagreement      → cross-validate Chainlink vs Pyth, max 10% spread
 */

interface ISequencerUptimeFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IPyth {
    struct Price { int64 price; uint64 conf; int32 expo; uint publishTime; }
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function updatePriceFeedsIfNecessary(bytes[] calldata, bytes32[] calldata, uint64[] calldata) external payable;
}

contract WikiOracle is Ownable2Step, Pausable {

    struct ChainlinkFeed {
        AggregatorV3Interface feed;
        uint32 heartbeat; uint8 decimals;
        uint256 minPrice; uint256 maxPrice;
        bool active;
    }
    struct PythFeed { bytes32 id; bool active; }
    struct GuardianPrice { uint256 price; uint256 submittedAt; }
    struct TWAPEntry { uint256 price; uint256 ts; }

    mapping(bytes32 => ChainlinkFeed)  public chainlinkFeeds;
    mapping(bytes32 => PythFeed)       public pythFeeds;
    mapping(bytes32 => GuardianPrice)  public guardianPrices;
    mapping(bytes32 => TWAPEntry[10])  private _twap;
    mapping(bytes32 => uint8)          private _twapIdx;
    mapping(bytes32 => uint8)          private _twapLen;
    mapping(address  => bool)          public guardians;
    mapping(bytes32  => bool)          public marketPaused;

    IPyth                public immutable pyth;
    ISequencerUptimeFeed public immutable sequencerFeed;

    uint256 public constant GUARDIAN_TTL      = 3600;
    uint256 public constant MAX_DEVIATION_BPS = 500;
    uint256 public constant TWAP_WINDOW       = 300;
    uint256 public constant SEQ_GRACE_PERIOD  = 3600;
    uint256 public constant MAX_PYTH_AGE      = 120;   // 2 minutes
    uint256 public constant MAX_PYTH_CONF_BPS = 200;   // 2% confidence width
    uint256 public constant BPS               = 10000;
    uint256 public constant PRECISION         = 1e18;

    event ChainlinkFeedSet(bytes32 indexed id, address feed);
    event PythFeedSet(bytes32 indexed id, bytes32 pythId);
    event GuardianPriceSet(bytes32 indexed id, uint256 price, address by);
    event GuardianUpdated(address indexed g, bool active);
    event MarketPausedSet(bytes32 indexed id, bool paused);

    constructor(address owner, address _seqFeed, address _pyth) Ownable(owner) {
        require(owner != address(0), "Wiki: zero owner");
        require(_seqFeed != address(0), "Wiki: zero _seqFeed");
        require(_pyth != address(0), "Wiki: zero _pyth");
        sequencerFeed = ISequencerUptimeFeed(_seqFeed);
        pyth          = IPyth(_pyth);
        guardians[owner] = true;
    }

    modifier onlyGuardian() { require(guardians[msg.sender], "Oracle: not guardian"); _; }

    // ── Feed Configuration ─────────────────────────────────────────────────

    function setChainlinkFeed(
        bytes32 id, address feed, uint32 heartbeat, uint8 decimals,
        uint256 minPrice, uint256 maxPrice
    ) external onlyOwner {
        chainlinkFeeds[id] = ChainlinkFeed({
            feed: AggregatorV3Interface(feed), heartbeat: heartbeat,
            decimals: decimals, minPrice: minPrice, maxPrice: maxPrice, active: true
        });
        emit ChainlinkFeedSet(id, feed);
    }

    function setPythFeed(bytes32 id, bytes32 pythId) external onlyOwner {
        pythFeeds[id] = PythFeed({ id: pythId, active: true });
        emit PythFeedSet(id, pythId);
    }

    /// @notice Gas-efficient batch setup for all 241 markets
    function batchSetPythFeeds(bytes32[] calldata ids, bytes32[] calldata pythIds) external onlyOwner {
        require(ids.length == pythIds.length, "Oracle: mismatch");
        for (uint i; i < ids.length; i++) {
            pythFeeds[ids[i]] = PythFeed({ id: pythIds[i], active: true });
            emit PythFeedSet(ids[i], pythIds[i]);
        }
    }

    function submitGuardianPrice(bytes32 id, uint256 price) external onlyGuardian {
        require(price > 0, "Oracle: zero price");
        uint256 twapPrice = _getTWAP(id);
        if (twapPrice > 0) {
            uint256 delta = price > twapPrice ? price - twapPrice : twapPrice - price;
            require(delta * BPS / twapPrice <= MAX_DEVIATION_BPS, "Oracle: guardian deviation");
        }
        guardianPrices[id] = GuardianPrice({ price: price, submittedAt: block.timestamp });
        _recordTWAP(id, price);
        emit GuardianPriceSet(id, price, msg.sender);
    }

    // ── Pyth Update (keeper calls before trade execution) ─────────────────

    function pushPythUpdates(bytes[] calldata updateData) external payable {
        uint fee = pyth.getUpdateFee(updateData);
        pyth.updatePriceFeeds{value: fee}(updateData);
    }

    function pushPythUpdatesIfStale(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable {
        uint fee = pyth.getUpdateFee(updateData);
        pyth.updatePriceFeedsIfNecessary{value: fee}(updateData, priceIds, publishTimes);
    }

    // ── Primary Price Read ─────────────────────────────────────────────────

    function getPrice(bytes32 id) external view whenNotPaused
        returns (uint256 price, uint256 updatedAt)
    {
        require(!marketPaused[id], "Oracle: market paused");
        _checkSequencer();

        uint256 clPrice; uint256 clTs;
        uint256 pyPrice; uint256 pyTs;

        ChainlinkFeed storage cf = chainlinkFeeds[id];
        if (cf.active && address(cf.feed) != address(0))
            (clPrice, clTs) = _readChainlink(cf);

        PythFeed storage pf = pythFeeds[id];
        if (pf.active && pf.id != bytes32(0))
            (pyPrice, pyTs) = _readPyth(pf.id);

        if (clPrice > 0 && pyPrice > 0) {
            uint256 delta = clPrice > pyPrice ? clPrice - pyPrice : pyPrice - clPrice;
            require(delta * BPS / clPrice <= MAX_DEVIATION_BPS * 2, "Oracle: CL/Pyth mismatch");
            return (clPrice, clTs);
        }
        if (clPrice > 0) return (clPrice, clTs);
        if (pyPrice > 0) return (pyPrice, pyTs);

        GuardianPrice storage gp = guardianPrices[id];
        require(gp.price > 0, "Oracle: no price");
        require(block.timestamp - gp.submittedAt <= GUARDIAN_TTL, "Oracle: guardian stale");
        uint256 twapPrice = _getTWAP(id);
        if (twapPrice > 0) {
            uint256 delta = gp.price > twapPrice ? gp.price - twapPrice : twapPrice - gp.price;
            require(delta * BPS / twapPrice <= MAX_DEVIATION_BPS, "Oracle: guardian TWAP");
        }
        return (gp.price, gp.submittedAt);
    }

    function getPriceBySymbol(string calldata symbol) external view returns (uint256, uint256) {
        return this.getPrice(keccak256(abi.encodePacked(symbol)));
    }

    // ── Internals ──────────────────────────────────────────────────────────

    function _readChainlink(ChainlinkFeed storage f) internal view returns (uint256, uint256) {
        try f.feed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (0, 0);
            if (block.timestamp - updatedAt > f.heartbeat) return (0, 0);
            if (answeredInRound < roundId) return (0, 0);
            uint256 raw = uint256(answer);
            uint256 price = f.decimals < 18 ? raw * 10**(18-f.decimals) : raw / 10**(f.decimals-18);
            if (price < f.minPrice || price > f.maxPrice) return (0, 0);
            return (price, updatedAt);
        } catch { return (0, 0); }
    }

    function _readPyth(bytes32 pythId) internal view returns (uint256, uint256) {
        try pyth.getPriceUnsafe(pythId) returns (IPyth.Price memory p) {
            if (p.price <= 0) return (0, 0);
            if (block.timestamp - p.publishTime > MAX_PYTH_AGE) return (0, 0);
            uint256 absPrice = uint256(uint64(p.price));
            if (absPrice > 0 && p.conf * BPS / absPrice > MAX_PYTH_CONF_BPS) return (0, 0);
            uint256 price;
            int32 expo = p.expo;
            if (expo >= 0) {
                price = absPrice * 10**uint32(expo);
            } else {
                uint32 neg = uint32(-expo);
                price = neg < 18 ? absPrice * 10**(18-neg) : absPrice / 10**(neg-18);
            }
            return (price, p.publishTime);
        } catch { return (0, 0); }
    }

    function _checkSequencer() internal view {
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        require(answer == 0, "Oracle: sequencer down");
        require(block.timestamp - startedAt >= SEQ_GRACE_PERIOD, "Oracle: grace period");
    }

    function _recordTWAP(bytes32 id, uint256 price) internal {
        uint8 idx = _twapIdx[id];
        _twap[id][idx] = TWAPEntry({ price: price, ts: block.timestamp });
        _twapIdx[id] = uint8((idx + 1) % 10);
        if (_twapLen[id] < 10) _twapLen[id]++;
    }

    function _getTWAP(bytes32 id) internal view returns (uint256) {
        uint8 len = _twapLen[id];
        if (len == 0) return 0;
        uint256 sum; uint256 cutoff = block.timestamp - TWAP_WINDOW; uint8 cnt;
        for (uint8 i; i < len; i++) {
            TWAPEntry memory e = _twap[id][i];
            if (e.ts >= cutoff) { sum += e.price; cnt++; }
        }
        return cnt == 0 ? 0 : sum / cnt;
    }

    function setGuardian(address g, bool active) external onlyOwner { guardians[g] = active; emit GuardianUpdated(g, active); }
    function setMarketPaused(bytes32 id, bool paused) external onlyOwner { marketPaused[id] = paused; emit MarketPausedSet(id, paused); }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    receive() external payable {}
}
