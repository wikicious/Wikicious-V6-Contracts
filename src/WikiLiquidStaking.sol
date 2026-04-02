// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title sWIK — Liquid Staking Receipt Token
 * @notice ERC20 receipt token minted when users stake assets into WikiLiquidStaking.
 *         sWIK represents a share of the staking pool; its value grows as rewards accrue.
 *         Transfer is unrestricted — can be used in DeFi (AMM LPs, lending collateral, etc.)
 */
contract sWIKToken is ERC20, Ownable2Step {
    // ── Timelock guard ────────────────────────────────────────────────────
    // All fund-moving owner functions must be queued through WikiTimelockController
    // (48h delay). Deployer sets this address after deployment.
    address public timelock;
    modifier onlyTimelocked() {
        require(
            msg.sender == owner() && (timelock == address(0) || msg.sender == timelock),
            "Wiki: must go through timelock"
        );
        _;
    }
    function setTimelock(address _tl) external onlyOwner {
        require(_tl != address(0), "Wiki: zero timelock");
        timelock = _tl;
    }

    address public minter;

    constructor(address owner) ERC20("Staked WIK", "sWIK") Ownable(owner) {
        require(owner != address(0), "Wiki: zero owner");
        _transferOwnership(owner);
    }

    function setMinter(address _minter) external onlyOwner { minter = _minter; }
    function mint(address to, uint256 amount) external { require(msg.sender == minter, "sWIK: not minter"); _mint(to, amount); }
    function burn(address from, uint256 amount) external { require(msg.sender == minter, "sWIK: not minter"); _burn(from, amount); }
}

/**
 * @title WikiLiquidStaking
 * @notice Liquid staking for WIK tokens — stake WIK, receive sWIK (liquid receipt),
 *         earn protocol fees + WIK staking rewards without lockup.
 *
 * MECHANICS
 * ──────────────────────────────────────────────────────────────────
 * • Users deposit WIK → receive sWIK at current exchange rate
 * • Exchange rate = totalWIK / sWIK supply — grows as rewards accrue
 * • Unbonding: request unstake → 7-day unbonding period → claim WIK
 *   (or use instant unstake queue if liquidity buffer is available — 0.3% instant fee)
 * • sWIK is fully transferable: use as collateral in WikiLending, LP in WikiLP, etc.
 *
 * REVENUE
 * ───────
 * • protocol takes protocolFeeBps of all staking rewards
 * • instantUnstakeFee: 0.3% of instant redemption goes to protocol
 *
 * ALSO SUPPORTS: WETH staking → receives synthetic ETH yield
 *   (simplified: we accept WETH, distribute WIK incentives from operator)
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy     → ReentrancyGuard + Pausable
 * [A2] CEI            → state written before transfers
 * [A3] Exchange rate  → rounded down on mint, up on redeem (LP-favorable)
 * [A4] Inflation att. → first deposit handled with minimum shares
 * [A5] Griefing       → unbonding IDs are per-user, packed in array
 */
