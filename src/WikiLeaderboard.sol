// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiLeaderboard
 * @notice Public on-chain leaderboard — ranked by return %, P&L, and volume.
 *         Hyperliquid's leaderboard drove viral Twitter growth. This does the same.
 *
 * RANKING CATEGORIES:
 *   Top PnL (absolute $)     — whales compete, impressive numbers go viral
 *   Top Return %             — levels the field, small accounts can compete
 *   Top Volume               — market makers and high-frequency traders
 *   Top Win Rate             — consistent traders, builds platform reputation
 *   Prop Leaderboard         — challenge pass rate, funded P&L
 *
 * HOW IT WORKS:
 *   WikiPerp/WikiSpot call updateStats() after every trade close.
 *   Stats accumulate per period (daily / weekly / all-time).
 *   Anyone can read rankings via getTopTraders().
 *   Traders can set a public display name.
 */
contract WikiLeaderboard is Ownable2Step {

    struct TraderStats {
        address trader;
        string  displayName;
        bool    isPublic;         // trader opts in to public display
        // All-time
        int256  totalPnlUsdc;     // net P&L in USDC (6 dec)
        uint256 totalVolume;      // total notional traded
        uint256 totalTrades;
        uint256 winningTrades;
        uint256 bestSingleTrade;
        uint256 peakBalance;
        // Current period (resets weekly)
        int256  weeklyPnl;
        uint256 weeklyVolume;
        uint256 weeklyTrades;
        uint256 lastTradeTs;
        uint256 lastWeekReset;
    }

    mapping(address => TraderStats) public stats;
    address[] public allTraders;
    mapping(address => bool) public registered;
    mapping(address => bool) public recorders;

    uint256 public constant WEEK = 7 days;

    event StatsUpdated(address indexed trader, int256 pnl, uint256 volume);
    event DisplayNameSet(address indexed trader, string name);

    constructor(address _owner) Ownable(_owner) {
        recorders[_owner] = true;
    }

    // ── Called by trading contracts after each trade ──────────────────────
    function recordTrade(
        address trader,
        int256  pnlUsdc,
        uint256 notional,
        bool    isWin
    ) external {
        require(recorders[msg.sender], "LB: not recorder");
        if (!registered[trader]) {
            registered[trader] = true;
            allTraders.push(trader);
            stats[trader].trader = trader;
            stats[trader].isPublic = true; // opt-in by default
            stats[trader].lastWeekReset = block.timestamp;
        }
        TraderStats storage s = stats[trader];

        // Reset weekly stats if new week
        if (block.timestamp >= s.lastWeekReset + WEEK) {
            s.weeklyPnl    = 0;
            s.weeklyVolume = 0;
            s.weeklyTrades = 0;
            s.lastWeekReset = block.timestamp;
        }

        s.totalPnlUsdc   += pnlUsdc;
        s.totalVolume    += notional;
        s.totalTrades++;
        s.weeklyPnl      += pnlUsdc;
        s.weeklyVolume   += notional;
        s.weeklyTrades++;
        s.lastTradeTs     = block.timestamp;

        if (isWin) s.winningTrades++;
        if (pnlUsdc > 0 && uint256(pnlUsdc) > s.bestSingleTrade) {
            s.bestSingleTrade = uint256(pnlUsdc);
        }
        emit StatsUpdated(trader, pnlUsdc, notional);
    }

    // ── Trader profile ────────────────────────────────────────────────────
    function setDisplayName(string calldata name) external {
        require(bytes(name).length <= 32, "LB: name too long");
        stats[msg.sender].displayName = name;
        emit DisplayNameSet(msg.sender, name);
    }

    function setPublic(bool isPublic) external { stats[msg.sender].isPublic = isPublic; }

    // ── Rankings (top N by various metrics) ───────────────────────────────
    function getTopByPnl(uint256 n, bool weekly) external view returns (
        address[] memory traders, int256[] memory pnls, string[] memory names
    ) {
        return _rankByPnl(n, weekly);
    }

    function getTopByVolume(uint256 n, bool weekly) external view returns (
        address[] memory traders, uint256[] memory volumes, string[] memory names
    ) {
        uint256 count  = allTraders.length < n ? allTraders.length : n;
        traders = new address[](count);
        volumes = new uint256[](count);
        names   = new string[](count);
        // Simple top-N scan (off-chain indexing recommended for production)
        for (uint i; i < count; i++) {
            address best;
            uint256 bestVol;
            for (uint j; j < allTraders.length; j++) {
                TraderStats storage s = stats[allTraders[j]];
                if (!s.isPublic) continue;
                uint256 vol = weekly ? s.weeklyVolume : s.totalVolume;
                bool alreadyPicked;
                for (uint k; k < i; k++) if (traders[k] == allTraders[j]) { alreadyPicked = true; break; }
                if (!alreadyPicked && vol > bestVol) { bestVol = vol; best = allTraders[j]; }
            }
            traders[i] = best;
            volumes[i] = bestVol;
            if (best != address(0)) names[i] = stats[best].displayName;
        }
    }

    function getTopByWinRate(uint256 n) external view returns (
        address[] memory traders, uint256[] memory winRates, string[] memory names
    ) {
        uint256 count = allTraders.length < n ? allTraders.length : n;
        traders  = new address[](count);
        winRates = new uint256[](count);
        names    = new string[](count);
        for (uint i; i < count; i++) {
            address best; uint256 bestWR;
            for (uint j; j < allTraders.length; j++) {
                TraderStats storage s = stats[allTraders[j]];
                if (!s.isPublic || s.totalTrades < 10) continue; // min 10 trades
                uint256 wr = s.winningTrades * 10000 / s.totalTrades;
                bool already;
                for (uint k; k < i; k++) if (traders[k] == allTraders[j]) { already = true; break; }
                if (!already && wr > bestWR) { bestWR = wr; best = allTraders[j]; }
            }
            traders[i]  = best;
            winRates[i] = bestWR;
            if (best != address(0)) names[i] = stats[best].displayName;
        }
    }

    function getTraderProfile(address trader) external view returns (TraderStats memory) {
        return stats[trader];
    }

    function totalTraders() external view returns (uint256) { return allTraders.length; }

    // ── Internal ──────────────────────────────────────────────────────────
    function _rankByPnl(uint256 n, bool weekly) internal view returns (
        address[] memory traders, int256[] memory pnls, string[] memory names
    ) {
        uint256 count = allTraders.length < n ? allTraders.length : n;
        traders = new address[](count);
        pnls    = new int256[](count);
        names   = new string[](count);
        for (uint i; i < count; i++) {
            address best; int256 bestPnl = type(int256).min;
            for (uint j; j < allTraders.length; j++) {
                TraderStats storage s = stats[allTraders[j]];
                if (!s.isPublic) continue;
                int256 pnl = weekly ? s.weeklyPnl : s.totalPnlUsdc;
                bool already;
                for (uint k; k < i; k++) if (traders[k] == allTraders[j]) { already = true; break; }
                if (!already && pnl > bestPnl) { bestPnl = pnl; best = allTraders[j]; }
            }
            traders[i] = best;
            pnls[i]    = bestPnl;
            if (best != address(0)) names[i] = stats[best].displayName;
        }
    }

    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
