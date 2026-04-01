// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiStakingFeeDiscount
 * @notice Stake WIK → pay lower trading fees.
 *         Binance BNB works exactly this way. Creates constant WIK buy pressure.
 *
 * DISCOUNT TIERS:
 *   No WIK staked:    0% discount (standard fees)
 *   100 WIK staked:   10% discount
 *   1,000 WIK staked: 20% discount
 *   10,000 WIK staked:30% discount
 *   100,000 WIK staked:40% discount
 *
 * WHY THIS MULTIPLIES LIQUIDITY AND REVENUE:
 *   Active traders stake WIK to save on fees
 *   → Constant buy pressure on WIK
 *   → WIK price rises
 *   → LP rewards in WIK worth more
 *   → More LPs attracted
 *   → Deeper order books
 *   → Better fills
 *   → More traders choose Wikicious
 *   → More fees
 *   → Higher natural APY for stakers
 *   → More staking
 *   → Full flywheel
 *
 * BREAK-EVEN FOR TRADER:
 *   At 20% discount, trader paying $1,000/month in fees saves $200/month.
 *   1,000 WIK at $1 = $1,000 staked. Payback in 5 months.
 *   After 5 months: pure savings forever.
 *   Result: traders are financially incentivised to hold and stake WIK.
 */
contract WikiStakingFeeDiscount is Ownable2Step {
    IERC20 public immutable veWIK;  // uses veWIK balance (already staked WIK)

    struct DiscountTier {
        uint256 minVeWIK;       // minimum veWIK balance to qualify
        uint256 discountBps;    // fee discount in BPS (e.g. 1000 = 10%)
        string  tierName;
    }

    DiscountTier[] public tiers;

    mapping(address => uint256) public lifetimeFeesSaved;  // tracking
    mapping(address => bool)    public recorders;

    uint256 public constant MAX_DISCOUNT_BPS = 4000; // 40% max
    uint256 public constant BPS              = 10000;

    event FeeDiscountApplied(address indexed trader, uint256 discountBps, uint256 savedUsdc);

    constructor(address _owner, address _veWIK) Ownable(_owner) {
        veWIK = IERC20(_veWIK);
        recorders[_owner] = true;
        _initTiers();
    }

    function _initTiers() internal {
        tiers.push(DiscountTier({ minVeWIK: 0,          discountBps: 0,    tierName: "Standard"    }));
        tiers.push(DiscountTier({ minVeWIK: 100e18,     discountBps: 1000, tierName: "Bronze"      }));
        tiers.push(DiscountTier({ minVeWIK: 1_000e18,   discountBps: 2000, tierName: "Silver"      }));
        tiers.push(DiscountTier({ minVeWIK: 10_000e18,  discountBps: 3000, tierName: "Gold"        }));
        tiers.push(DiscountTier({ minVeWIK: 100_000e18, discountBps: 4000, tierName: "Diamond"     }));
    }

    // ── Get discount for a trader ─────────────────────────────────────────
    function getDiscountBps(address trader) public view returns (uint256 discountBps, string memory tierName) {
        uint256 veBal = veWIK.balanceOf(trader);
        uint256 bestDiscount;
        string memory bestTier = "Standard";
        for (uint i; i < tiers.length; i++) {
            if (veBal >= tiers[i].minVeWIK && tiers[i].discountBps >= bestDiscount) {
                bestDiscount = tiers[i].discountBps;
                bestTier     = tiers[i].tierName;
            }
        }
        return (bestDiscount, bestTier);
    }

    // ── Apply discount to a fee amount (called by WikiPerp/WikiSpot) ──────
    function applyDiscount(address trader, uint256 baseFee) external returns (uint256 discountedFee, uint256 saved) {
        require(recorders[msg.sender], "FD: not recorder");
        (uint256 discountBps,) = getDiscountBps(trader);
        if (discountBps == 0) return (baseFee, 0);
        saved          = baseFee * discountBps / BPS;
        discountedFee  = baseFee - saved;
        lifetimeFeesSaved[trader] += saved;
        emit FeeDiscountApplied(trader, discountBps, saved);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getTraderStatus(address trader) external view returns (
        uint256 veWIKBalance,
        uint256 discountBps,
        string  memory tierName,
        uint256 nextTierMinVeWIK,
        uint256 nextTierDiscountBps,
        uint256 lifetimeSaved
    ) {
        veWIKBalance = veWIK.balanceOf(trader);
        (discountBps, tierName) = getDiscountBps(trader);
        lifetimeSaved = lifetimeFeesSaved[trader];

        // Find next tier
        for (uint i; i < tiers.length; i++) {
            if (tiers[i].minVeWIK > veWIKBalance) {
                nextTierMinVeWIK     = tiers[i].minVeWIK;
                nextTierDiscountBps  = tiers[i].discountBps;
                break;
            }
        }
    }

    function estimateMonthlySavings(address trader, uint256 monthlyFeeUsdc)
        external view returns (uint256 savingsUsdc, uint256 paybackMonthsAt1USD)
    {
        (uint256 disc,) = getDiscountBps(trader);
        savingsUsdc = monthlyFeeUsdc * disc / BPS;
        uint256 veWIKBal = veWIK.balanceOf(trader);
        // Assume $1 per WIK for payback calc (frontend passes real price)
        paybackMonthsAt1USD = savingsUsdc > 0 ? (veWIKBal / 1e18) / (savingsUsdc / 1e6) : 0;
    }

    function getAllTiers() external view returns (DiscountTier[] memory) { return tiers; }
    function setTier(uint256 idx, uint256 minVeWIK, uint256 discBps, string calldata name) external onlyOwner {
        require(discBps <= MAX_DISCOUNT_BPS, "FD: exceeds max");
        if (idx < tiers.length) {
            tiers[idx] = DiscountTier({ minVeWIK: minVeWIK, discountBps: discBps, tierName: name });
        } else {
            tiers.push(DiscountTier({ minVeWIK: minVeWIK, discountBps: discBps, tierName: name }));
        }
    }
    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
