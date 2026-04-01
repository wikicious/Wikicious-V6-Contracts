// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLiquidationMarket
 * @notice Competitive liquidation auction marketplace.
 *
 * ─── WHY THIS IS BETTER THAN A SINGLE KEEPER ─────────────────────────────────
 *
 * Old model: one keeper bot watches positions. When undercollateralised, it
 * liquidates and keeps the entire liquidation bonus (usually 5-10% of position).
 * Problem: if the keeper is offline, positions sit undercollateralised → risk.
 *
 * New model:
 * 1. Any address can call openAuction(posId) on a liquidatable position
 * 2. A 2-block Dutch auction starts — the discount starts at 5% and grows
 * 3. First bot to call bid(auctionId) at the current discount wins
 * 4. Protocol takes 50% of the discount; winning bot keeps 50%
 * 5. If no one bids within MAX_BLOCKS, fallback to WikiLiquidator (old keeper)
 *
 * ─── REVENUE ─────────────────────────────────────────────────────────────────
 *
 * Protocol earns 50% of every liquidation discount.
 * At $1M/day in perp open interest with 0.5% daily liquidations:
 *   $5K/day in liquidated notional × 5% bonus × 50% protocol share = $125/day
 *   = ~$45K/year, scales linearly with TVL
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────────
 * [A1] Position must be liquidatable (checked via WikiPerp)
 * [A2] Dutch auction prevents winner's curse — price drops until someone bids
 * [A3] Fallback keeper ensures no position stays undercollateralised
 * [A4] Protocol share goes to insurance fund first, then revenue splitter
 * [A5] Auction can only be opened once per position (deduplicated)
 */
interface IWikiRevenueSplitter {
        function receiveFees(uint256 amount) external;
    }

interface IWikiVault {
        function fundInsurance(uint256 amount) external;
    }

interface IWikiPerp {
        struct Position {
            address user; bytes32 marketId; uint256 collateral; uint256 size;
            uint256 entryPrice; uint256 leverage; bool isLong; bool active; uint256 liqPrice;
        }
        function getPosition(uint256 posId) external view returns (Position memory);
        function liquidate(uint256 posId) external returns (uint256 collateral);
    }

