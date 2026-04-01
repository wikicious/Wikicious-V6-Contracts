// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiVestingMarket
 * @notice P2P marketplace for locked/vesting WIK tokens.
 *         Sellers: team/investors with locked WIK who need liquidity now.
 *         Buyers: want WIK at a discount and willing to wait for unlock.
 *         Protocol: earns 2% fee on every transaction.
 *
 * MECHANICS:
 *   Seller lists vesting position: "I have 1M WIK unlocking in 6 months.
 *   I'll sell it for 80 cents on the dollar (20% discount) right now."
 *
 *   Buyer pays 800,000 USDC now.
 *   Seller gets 800,000 USDC immediately (minus 2% fee).
 *   In 6 months, buyer claims 1,000,000 WIK from vesting contract.
 *
 * BENEFITS:
 *   Sellers: liquidity without dumping on spot market
 *   Buyers:  WIK at a discount vs spot price
 *   Protocol:2% fee + reduced WIK sell pressure = higher WIK price
 *
 * RISK:
 *   Buyer risk: WIK price drops below purchase price
 *   Mitigated by: discount provides buffer; buyer chooses discount %
 */
interface IWikiTokenVesting {
        function transferBeneficiary(uint256 scheduleId, address newBeneficiary) external;
        function getSchedule(uint256 scheduleId) external view returns (
            address beneficiary, uint256 totalAmount, uint256 vestedAmount,
            uint256 claimedAmount, uint256 startTime, uint256 cliffEnd, uint256 endTime
        );
    }

contract WikiVestingMarket is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;


    IERC20 public immutable USDC;
    IERC20 public immutable WIK;
    IWikiTokenVesting public vestingContract;

    struct Listing {
        address  seller;
        uint256  vestingScheduleId;
        uint256  wikAmount;         // total WIK in the schedule
        uint256  remainingWIK;      // unvested WIK remaining
        uint256  askPriceUsdc;      // seller's asking price for all remaining WIK
        uint256  discountBps;       // discount vs spot price (e.g. 2000 = 20% off)
        uint256  unlockTimestamp;   // when WIK unlocks
        bool     active;
        uint256  createdAt;
        uint256  expiresAt;
    }

    mapping(uint256 => Listing)      public listings;
    mapping(address => uint256[])    public sellerListings;
    mapping(address => uint256[])    public buyerPurchases; // buyer → listing IDs they bought

    uint256 public nextListingId;
    uint256 public protocolFeeBps = 200; // 2%
    uint256 public constant BPS   = 10_000;
    address public feeTreasury;

    event Listed(uint256 listingId, address seller, uint256 wikAmount, uint256 askPrice, uint256 discount);
    event Sold(uint256 listingId, address buyer, uint256 wikAmount, uint256 pricePaid, uint256 fee);
    event ListingCancelled(uint256 listingId, address seller);

    constructor(address _owner, address _usdc, address _wik, address _vesting, address _treasury) Ownable(_owner) {
        USDC            = IERC20(_usdc);
        WIK             = IERC20(_wik);
        vestingContract = IWikiTokenVesting(_vesting);
        feeTreasury     = _treasury;
    }

    // ── List vesting position ─────────────────────────────────────────────
    function listVestingSchedule(
        uint256 scheduleId,
        uint256 askPriceUsdc,
        uint256 discountBps,
        uint256 expiryDays
    ) external nonReentrant returns (uint256 listingId) {
        require(discountBps >= 500 && discountBps <= 5000, "VM: discount 5-50%");

        // Verify seller owns this schedule
        (address beneficiary, uint256 total,, uint256 claimed,, , uint256 endTime) =
            vestingContract.getSchedule(scheduleId);
        require(beneficiary == msg.sender, "VM: not your schedule");
        uint256 remaining = total - claimed;
        require(remaining > 0, "VM: nothing remaining");

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller:            msg.sender,
            vestingScheduleId: scheduleId,
            wikAmount:         total,
            remainingWIK:      remaining,
            askPriceUsdc:      askPriceUsdc,
            discountBps:       discountBps,
            unlockTimestamp:   endTime,
            active:            true,
            createdAt:         block.timestamp,
            expiresAt:         block.timestamp + expiryDays * 1 days
        });
        sellerListings[msg.sender].push(listingId);
        emit Listed(listingId, msg.sender, remaining, askPriceUsdc, discountBps);
    }

    // ── Buy listing ───────────────────────────────────────────────────────
    function buyListing(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active,                             "VM: not active");
        require(block.timestamp <= l.expiresAt,       "VM: expired");
        require(msg.sender != l.seller,               "VM: cannot buy own listing");

        uint256 price     = l.askPriceUsdc;
        uint256 fee       = price * protocolFeeBps / BPS;
        uint256 netToSeller = price - fee;

        // Transfer USDC: buyer → seller + fee
        USDC.safeTransferFrom(msg.sender, l.seller,   netToSeller);
        USDC.safeTransferFrom(msg.sender, feeTreasury, fee);

        // Transfer vesting schedule beneficiary to buyer
        // Buyer will claim WIK directly from vesting contract on unlock
        vestingContract.transferBeneficiary(l.vestingScheduleId, msg.sender);

        l.active = false;
        buyerPurchases[msg.sender].push(listingId);

        emit Sold(listingId, msg.sender, l.remainingWIK, price, fee);
    }

    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.seller == msg.sender, "VM: not seller");
        require(l.active,               "VM: not active");
        l.active = false;
        emit ListingCancelled(listingId, msg.sender);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getActiveListings(uint256 offset, uint256 limit) external view returns (Listing[] memory result) {
        uint256 total = nextListingId;
        uint256 count;
        for (uint i = offset; i < total && count < limit; i++) {
            if (listings[i].active && block.timestamp <= listings[i].expiresAt) count++;
        }
        result = new Listing[](count);
        uint256 idx;
        for (uint i = offset; i < total && idx < count; i++) {
            if (listings[i].active && block.timestamp <= listings[i].expiresAt) result[idx++] = listings[i];
        }
    }

    function getImpliedWIKPrice(uint256 listingId) external view returns (uint256 pricePerWIK) {
        Listing storage l = listings[listingId];
        if (l.remainingWIK == 0) return 0;
        return l.askPriceUsdc * 1e18 / l.remainingWIK; // USDC per WIK (6 dec / 18 dec → scale)
    }

    function getMyListings(address seller) external view returns (uint256[] memory) { return sellerListings[seller]; }
    function getMyPurchases(address buyer) external view returns (uint256[] memory)  { return buyerPurchases[buyer]; }
    function setProtocolFee(uint256 bps) external onlyOwner { require(bps <= 500); protocolFeeBps = bps; }
    function setTreasury(address t) external onlyOwner { feeTreasury = t; }
}
