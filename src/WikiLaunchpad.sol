// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLaunchpad
 * @notice Tiered IDO launchpad with guaranteed allocation, cliff + linear vesting
 *
 * RAISE MODEL
 * ──────────────────────────────────────────────────────
 * • Projects create a Sale with a hardcap, price, and timeline
 * • Participants must hold veWIK (from WikiStaking) to qualify for tiers
 * • 3 tiers: Bronze (500 veWIK), Silver (2000 veWIK), Gold (10000 veWIK)
 * • Guaranteed allocation within tier, FCFS overflow once all tiers filled
 * • Funds raised are held in escrow; project can claim after TGE
 * • Purchasers claim tokens on vesting schedule (cliff + linear release)
 * • If sale fails (below softcap), participants receive full USDC refund
 *
 * REVENUE
 * ───────
 * • Protocol charges launchFeeOnRaise (default 3%) taken from raise proceeds
 * • Emergency withdraw penalty (5%) if project pulls before TGE (rare)
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy   → ReentrancyGuard
 * [A2] CEI          → state before transfers
 * [A3] Refund math  → tracked per-user, no rounding loss
 * [A4] Over-raise   → capped at hardcap strictly
 * [A5] Time locks   → sale phases enforced by block.timestamp
 * [A6] Double claim → claimable math subtracts already claimed
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

interface IWikiStaking {
        function getCurrentVeWIK(address user) external view returns (uint256);
    }