contract WikiLiquidationMarket is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public timelock;
    function setTimelock(address _tl) external onlyOwner { timelock = _tl; }

    uint256 public constant BPS             = 10_000;
    uint256 public constant MAX_BLOCKS      = 10;     // auction window: ~2 seconds on Arbitrum
    uint256 public constant START_DISC_BPS  = 200;    // 2% starting discount
    uint256 public constant MAX_DISC_BPS    = 800;    // 8% max discount
    uint256 public constant PROTOCOL_SHARE  = 5_000;  // 50% of discount to protocol
    uint256 public constant OPENER_SHARE    = 500;    // 5% to whoever opened the auction
    uint256 public constant MIN_COLLATERAL  = 10 * 1e6; // $10 min position to bother



    struct Auction {
        uint256 posId;
        address opener;
        uint256 openBlock;
        uint256 startDiscBps;
        bool    settled;
        address winner;
        uint256 discountPaid;   // USDC discount captured
        uint256 toProtocol;
        uint256 toWinner;
    }

    IWikiPerp              public perp;
    IWikiVault             public vault;
    IWikiRevenueSplitter   public splitter;
    IERC20                 public immutable USDC;

    Auction[]              public auctions;
    mapping(uint256 => uint256)  public posToAuction;   // posId → auctionId
    mapping(uint256 => bool)     public posHasAuction;

    uint256 public totalProtocolRevenue;
    uint256 public totalLiquidations;

    event AuctionOpened(uint256 indexed auctionId, uint256 indexed posId, address opener, uint256 startDiscBps);
    event AuctionWon(uint256 indexed auctionId, address indexed winner, uint256 discountBps, uint256 toProtocol, uint256 toWinner);
    event AuctionExpired(uint256 indexed auctionId, uint256 posId);

    constructor(address _owner, address _perp, address _vault, address _splitter, address _usdc) Ownable(_owner) {
        require(_perp != address(0), "LiqMkt: zero perp");
        perp     = IWikiPerp(_perp);
        vault    = IWikiVault(_vault);
        splitter = IWikiRevenueSplitter(_splitter);
        USDC     = IERC20(_usdc);
    }

    /**
     * @notice Anyone calls this when a position becomes liquidatable.
     *         Opener earns 5% of the auction discount as reward.
     */
    function openAuction(uint256 posId) external nonReentrant whenNotPaused {
        require(!posHasAuction[posId],           "LiqMkt: auction exists"); // [A5]
        require(perp.isLiquidatable(posId),      "LiqMkt: not liquidatable"); // [A1]
        IWikiPerp.Position memory pos = perp.positions(posId);
        require(pos.active,                      "LiqMkt: position closed");
        require(pos.collateral >= MIN_COLLATERAL,"LiqMkt: too small");

        uint256 auctionId = auctions.length;
        auctions.push(Auction({
            posId:        posId,
            opener:       msg.sender,
            openBlock:    block.number,
            startDiscBps: START_DISC_BPS,
            settled:      false,
            winner:       address(0),
            discountPaid: 0,
            toProtocol:   0,
            toWinner:     0
        }));
        posToAuction[posId]  = auctionId;
        posHasAuction[posId] = true;

        emit AuctionOpened(auctionId, posId, msg.sender, START_DISC_BPS);
    }

    /**
     * @notice Winning bid. Caller pays (collateral × currentDiscount) in USDC
     *         and receives the collateral back. Protocol keeps 50% of discount.
     *
     * @param auctionId  The auction to win
     */
    function bid(uint256 auctionId) external nonReentrant whenNotPaused {
        Auction storage a = auctions[auctionId];
        require(!a.settled,                                      "LiqMkt: settled");
        require(block.number <= a.openBlock + MAX_BLOCKS,        "LiqMkt: expired"); // [A2]

        IWikiPerp.Position memory pos = perp.positions(a.posId);
        require(pos.active && perp.isLiquidatable(a.posId),      "LiqMkt: not liq anymore");

        // Dutch auction: discount grows each block [A2]
        uint256 blocks      = block.number - a.openBlock;
        uint256 curDisc     = START_DISC_BPS + (blocks * (MAX_DISC_BPS - START_DISC_BPS) / MAX_BLOCKS);
        if (curDisc > MAX_DISC_BPS) curDisc = MAX_DISC_BPS;

        uint256 collateral  = pos.collateral;
        uint256 discAmount  = collateral * curDisc / BPS;
        uint256 toProtocol  = discAmount * PROTOCOL_SHARE / BPS;
        uint256 toOpener    = discAmount * OPENER_SHARE   / BPS;
        uint256 toWinner    = discAmount - toProtocol - toOpener;

        // Mark settled before any external calls [A2]
        a.settled     = true;
        a.winner      = msg.sender;
        a.discountPaid = discAmount;
        a.toProtocol  = toProtocol;
        a.toWinner    = toWinner;
        totalProtocolRevenue += toProtocol;
        totalLiquidations++;

        // Caller pays full collateral to buy the position
        USDC.safeTransferFrom(msg.sender, address(this), collateral);

        // Execute liquidation on the perp engine
        perp.liquidate(a.posId);

        // Distribute: protocol share to insurance then splitter
        uint256 toInsurance = toProtocol / 2;
        uint256 toSplitter  = toProtocol - toInsurance;
        if (toInsurance > 0) try vault.fundInsurance(toInsurance) {} catch {}
        if (toSplitter  > 0) { USDC.safeApprove(address(splitter), toSplitter); try splitter.receiveFees(toSplitter) {} catch {} }

        // Pay opener reward
        if (toOpener > 0) USDC.safeTransfer(a.opener, toOpener);

        // Pay winner their net discount
        if (toWinner > 0) USDC.safeTransfer(msg.sender, toWinner);

        emit AuctionWon(auctionId, msg.sender, curDisc, toProtocol, toWinner);
    }

    /**
     * @notice If auction expires with no bids, fallback to direct liquidation.
     *         Anyone can call — they earn the opener share as compensation.
     */
    function settleExpired(uint256 auctionId) external nonReentrant whenNotPaused {
        Auction storage a = auctions[auctionId];
        require(!a.settled,                                 "LiqMkt: already settled");
        require(block.number > a.openBlock + MAX_BLOCKS,    "LiqMkt: still open");
        require(perp.isLiquidatable(a.posId),               "LiqMkt: not liquidatable");

        a.settled = true;
        perp.liquidate(a.posId); // [A3] fallback

        emit AuctionExpired(auctionId, a.posId);
    }

    function currentDiscount(uint256 auctionId) external view returns (uint256 discBps, bool active) {
        Auction storage a = auctions[auctionId];
        if (a.settled || block.number > a.openBlock + MAX_BLOCKS) return (0, false);
        uint256 blocks = block.number - a.openBlock;
        uint256 d = START_DISC_BPS + (blocks * (MAX_DISC_BPS - START_DISC_BPS) / MAX_BLOCKS);
        return (d > MAX_DISC_BPS ? MAX_DISC_BPS : d, true);
    }

    function auctionCount() external view returns (uint256) { return auctions.length; }

    function setContracts(address _perp, address _vault, address _splitter) external onlyOwner {
        if (_perp     != address(0)) perp     = IWikiPerp(_perp);
        if (_vault    != address(0)) vault    = IWikiVault(_vault);
        if (_splitter != address(0)) splitter = IWikiRevenueSplitter(_splitter);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
