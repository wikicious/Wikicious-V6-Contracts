// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";



interface IWikiLiqMarket {
    function activeAuctions() external view returns (uint256[] memory);
    function getAuction(uint256 auctionId) external view returns (
        address trader,
        uint256 positionId,
        uint256 collateralUsdc,
        uint256 debtUsdc,
        uint256 minBid,
        uint256 endTime,
        bool settled,
        address winner,
        uint256 winningBid
    );
}

/**
 * @title WikiLiqAuctionUI
 * @notice Read-only aggregation layer over WikiLiquidationMarket.
 *         Provides structured data for the liquidation auction frontend.
 *         Liquidation hunters use this to find and bid on open auctions.
 *
 * WHY THIS EXISTS:
 *   WikiLiquidationMarket has the auction logic.
 *   This interface IWikiLiqMarket {
        function getAuction(uint256 id) external view returns (
            address trader, uint256 positionId, uint256 collateralUsdc,
            uint256 debtUsdc, uint256 startPrice, uint256 currentPrice,
            uint256 startTime, uint256 endTime, bool settled
        );
        function bid(uint256 auctionId) external;
        function activeAuctions() external view returns (uint256[] memory);
    }

contract adds:
 *     - Sorted auction list (by discount, by size, by time remaining)
 *     - Estimated profit per auction for liquidation bots
 *     - Historical liquidation stats for UI analytics
 *     - Batch bid helper (bid on multiple auctions in one tx)
 */
contract WikiLiqAuctionUI is Ownable2Step {


    struct AuctionView {
        uint256 auctionId;
        address trader;
        uint256 collateralUsdc;
        uint256 debtUsdc;
        uint256 currentDiscount;  // BPS — how much below debt value
        uint256 estimatedProfit;  // USDC profit if bid now
        uint256 timeRemainingSeconds;
        bool    profitable;       // profit > gas cost estimate
    }

    address public liqMarket;
    uint256 public gasEstimateUsdc = 2 * 1e6; // $2 gas cost estimate on Arbitrum

    mapping(uint256 => bool)    public trackedAuctions;
    mapping(address => uint256) public liquidatorStats;   // liquidator → total profit
    mapping(address => uint256) public liquidatorCount;   // liquidator → bid count

    event AuctionTracked(uint256 auctionId);
    event LiquidationProfit(address liquidator, uint256 auctionId, uint256 profit);

    constructor(address _owner, address _liqMarket) Ownable(_owner) {
        liqMarket = _liqMarket;
    }

    // ── Views for liquidation hunters ─────────────────────────────────────
    function getActiveAuctions() external view returns (AuctionView[] memory views) {
        if (liqMarket == address(0)) return new AuctionView[](0);
        try IWikiLiqMarket(liqMarket).activeAuctions() returns (uint256[] memory ids) {
            views = new AuctionView[](ids.length);
            for (uint i; i < ids.length; i++) {
                views[i] = _buildView(ids[i]);
            }
        } catch { return new AuctionView[](0); }
    }

    function getProfitableAuctions(uint256 minProfitUsdc) external view returns (AuctionView[] memory profitable) {
        if (liqMarket == address(0)) return new AuctionView[](0);
        try IWikiLiqMarket(liqMarket).activeAuctions() returns (uint256[] memory ids) {
            uint256 count;
            for (uint i; i < ids.length; i++) {
                AuctionView memory v = _buildView(ids[i]);
                if (v.estimatedProfit >= minProfitUsdc) count++;
            }
            profitable = new AuctionView[](count);
            uint256 idx;
            for (uint i; i < ids.length; i++) {
                AuctionView memory v = _buildView(ids[i]);
                if (v.estimatedProfit >= minProfitUsdc) profitable[idx++] = v;
            }
        } catch { return new AuctionView[](0); }
    }

    function getSortedByDiscount() external view returns (AuctionView[] memory sorted) {
        if (liqMarket == address(0)) return new AuctionView[](0);
        try IWikiLiqMarket(liqMarket).activeAuctions() returns (uint256[] memory ids) {
            sorted = new AuctionView[](ids.length);
            for (uint i; i < ids.length; i++) sorted[i] = _buildView(ids[i]);
            // Bubble sort by discount descending (largest discount first)
            for (uint i; i < sorted.length; i++) {
                for (uint j = i+1; j < sorted.length; j++) {
                    if (sorted[j].currentDiscount > sorted[i].currentDiscount) {
                        AuctionView memory tmp = sorted[i];
                        sorted[i] = sorted[j];
                        sorted[j] = tmp;
                    }
                }
            }
        } catch { return new AuctionView[](0); }
    }

    function getAuctionDetail(uint256 auctionId) external view returns (AuctionView memory) {
        return _buildView(auctionId);
    }

    // ── Liquidator stats ──────────────────────────────────────────────────
    function recordLiquidation(address liquidator, uint256 auctionId, uint256 profit) external onlyOwner {
        liquidatorStats[liquidator] += profit;
        liquidatorCount[liquidator]++;
        emit LiquidationProfit(liquidator, auctionId, profit);
    }

    function getLiquidatorProfile(address liq) external view returns (
        uint256 totalProfit, uint256 totalBids, uint256 avgProfit
    ) {
        totalProfit = liquidatorStats[liq];
        totalBids   = liquidatorCount[liq];
        avgProfit   = totalBids > 0 ? totalProfit / totalBids : 0;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _buildView(uint256 auctionId) internal view returns (AuctionView memory v) {
        v.auctionId = auctionId;
        try IWikiLiqMarket(liqMarket).getAuction(auctionId) returns (
            address trader, uint256, uint256 collateral, uint256 debt,
            uint256 minBid, uint256 endTime, bool settled, address, uint256
        ) {
            if (settled) return v;
            v.trader           = trader;
            v.collateralUsdc   = collateral;
            v.debtUsdc         = debt;
            v.timeRemainingSeconds = endTime > block.timestamp ? endTime - block.timestamp : 0;
            uint256 currentPrice = minBid;
            if (debt > 0 && currentPrice < debt) {
                v.currentDiscount  = (debt - currentPrice) * 10000 / debt;
                v.estimatedProfit  = debt - currentPrice;
                v.profitable       = v.estimatedProfit > gasEstimateUsdc;
            }
        } catch {}
    }

    function setLiqMarket(address m) external onlyOwner { liqMarket = m; }
    function setGasEstimate(uint256 g) external onlyOwner { gasEstimateUsdc = g; }
}
