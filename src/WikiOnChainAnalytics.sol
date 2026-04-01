// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiOnChainAnalytics
 * @notice Aggregated protocol statistics stored on-chain.
 *         Powers the public analytics dashboard and DefiLlama integration.
 *         Builds trust with institutional traders who require transparency.
 *
 * METRICS TRACKED:
 *   Protocol:  total volume, total fees, total trades, unique traders
 *   Markets:   volume per market, OI, funding rates, liquidations
 *   Daily:     24h snapshot of all key metrics
 *   Users:     unique daily/weekly/monthly active traders
 *
 * DEFI LLAMA INTEGRATION:
 *   getTVL()           → returns total protocol TVL for DefiLlama
 *   get24hVolume()     → 24h trading volume
 *   get24hFees()       → 24h fees generated
 *   getCumulativeFees()→ all-time fees
 */
contract WikiOnChainAnalytics is Ownable2Step {

    struct ProtocolSnapshot {
        uint256 timestamp;
        uint256 totalVolumeUsdc;
        uint256 totalFeesUsdc;
        uint256 totalTrades;
        uint256 uniqueTraders;
        uint256 openInterest;
        uint256 tvl;                 // total value locked
        uint256 backstopTVL;
        uint256 lendingTVL;
        uint256 fundedPoolTVL;
    }

    struct MarketStats {
        uint256 volume24h;
        uint256 volumeAllTime;
        uint256 openInterest;
        int256  fundingRate8h;
        uint256 liquidations24h;
        uint256 liquidationsAllTime;
        uint256 uniqueTraders24h;
        uint256 lastUpdate;
    }

    struct DailyStats {
        uint256 day;             // unix day (block.timestamp / 1 days)
        uint256 volume;
        uint256 fees;
        uint256 trades;
        uint256 newTraders;
        uint256 liquidations;
        uint256 propChallenges;
        uint256 propPassed;
    }

    // All-time cumulative
    uint256 public totalVolumeAllTime;
    uint256 public totalFeesAllTime;
    uint256 public totalTradesAllTime;
    uint256 public totalLiquidationsAllTime;
    uint256 public totalUniqueTraders;

    // Current 24h window (rolling)
    uint256 public volume24h;
    uint256 public fees24h;
    uint256 public trades24h;
    uint256 public windowStartTs;

    // Market-specific stats
    mapping(uint256 => MarketStats) public marketStats;  // marketId → stats

    // Daily history
    mapping(uint256 => DailyStats) public dailyHistory;  // day → stats
    uint256[] public recordedDays;

    // Trader registry
    mapping(address => bool) public isKnownTrader;
    mapping(address => uint256) public traderFirstSeen;

    mapping(address => bool) public recorders;

    event VolumeRecorded(uint256 marketId, uint256 volume, uint256 fees);
    event DailySnapshotSaved(uint256 day, uint256 volume, uint256 fees);

    constructor(address _owner) Ownable(_owner) {
        recorders[_owner] = true;
        windowStartTs = block.timestamp;
    }

    // ── Record trade (called by WikiPerp, WikiSpot etc) ───────────────────
    function recordTrade(
        address trader,
        uint256 marketId,
        uint256 notional,
        uint256 fee,
        bool    isLiquidation
    ) external {
        require(recorders[msg.sender], "Analytics: not recorder");

        // New trader?
        if (!isKnownTrader[trader]) {
            isKnownTrader[trader]    = true;
            traderFirstSeen[trader]  = block.timestamp;
            totalUniqueTraders++;
        }

        // All-time
        totalVolumeAllTime  += notional;
        totalFeesAllTime    += fee;
        totalTradesAllTime++;
        if (isLiquidation) totalLiquidationsAllTime++;

        // Rolling 24h window
        if (block.timestamp >= windowStartTs + 1 days) {
            // Save daily snapshot
            uint256 day = windowStartTs / 1 days;
            if (dailyHistory[day].day == 0) recordedDays.push(day);
            dailyHistory[day].volume += volume24h;
            dailyHistory[day].fees   += fees24h;
            dailyHistory[day].trades += trades24h;
            emit DailySnapshotSaved(day, volume24h, fees24h);
            volume24h     = 0;
            fees24h       = 0;
            trades24h     = 0;
            windowStartTs = block.timestamp;
        }
        volume24h += notional;
        fees24h   += fee;
        trades24h++;

        // Market-specific
        MarketStats storage m = marketStats[marketId];
        m.volume24h    += notional;
        m.volumeAllTime+= notional;
        m.lastUpdate    = block.timestamp;
        if (isLiquidation) { m.liquidations24h++; m.liquidationsAllTime++; }

        emit VolumeRecorded(marketId, notional, fee);
    }

    function updateFundingRate(uint256 marketId, int256 rate8h) external {
        require(recorders[msg.sender], "Analytics: not recorder");
        marketStats[marketId].fundingRate8h = rate8h;
        marketStats[marketId].lastUpdate    = block.timestamp;
    }

    function updateOpenInterest(uint256 marketId, uint256 oi) external {
        require(recorders[msg.sender], "Analytics: not recorder");
        marketStats[marketId].openInterest = oi;
    }

    // ── DefiLlama compatible views ────────────────────────────────────────
    function get24hVolume() external view returns (uint256) { return volume24h; }
    function get24hFees()   external view returns (uint256) { return fees24h; }
    function getCumulativeFees() external view returns (uint256) { return totalFeesAllTime; }
    function getCumulativeVolume() external view returns (uint256) { return totalVolumeAllTime; }

    // ── Dashboard views ───────────────────────────────────────────────────
    function getProtocolSummary() external view returns (
        uint256 vol24h, uint256 fees24hOut, uint256 volAllTime,
        uint256 feesAllTime, uint256 totalTrades, uint256 uniqueTraders,
        uint256 totalLiqs
    ) {
        return (volume24h, fees24h, totalVolumeAllTime, totalFeesAllTime,
                totalTradesAllTime, totalUniqueTraders, totalLiquidationsAllTime);
    }

    function getMarketStats(uint256 marketId) external view returns (MarketStats memory) {
        return marketStats[marketId];
    }

    function getDailyHistory(uint256 numDays) external view returns (DailyStats[] memory history) {
        uint256 n = numDays < recordedDays.length ? numDays : recordedDays.length;
        history   = new DailyStats[](n);
        for (uint i; i < n; i++) {
            history[i] = dailyHistory[recordedDays[recordedDays.length - 1 - i]];
        }
    }

    // Annualised fee run rate based on last 30 days
    function getAnnualisedFeeRunRate() external view returns (uint256) {
        if (recordedDays.length < 7) return fees24h * 365;
        uint256 days_ = recordedDays.length < 30 ? recordedDays.length : 30;
        uint256 total;
        for (uint i; i < days_; i++) {
            total += dailyHistory[recordedDays[recordedDays.length - 1 - i]].fees;
        }
        return total * 365 / days_;
    }

    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
