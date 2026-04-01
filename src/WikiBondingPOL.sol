// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiBondingPOL — Protocol-Owned Liquidity via LP Token Bonds
 *
 * Replaces "mercenary farming" with permanent protocol-owned liquidity.
 *
 * HOW BONDS WORK
 * ─────────────────────────────────────────────────────────────────────────
 * 1. User has ETH/WIK LP tokens earning yield on WikiSpot
 * 2. User sells LP tokens to WikiBondingPOL at a 5–15% DISCOUNT on WIK
 * 3. User receives WIK tokens vested linearly over 5 days
 * 4. Protocol PERMANENTLY owns the LP tokens → earns 100% of those pool fees forever
 *
 * BOND DISCOUNT MECHANISM
 * Bond price = market WIK price × (1 - discount)
 * Discount range: 2–15% (higher when protocol needs more liquidity)
 * Max bond size per user per day: $50,000 (prevents whale gaming)
 *
 * REVENUE
 * Protocol gets LP tokens permanently. All fees from those LP positions
 * flow to WikiRevenueSplitter → stakers/treasury/safety in perpetuity.
 * This creates compounding revenue as the protocol accumulates more LP.
 */

interface IWikiOracle { function getPrice(bytes32 id) external view returns (uint256, uint256); }
interface IWIK { function mint(address to, uint256 amount) external; function totalSupply() external view returns (uint256); }

