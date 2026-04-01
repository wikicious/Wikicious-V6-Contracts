// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiTradeHistory
 * @notice On-chain trade history registry. Powers tax export and analytics.
 *         Traders cannot leave a platform where their complete history lives.
 *         Compatible with Koinly, CoinTracker, TokenTax CSV formats.
 */
contract WikiTradeHistory is Ownable2Step {

    struct TradeRecord {
        uint256 id;
        address trader;
        uint256 timestamp;
        uint256 marketId;
        string  marketSymbol;   // "BTC/USD", "EUR/USD"
        bool    isLong;
        uint256 entryPrice;     // 8 dec
        uint256 exitPrice;      // 8 dec
        uint256 size;           // notional USDC (6 dec)
        uint256 leverage;
        int256  pnl;            // net P&L after fees (6 dec)
        uint256 fee;            // fee paid (6 dec)
        uint256 fundingPaid;    // funding paid/received (6 dec)
        string  tradeType;      // "PERP", "SPOT", "OPTIONS", "PROP"
        bool    isLiquidation;
    }

    struct TaxSummary {
        int256  totalPnl;
        uint256 totalFees;
        uint256 totalFunding;
        uint256 totalTrades;
        uint256 winCount;
        uint256 lossCount;
        int256  shortTermGains; // < 1 year
        int256  longTermGains;  // > 1 year (where applicable)
    }

    mapping(address => TradeRecord[]) public tradeHistory;
    mapping(address => TaxSummary)    public taxSummary;
    mapping(address => bool)          public recorders;

    uint256 public nextTradeId;
    uint256 public constant MAX_HISTORY = 10_000; // per trader on-chain

    event TradeRecorded(address indexed trader, uint256 tradeId, int256 pnl);

    constructor(address _owner) Ownable(_owner) { recorders[_owner] = true; }

    // ── Record trade (called by all trading contracts) ────────────────────
    function recordTrade(
        address trader,
        uint256 marketId,
        string  calldata symbol,
        bool    isLong,
        uint256 entryPrice,
        uint256 exitPrice,
        uint256 size,
        uint256 leverage,
        int256  pnl,
        uint256 fee,
        uint256 fundingPaid,
        string  calldata tradeType,
        bool    isLiquidation
    ) external returns (uint256 tradeId) {
        require(recorders[msg.sender], "TH: not recorder");

        tradeId = nextTradeId++;
        TradeRecord memory r = TradeRecord({
            id: tradeId, trader: trader,
            timestamp: block.timestamp, marketId: marketId,
            marketSymbol: symbol, isLong: isLong,
            entryPrice: entryPrice, exitPrice: exitPrice,
            size: size, leverage: leverage, pnl: pnl,
            fee: fee, fundingPaid: fundingPaid,
            tradeType: tradeType, isLiquidation: isLiquidation
        });

        // Keep last MAX_HISTORY trades on-chain; older ones emit events only
        if (tradeHistory[trader].length < MAX_HISTORY) {
            tradeHistory[trader].push(r);
        } else {
            // Overwrite oldest (ring buffer)
            uint256 idx = tradeId % MAX_HISTORY;
            tradeHistory[trader][idx] = r;
        }

        // Update tax summary
        TaxSummary storage ts = taxSummary[trader];
        ts.totalPnl     += pnl;
        ts.totalFees    += fee;
        ts.totalFunding += fundingPaid;
        ts.totalTrades++;
        if (pnl > 0) ts.winCount++; else ts.lossCount++;

        emit TradeRecorded(trader, tradeId, pnl);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getTradeHistory(address trader, uint256 offset, uint256 limit)
        external view returns (TradeRecord[] memory records)
    {
        TradeRecord[] storage all = tradeHistory[trader];
        uint256 total = all.length;
        if (offset >= total) return new TradeRecord[](0);
        uint256 end   = offset + limit > total ? total : offset + limit;
        records = new TradeRecord[](end - offset);
        for (uint i = offset; i < end; i++) records[i - offset] = all[i];
    }

    function getTaxSummary(address trader) external view returns (TaxSummary memory) {
        return taxSummary[trader];
    }

    // Returns data formatted for Koinly/CoinTracker CSV generation (off-chain)
    function getTradesForTaxExport(address trader, uint256 yearStart, uint256 yearEnd)
        external view returns (TradeRecord[] memory records)
    {
        TradeRecord[] storage all = tradeHistory[trader];
        uint256 count;
        for (uint i; i < all.length; i++) {
            if (all[i].timestamp >= yearStart && all[i].timestamp <= yearEnd) count++;
        }
        records = new TradeRecord[](count);
        uint256 idx;
        for (uint i; i < all.length; i++) {
            if (all[i].timestamp >= yearStart && all[i].timestamp <= yearEnd) {
                records[idx++] = all[i];
            }
        }
    }

    function getTotalTrades(address trader) external view returns (uint256) { return tradeHistory[trader].length; }
    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