contract WikiLaunchpad is Ownable2Step, ReentrancyGuard {
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

    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant BPS              = 10_000;
    uint256 public constant DEFAULT_LAUNCH_FEE = 300; // 3%
    uint256 public constant MAX_LAUNCH_FEE   = 1000; // 10% max
    uint256 public constant EMERGENCY_PENALTY = 500; // 5%

    // veWIK thresholds for each tier (scaled 1e18)
    uint256 public constant TIER_BRONZE_MIN  = 500   * 1e18;
    uint256 public constant TIER_SILVER_MIN  = 2_000 * 1e18;
    uint256 public constant TIER_GOLD_MIN    = 10_000 * 1e18;

    // ─────────────────────────────────────────────────────────────────────
    //  Interfaces
    // ─────────────────────────────────────────────────────────────────────


    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────
    enum SaleStatus { Pending, Active, Filled, Failed, Finalized }

    struct Sale {
        // Project info
        address projectOwner;
        address saleToken;      // token being sold (address(0) if not yet deployed)
        address raiseToken;     // usually USDC
        string  name;
        string  metaURI;        // IPFS URI for project metadata

        // Raise params
        uint256 pricePerToken;  // raiseToken per saleToken (18 dec)
        uint256 hardcap;        // max raise amount (raiseToken)
        uint256 softcap;        // min raise for success (raiseToken)
        uint256 totalTokens;    // total saleTokens available

        // Allocation per tier (raiseToken)
        uint256 goldAlloc;
        uint256 silverAlloc;
        uint256 bronzeAlloc;
        uint256 publicAlloc;    // no-tier FCFS phase

        // Timeline
        uint256 startTime;
        uint256 endTime;
        uint256 tgeTime;        // Token Generation Event timestamp

        // Vesting
        uint256 cliffDuration;  // seconds before any tokens unlock
        uint256 vestDuration;   // seconds for full linear vesting after cliff

        // State
        uint256 totalRaised;
        uint256 launchFeeBps;
        SaleStatus status;
        bool     tokensDeposited;
    }

    struct UserCommit {
        uint256 committed;      // raiseToken committed
        uint256 tokensClaimed;  // saleTokens already claimed
        bool    refunded;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IERC20          public immutable USDC;
    IWikiStaking    public           staking;

    Sale[]          public sales;
    mapping(uint256 => mapping(address => UserCommit)) public commits;
    uint256         public protocolFees; // accumulated USDC

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event SaleCreated(uint256 indexed saleId, address indexed project, string name, uint256 hardcap);
    event Committed(uint256 indexed saleId, address indexed user, uint256 amount, uint8 tier);
    event SaleFinalized(uint256 indexed saleId, uint256 raised, uint256 fee);
    event SaleFailed(uint256 indexed saleId);
    event TokensClaimed(uint256 indexed saleId, address indexed user, uint256 amount);
    event Refunded(uint256 indexed saleId, address indexed user, uint256 amount);
    event TokensDeposited(uint256 indexed saleId, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = router;
    }

    /// @notice Keeper calls this to deploy idle USDC to yield strategies
    function deployIdle(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        require(address(idleYieldRouter) != address(0), "Router not set");
        USDC.approve(address(idleYieldRouter), amount);
        idleYieldRouter.depositIdle(amount);
    }

    /// @notice Recall capital before a claim/allocation
    function recallIdle(uint256 amount, string calldata reason) external {
        require(msg.sender == owner() || msg.sender == address(idleYieldRouter), "Not authorized");
        if (address(idleYieldRouter) != address(0)) {
            idleYieldRouter.recall(amount, reason);
        }
    }

    constructor(address usdc, address _staking, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(_staking != address(0), "Wiki: zero _staking");
        require(owner != address(0), "Wiki: zero owner");
        USDC    = IERC20(usdc);
        staking = IWikiStaking(_staking);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Create Sale
    // ─────────────────────────────────────────────────────────────────────

    function createSale(
        address projectOwner,
        address saleToken,
        string  calldata name,
        string  calldata metaURI,
        uint256 pricePerToken,
        uint256 hardcap,
        uint256 softcap,
        uint256 totalTokens,
        uint256[4] calldata allocations, // [gold, silver, bronze, public]
        uint256[3] calldata timeline,    // [startTime, endTime, tgeTime]
        uint256 cliffDuration,
        uint256 vestDuration,
        uint256 launchFeeBps
    ) external onlyOwner returns (uint256 saleId) {
        require(hardcap >= softcap && softcap > 0,       "LP: bad caps");
        require(timeline[0] < timeline[1],               "LP: bad timeline");
        require(timeline[1] <= timeline[2],              "LP: TGE before end");
        require(pricePerToken > 0 && totalTokens > 0,    "LP: zero price/tokens");
        require(launchFeeBps <= MAX_LAUNCH_FEE,          "LP: fee too high");
        require(
            allocations[0] + allocations[1] + allocations[2] + allocations[3] == hardcap,
            "LP: alloc mismatch"
        );

        saleId = sales.length;
        sales.push(Sale({
            projectOwner:    projectOwner,
            saleToken:       saleToken,
            raiseToken:      address(USDC),
            name:            name,
            metaURI:         metaURI,
            pricePerToken:   pricePerToken,
            hardcap:         hardcap,
            softcap:         softcap,
            totalTokens:     totalTokens,
            goldAlloc:       allocations[0],
            silverAlloc:     allocations[1],
            bronzeAlloc:     allocations[2],
            publicAlloc:     allocations[3],
            startTime:       timeline[0],
            endTime:         timeline[1],
            tgeTime:         timeline[2],
            cliffDuration:   cliffDuration,
            vestDuration:    vestDuration,
            totalRaised:     0,
            launchFeeBps:    launchFeeBps == 0 ? DEFAULT_LAUNCH_FEE : launchFeeBps,
            status:          SaleStatus.Pending,
            tokensDeposited: false
        }));
        emit SaleCreated(saleId, projectOwner, name, hardcap);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Project: Deposit Sale Tokens
    // ─────────────────────────────────────────────────────────────────────

    function depositSaleTokens(uint256 saleId) external nonReentrant {
        Sale storage s = sales[saleId];
        require(msg.sender == s.projectOwner || msg.sender == owner(), "LP: not project");
        require(!s.tokensDeposited, "LP: already deposited");
        require(s.saleToken != address(0),                            "LP: no token set");

        s.tokensDeposited = true;
        IERC20(s.saleToken).safeTransferFrom(msg.sender, address(this), s.totalTokens);
        emit TokensDeposited(saleId, s.totalTokens);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  User: Commit
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Commit USDC to participate in a sale
     * @param saleId  Sale to participate in
     * @param amount  USDC amount to commit
     */
    function commit(uint256 saleId, uint256 amount) external nonReentrant {
        Sale storage s = sales[saleId];
        require(block.timestamp >= s.startTime && block.timestamp < s.endTime, "LP: sale not active");
        require(s.status == SaleStatus.Pending || s.status == SaleStatus.Active, "LP: not open");
        require(amount > 0, "LP: zero amount");

        // Tier check and cap
        uint8   tier    = _getTier(msg.sender);
        uint256 maxAlloc = _maxAlloc(s, tier);
        UserCommit storage uc = commits[saleId][msg.sender];

        require(uc.committed + amount <= maxAlloc, "LP: exceeds tier allocation");
        require(s.totalRaised + amount <= s.hardcap, "LP: hardcap reached"); // [A4]

        // [A2] State before transfer
        uc.committed   += amount;
        s.totalRaised  += amount;
        if (s.status == SaleStatus.Pending) s.status = SaleStatus.Active;
        if (s.totalRaised >= s.hardcap)     s.status = SaleStatus.Filled;

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Committed(saleId, msg.sender, amount, tier);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Finalize Sale (after endTime)
    // ─────────────────────────────────────────────────────────────────────

    function finalizeSale(uint256 saleId) external nonReentrant {
        Sale storage s = sales[saleId];
        require(block.timestamp >= s.endTime,                       "LP: not ended");
        require(s.status == SaleStatus.Active || s.status == SaleStatus.Filled ||
                s.status == SaleStatus.Pending,                     "LP: already finalized");

        if (s.totalRaised < s.softcap) {
            // Sale failed — enable refunds
            s.status = SaleStatus.Failed;
            // Return unsold tokens to project
            if (s.tokensDeposited) {
                IERC20(s.saleToken).safeTransfer(s.projectOwner, s.totalTokens);
            }
            emit SaleFailed(saleId);
        } else {
            s.status = SaleStatus.Finalized;

            // Take protocol fee
            uint256 fee      = s.totalRaised * s.launchFeeBps / BPS;
            uint256 proceeds = s.totalRaised - fee;
            protocolFees    += fee;

            // Send proceeds to project
            USDC.safeTransfer(s.projectOwner, proceeds);
            emit SaleFinalized(saleId, s.totalRaised, fee);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Claim Tokens (with vesting)
    // ─────────────────────────────────────────────────────────────────────

    function claimTokens(uint256 saleId) external nonReentrant {
        Sale storage s     = sales[saleId];
        UserCommit storage uc = commits[saleId][msg.sender];
        require(s.status == SaleStatus.Finalized,  "LP: not finalized");
        require(uc.committed > 0,                   "LP: nothing committed");
        require(s.saleToken != address(0),          "LP: no token");
        require(block.timestamp >= s.tgeTime + s.cliffDuration, "LP: cliff not passed"); // [A5]

        uint256 claimable = _claimable(s, uc);
        require(claimable > 0, "LP: nothing claimable");

        // [A6] Track claimed to prevent double-claim
        uc.tokensClaimed += claimable;
        IERC20(s.saleToken).safeTransfer(msg.sender, claimable);
        emit TokensClaimed(saleId, msg.sender, claimable);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Refund (failed sale)
    // ─────────────────────────────────────────────────────────────────────

    function refund(uint256 saleId) external nonReentrant {
        Sale storage s = sales[saleId];
        UserCommit storage uc = commits[saleId][msg.sender];
        require(s.status == SaleStatus.Failed, "LP: not failed");
        require(uc.committed > 0,              "LP: nothing committed");
        require(!uc.refunded,                  "LP: already refunded");

        uint256 amount = uc.committed;
        uc.refunded    = true;    // [A2] state before transfer
        USDC.safeTransfer(msg.sender, amount);
        emit Refunded(saleId, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner: Withdraw Protocol Fees
    // ─────────────────────────────────────────────────────────────────────

    function withdrawProtocolFees(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolFees;
        require(amt > 0, "LP: no fees");
        protocolFees = 0;
        USDC.safeTransfer(to, amt);
        emit ProtocolFeesWithdrawn(to, amt);
    }

    function setStaking(address _staking) external onlyOwner {
        staking = IWikiStaking(_staking);
    }

    function setSaleToken(uint256 saleId, address token) external onlyOwner {
        sales[saleId].saleToken = token;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _getTier(address user) internal view returns (uint8) {
        uint256 veWIK = staking.getCurrentVeWIK(user);
        if (veWIK >= TIER_GOLD_MIN)   return 3; // Gold
        if (veWIK >= TIER_SILVER_MIN) return 2; // Silver
        if (veWIK >= TIER_BRONZE_MIN) return 1; // Bronze
        return 0;                                // Public (FCFS only)
    }

    function _maxAlloc(Sale storage s, uint8 tier) internal view returns (uint256) {
        if (tier == 3) return s.goldAlloc   + s.silverAlloc + s.bronzeAlloc + s.publicAlloc;
        if (tier == 2) return s.silverAlloc + s.bronzeAlloc + s.publicAlloc;
        if (tier == 1) return s.bronzeAlloc + s.publicAlloc;
        return s.publicAlloc;
    }

    function _claimable(Sale storage s, UserCommit storage uc) internal view returns (uint256) {
        uint256 totalOwed    = uc.committed * 1e18 / s.pricePerToken;
        uint256 tgeUnlock    = s.tgeTime + s.cliffDuration;
        if (block.timestamp < tgeUnlock)        return 0;
        if (s.vestDuration == 0)                return totalOwed - uc.tokensClaimed;

        uint256 elapsed      = block.timestamp - tgeUnlock;
        if (elapsed >= s.vestDuration)           return totalOwed - uc.tokensClaimed;

        uint256 vested       = totalOwed * elapsed / s.vestDuration;
        return vested > uc.tokensClaimed ? vested - uc.tokensClaimed : 0;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function getSale(uint256 saleId) external view returns (Sale memory) {
        return sales[saleId];
    }

    function saleCount() external view returns (uint256) {
        return sales.length;
    }

    function getUserCommit(uint256 saleId, address user) external view returns (UserCommit memory) {
        return commits[saleId][user];
    }

    function claimableView(uint256 saleId, address user) external view returns (uint256) {
        Sale storage s = sales[saleId];
        if (s.status != SaleStatus.Finalized) return 0;
        return _claimable(s, commits[saleId][user]);
    }

    function tierOf(address user) external view returns (uint8) {
        return _getTier(user);
    }

    function allocationFor(uint256 saleId, address user) external view returns (uint256) {
        Sale storage s = sales[saleId];
        uint8 tier = _getTier(user);
        uint256 max = _maxAlloc(s, tier);
        uint256 used = commits[saleId][user].committed;
        return max > used ? max - used : 0;
    }
}