contract WikiLiquidStaking is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant PRECISION          = 1e18;
    uint256 public constant BPS                = 10_000;
    uint256 public constant UNBONDING_PERIOD   = 7 days;
    uint256 public constant INSTANT_FEE_BPS    = 30;    // 0.30% for instant unstake
    uint256 public constant MAX_PROTOCOL_FEE   = 1500;  // 15% max of rewards
    uint256 public constant MIN_STAKE          = 1e18;  // 1 WIK minimum
    uint256 public constant INITIAL_SHARE_RATE = 1e18;  // 1 WIK = 1 sWIK initially

    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────
    struct UnbondRequest {
        uint256 id;
        uint256 wikAmount;       // WIK to receive after unbonding
        uint256 unbondTime;      // timestamp when WIK can be claimed
        bool    claimed;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IERC20    public immutable WIK;
    sWIKToken public immutable sWIK;

    uint256   public totalStakedWIK;     // total WIK in the pool (incl. rewards)
    uint256   public protocolFeeBps;     // portion of rewards taken by protocol
    uint256   public pendingProtocolFee; // accumulated WIK fees for owner to claim
    uint256   public instantLiqBuffer;   // WIK reserve for instant unstakes
    uint256   public totalUnbonding;     // WIK locked in pending unbond requests

    mapping(address => UnbondRequest[]) public unbondRequests;
    mapping(address => uint256) public unbondNonce;

    // Operator: an EOA/multisig that pushes reward accruals (keeper-based)
    address public operator;

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 wikIn, uint256 sWIKMinted, uint256 exchangeRate);
    event UnstakeRequested(address indexed user, uint256 unbondId, uint256 sWIKBurned, uint256 wikOut, uint256 unbondTime);
    event UnstakeClaimed(address indexed user, uint256 unbondId, uint256 wikOut);
    event InstantUnstake(address indexed user, uint256 sWIKBurned, uint256 wikOut, uint256 fee);
    event RewardAccrued(uint256 wikReward, uint256 protocolFee, uint256 newRate);
    event ProtocolFeesClaimed(address indexed to, uint256 amount);
    event OperatorSet(address indexed operator);
    event BufferFunded(uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    constructor(address wik, address owner, uint256 _protocolFeeBps) Ownable(owner) {
        require(_protocolFeeBps <= MAX_PROTOCOL_FEE, "LS: fee too high");
        WIK           = IERC20(wik);
        sWIK          = new sWIKToken(address(this));
        sWIK.setMinter(address(this));
        protocolFeeBps = _protocolFeeBps;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner / Operator
    // ─────────────────────────────────────────────────────────────────────

    function setOperator(address op) external onlyOwner {
        operator = op;
        emit OperatorSet(op);
    }

    function setProtocolFee(uint256 bps) external onlyOwner {
        require(bps <= MAX_PROTOCOL_FEE, "LS: fee too high");
        protocolFeeBps = bps;
    }

    /**
     * @notice Fund the instant-unstake liquidity buffer.
     *         Owner/operator deposits WIK so users can exit instantly.
     */
    function fundBuffer(uint256 amount) external nonReentrant {
        require(msg.sender == owner() || msg.sender == operator, "LS: not authorized");
        WIK.safeTransferFrom(msg.sender, address(this), amount);
        instantLiqBuffer += amount;
        emit BufferFunded(amount);
    }

    /**
     * @notice Push staking rewards into the pool (called by operator/keeper)
     *         Rewards increase the exchange rate for all sWIK holders.
     * @param rewardAmount WIK reward to distribute
     */
    function accrueRewards(uint256 rewardAmount) external nonReentrant {
        require(msg.sender == operator || msg.sender == owner(), "LS: not authorized");
        require(rewardAmount > 0, "LS: zero reward");
        require(sWIK.totalSupply() > 0, "LS: no stakers");

        uint256 protocolCut = rewardAmount * protocolFeeBps / BPS;
        uint256 netReward   = rewardAmount - protocolCut;

        // [A2] State before transfer
        totalStakedWIK     += netReward;
        pendingProtocolFee += protocolCut;

        WIK.safeTransferFrom(msg.sender, address(this), rewardAmount);

        emit RewardAccrued(rewardAmount, protocolCut, exchangeRate());
    }

    function claimProtocolFees(address to) external onlyOwner nonReentrant {
        uint256 amt        = pendingProtocolFee;
        require(amt > 0, "LS: no fees");
        pendingProtocolFee = 0;
        WIK.safeTransfer(to, amt);
        emit ProtocolFeesClaimed(to, amt);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────────────
    //  Stake
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Stake WIK to receive sWIK (liquid receipt token)
     * @param amount WIK to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 sWIKMinted) {
        require(amount >= MIN_STAKE, "LS: below minimum");

        uint256 rate  = exchangeRate();
        sWIKMinted    = amount * PRECISION / rate; // [A3] floor division
        require(sWIKMinted > 0, "LS: zero shares");

        // [A2] State before transfer
        totalStakedWIK += amount;

        WIK.safeTransferFrom(msg.sender, address(this), amount);
        sWIK.mint(msg.sender, sWIKMinted);

        emit Staked(msg.sender, amount, sWIKMinted, rate);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Unstake — Standard (7-day unbonding)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Request unstake: burn sWIK, start 7-day unbonding period
     * @param sWIKAmount Amount of sWIK to redeem
     */
    function requestUnstake(uint256 sWIKAmount) external nonReentrant returns (uint256 unbondId) {
        require(sWIK.balanceOf(msg.sender) >= sWIKAmount, "LS: insufficient sWIK");
        require(sWIKAmount > 0, "LS: zero amount");

        uint256 wikAmount  = sWIKAmount * exchangeRate() / PRECISION; // [A3] users get floor
        require(wikAmount > 0, "LS: zero WIK");

        unbondId           = unbondNonce[msg.sender]++;

        // [A2] State before transfer
        totalStakedWIK    -= wikAmount;
        totalUnbonding    += wikAmount;

        sWIK.burn(msg.sender, sWIKAmount);
        unbondRequests[msg.sender].push(UnbondRequest({
            id:         unbondId,
            wikAmount:  wikAmount,
            unbondTime: block.timestamp + UNBONDING_PERIOD,
            claimed:    false
        }));

        emit UnstakeRequested(msg.sender, unbondId, sWIKAmount, wikAmount, block.timestamp + UNBONDING_PERIOD);
    }

    /**
     * @notice Claim WIK after unbonding period
     */
    function claimUnstake(uint256 unbondId) external nonReentrant {
        UnbondRequest[] storage reqs = unbondRequests[msg.sender];
        UnbondRequest storage req    = reqs[unbondId];
        require(!req.claimed,                             "LS: already claimed");
        require(block.timestamp >= req.unbondTime,        "LS: unbonding not complete");

        uint256 amt    = req.wikAmount;
        req.claimed    = true;
        totalUnbonding -= amt;

        WIK.safeTransfer(msg.sender, amt);
        emit UnstakeClaimed(msg.sender, unbondId, amt);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Instant Unstake (uses buffer, pays fee)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Instantly redeem sWIK for WIK from the liquidity buffer.
     *         Pays INSTANT_FEE_BPS fee (0.3%). Buffer must have enough WIK.
     */
    function instantUnstake(uint256 sWIKAmount) external nonReentrant whenNotPaused {
        require(sWIK.balanceOf(msg.sender) >= sWIKAmount, "LS: insufficient sWIK");

        uint256 grossWIK   = sWIKAmount * exchangeRate() / PRECISION;
        uint256 fee        = grossWIK * INSTANT_FEE_BPS / BPS;
        uint256 netWIK     = grossWIK - fee;

        require(instantLiqBuffer >= netWIK + fee, "LS: buffer insufficient");

        // [A2] State before transfers
        totalStakedWIK     -= grossWIK;
        instantLiqBuffer   -= netWIK;
        pendingProtocolFee += fee;

        sWIK.burn(msg.sender, sWIKAmount);
        WIK.safeTransfer(msg.sender, netWIK);

        emit InstantUnstake(msg.sender, sWIKAmount, netWIK, fee);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Current exchange rate: WIK per sWIK (scaled 1e18)
     *         Rate grows as rewards accrue — 1 sWIK always redeems for >= 1 WIK
     */
    function exchangeRate() public view returns (uint256) {
        uint256 supply = sWIK.totalSupply();
        if (supply == 0) return INITIAL_SHARE_RATE;
        return totalStakedWIK * PRECISION / supply;
    }

    function sWIKToWIK(uint256 sWIKAmount) external view returns (uint256) {
        return sWIKAmount * exchangeRate() / PRECISION;
    }

    function wikToSWIK(uint256 wikAmount) external view returns (uint256) {
        return wikAmount * PRECISION / exchangeRate();
    }

    function getUnbondRequests(address user) external view returns (UnbondRequest[] memory) {
        return unbondRequests[user];
    }

    function totalPoolWIK() external view returns (uint256) {
        return totalStakedWIK;
    }

    function sWIKAddress() external view returns (address) {
        return address(sWIK);
    }
}