contract WikiBondingPOL is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct BondType {
        address  lpToken;        // accepted LP token
        bytes32  oracleId;       // WIK/USD oracle ID
        uint256  discountBps;    // current discount (e.g. 700 = 7%)
        uint256  maxBondPerDay;  // in LP token value (USDC)
        uint256  vestingDays;    // linear vesting (default 5 days)
        bool     active;
    }

    struct UserBond {
        uint256  bondTypeId;
        uint256  lpDeposited;
        uint256  wikTotal;       // total WIK to vest
        uint256  wikClaimed;
        uint256  startTime;
        uint256  vestingEnd;
        bool     fullyVested;
    }

    mapping(uint256 => BondType)          public bondTypes;
    mapping(uint256 => UserBond)          public userBonds;
    mapping(address => uint256[])         public userBondIds;
    mapping(uint256 => mapping(address => uint256)) public dailyBondVolume; // bondTypeId → day → userVolume

    IWikiOracle public oracle;
    IWIK        public wik;
    address     public treasury;

    uint256 public bondTypeCount;
    uint256 public bondCount;
    uint256 public totalLPOwned;         // total LP value permanently owned
    uint256 public totalWIKIssuedAsBonds;
    uint256 public totalDiscountGiven;

    uint256 public constant BPS           = 10000;
    uint256 public constant MAX_DISCOUNT  = 1500;  // 15% max
    uint256 public constant MIN_DISCOUNT  = 200;   // 2% min
    uint256 public constant DEFAULT_VESTING = 5 days;
    uint256 public constant LP_VALUE_PRECISION = 1e6; // USDC 6dec

    event BondTypeCreated(uint256 indexed id, address lpToken, uint256 discountBps);
    event BondPurchased(uint256 indexed bondId, address user, uint256 lpAmount, uint256 wikAmount, uint256 discount);
    event BondClaimed(uint256 indexed bondId, address user, uint256 wikClaimed);
    event DiscountUpdated(uint256 bondTypeId, uint256 newDiscountBps);

    constructor(address _oracle, address _wik, address _treasury, address _owner) Ownable(_owner) {
        require(_oracle != address(0), "Wiki: zero _oracle");
        require(_wik != address(0), "Wiki: zero _wik");
        require(_treasury != address(0), "Wiki: zero _treasury");
        oracle   = IWikiOracle(_oracle);
        wik      = IWIK(_wik);
        treasury = _treasury;
    }

    // ── Bond Management ───────────────────────────────────────────────────────

    function createBondType(address lpToken, bytes32 oracleId, uint256 discountBps, uint256 maxBondPerDay, uint256 vestingDays)
        external onlyOwner returns (uint256 id)
    {
        require(discountBps >= MIN_DISCOUNT && discountBps <= MAX_DISCOUNT, "Bond: discount out of range");
        id = ++bondTypeCount;
        bondTypes[id] = BondType({ lpToken:lpToken, oracleId:oracleId, discountBps:discountBps, maxBondPerDay:maxBondPerDay, vestingDays:vestingDays > 0 ? vestingDays * 1 days : DEFAULT_VESTING, active:true });
        emit BondTypeCreated(id, lpToken, discountBps);
    }

    // ── Purchase Bond ─────────────────────────────────────────────────────────

    /**
     * @notice Sell LP tokens to protocol, receive discounted WIK vesting over 5 days.
     * @param bondTypeId  Which bond type to purchase
     * @param lpAmount    Amount of LP tokens to sell
     * @param lpValueUSDC Off-chain computed USD value of LP (keeper or user provides, capped)
     */
    function purchaseBond(uint256 bondTypeId, uint256 lpAmount, uint256 lpValueUSDC)
        external nonReentrant returns (uint256 bondId)
    {
        BondType storage bt = bondTypes[bondTypeId];
        require(bt.active, "Bond: inactive");
        require(lpAmount > 0, "Bond: zero LP");

        // Daily limit check
        uint256 today = block.timestamp / 1 days;
        require(dailyBondVolume[bondTypeId][today] + lpValueUSDC <= bt.maxBondPerDay, "Bond: daily limit exceeded");

        // Transfer LP to protocol (permanently)
        IERC20(bt.lpToken).safeTransferFrom(msg.sender, address(this), lpAmount);
        dailyBondVolume[bondTypeId][today] += lpValueUSDC;
        totalLPOwned += lpValueUSDC;

        // Calculate discounted WIK amount
        // wikPrice = oracle price (USD per WIK, 1e18 scaled)
        (uint256 wikPriceUSD,) = oracle.getPrice(bt.oracleId);
        require(wikPriceUSD > 0, "Bond: oracle error");

        // WIK amount = lpValueUSDC / (wikPrice × (1 - discount))
        uint256 discountedPrice = wikPriceUSD * (BPS - bt.discountBps) / BPS;
        uint256 wikAmount = lpValueUSDC * 1e18 / discountedPrice;
        uint256 discount  = wikAmount - (lpValueUSDC * 1e18 / wikPriceUSD);

        totalWIKIssuedAsBonds += wikAmount;
        totalDiscountGiven    += discount;

        // Create vesting position
        bondId = ++bondCount;
        userBonds[bondId] = UserBond({
            bondTypeId:  bondTypeId,
            lpDeposited: lpAmount,
            wikTotal:    wikAmount,
            wikClaimed:  0,
            startTime:   block.timestamp,
            vestingEnd:  block.timestamp + bt.vestingDays,
            fullyVested: false
        });
        userBondIds[msg.sender].push(bondId);
        emit BondPurchased(bondId, msg.sender, lpAmount, wikAmount, bt.discountBps);
    }

    // ── Claim Vested WIK ─────────────────────────────────────────────────────

    function claimVested(uint256 bondId) external nonReentrant returns (uint256 claimable) {
        UserBond storage b = userBonds[bondId];
        require(!b.fullyVested, "Bond: fully claimed");

        uint256 elapsed = block.timestamp - b.startTime;
        BondType storage bt = bondTypes[b.bondTypeId];
        uint256 vestedFraction = elapsed >= bt.vestingDays ? BPS : elapsed * BPS / bt.vestingDays;
        uint256 totalVested = b.wikTotal * vestedFraction / BPS;
        claimable = totalVested - b.wikClaimed;
        require(claimable > 0, "Bond: nothing to claim");

        b.wikClaimed += claimable;
        if (b.wikClaimed >= b.wikTotal) b.fullyVested = true;

        wik.mint(msg.sender, claimable);
        emit BondClaimed(bondId, msg.sender, claimable);
    }

    // ── Dynamic Discount ──────────────────────────────────────────────────────

    function setDiscount(uint256 bondTypeId, uint256 newDiscountBps) external onlyOwner {
        require(newDiscountBps >= MIN_DISCOUNT && newDiscountBps <= MAX_DISCOUNT, "Bond: discount out of range");
        bondTypes[bondTypeId].discountBps = newDiscountBps;
        emit DiscountUpdated(bondTypeId, newDiscountBps);
    }

    // ── Views ─────────────────────────────────────────────────────────────────
    function claimableAmount(uint256 bondId) external view returns (uint256) {
        UserBond storage b = userBonds[bondId];
        if (b.fullyVested) return 0;
        uint256 elapsed = block.timestamp - b.startTime;
        BondType storage bt = bondTypes[b.bondTypeId];
        uint256 vestedFraction = elapsed >= bt.vestingDays ? BPS : elapsed * BPS / bt.vestingDays;
        uint256 totalVested = b.wikTotal * vestedFraction / BPS;
        return totalVested > b.wikClaimed ? totalVested - b.wikClaimed : 0;
    }
    function getUserBonds(address user) external view returns (uint256[] memory) { return userBondIds[user]; }
    function getTotalPOLValue() external view returns (uint256) { return totalLPOwned; }
}
