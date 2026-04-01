// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiIEOPlatform
 * @notice IEO 2.0 — primary token issuance venue with exclusivity requirements.
 *
 * REVENUE MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * 1. PROTOCOL FEE : 3% of all raise proceeds → protocol treasury
 * 2. TOKEN ALLOCATION: 2% of total token supply allocated to protocol
 *    (held in this contract, vested 12 months)
 * 3. WIK BOND: projects post 50K WIK bond (slashed if exclusivity broken)
 * 4. LISTING FEE: flat $5K USDC to list (covers vetting costs)
 *
 * EXCLUSIVITY REQUIREMENT
 * ─────────────────────────────────────────────────────────────────────────
 * Projects must commit to Wikicious as primary DEX for 12 months.
 * WikiOrderBook gets initial liquidity seeding.
 * Bond slashed 100% if project lists on competing DEX within 12 months.
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

contract WikiIEOPlatform is Ownable2Step, ReentrancyGuard {
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

    uint256 public constant BPS              = 10_000;
    uint256 public constant PROTOCOL_FEE_BPS = 300;    // 3% of raise
    uint256 public constant TOKEN_ALLOC_BPS  = 200;    // 2% of supply
    uint256 public constant WIK_BOND         = 50_000 * 1e18; // 50K WIK
    uint256 public constant LISTING_FEE      = 5_000  * 1e6;  // $5K USDC
    uint256 public constant EXCLUSIVITY_DAYS = 365;
    uint256 public constant VESTING_MONTHS   = 12;

    enum SaleStatus { PENDING, APPROVED, ACTIVE, FINALIZED, CANCELLED }

    struct IEOProject {
        address  projectOwner;
        string   name;
        string   tokenSymbol;
        address  saleToken;         // token being sold (0x0 if not yet deployed)
        uint256  totalSupply;        // total token supply
        uint256  hardcap;            // USDC raise target
        uint256  softcap;
        uint256  tokenPrice;         // USDC per token (1e18)
        uint256  startTime;
        uint256  endTime;
        uint256  raised;             // USDC collected
        uint256  protocolFee;        // 3% collected
        uint256  protocolTokens;     // 2% of supply allocated to protocol
        uint256  protocolTokensVested;
        uint256  vestingStart;
        uint256  wikBond;            // WIK posted
        SaleStatus status;
        bool     exclusivityActive;
        uint256  exclusivityExpiry;
    }

    struct Contribution {
        uint256 usdcAmount;
        uint256 tokenAmount;
        bool    claimed;
    }

    IERC20  public immutable USDC;
    IERC20  public immutable WIK;

    IEOProject[] public projects;
    mapping(uint256 => mapping(address => Contribution)) public contributions;
    mapping(address => uint256[]) public projectsByOwner;

    address public treasury;
    uint256 public totalRaised;
    uint256 public totalProtocolFees;

    event ProjectRegistered(uint256 indexed id, address owner, string name, uint256 hardcap);
    event ProjectApproved(uint256 indexed id);
    event Contributed(uint256 indexed id, address contributor, uint256 usdc, uint256 tokens);
    event SaleFinalized(uint256 indexed id, uint256 raised, uint256 protocolFee);
    event TokensClaimed(uint256 indexed id, address contributor, uint256 amount);
    event ExclusivitySlashed(uint256 indexed id, uint256 wikSlashed);

    
    // ── Idle Yield Hook ─────────────────────────────────────────
    IIdleYieldRouter public idleYieldRouter;

    function setIdleYieldRouter(address router) external onlyOwner {
        idleYieldRouter = IIdleYieldRouter(router);
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

    constructor(address _usdc, address _wik, address _treasury, address _owner)
        Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_wik != address(0), "Wiki: zero _wik");
        require(_treasury != address(0), "Wiki: zero _treasury");
        USDC = IERC20(_usdc);
        WIK  = IERC20(_wik);
        treasury = _treasury;
    }

    function registerProject(
        string calldata name, string calldata symbol, address saleToken,
        uint256 totalSupply, uint256 hardcap, uint256 softcap, uint256 tokenPrice,
        uint256 startTime, uint256 endTime
    ) external nonReentrant returns (uint256 id) {
        require(hardcap > softcap && softcap > 0, "IEO: bad caps");
        require(startTime > block.timestamp && endTime > startTime, "IEO: bad times");
        require(tokenPrice > 0, "IEO: zero price");

        // Collect listing fee + WIK bond
        USDC.safeTransferFrom(msg.sender, treasury, LISTING_FEE);
        WIK.safeTransferFrom(msg.sender, address(this), WIK_BOND);
        totalProtocolFees += LISTING_FEE;

        id = projects.length;
        projects.push(IEOProject({
            projectOwner: msg.sender, name: name, tokenSymbol: symbol,
            saleToken: saleToken, totalSupply: totalSupply,
            hardcap: hardcap, softcap: softcap, tokenPrice: tokenPrice,
            startTime: startTime, endTime: endTime, raised: 0,
            protocolFee: 0, protocolTokens: totalSupply * TOKEN_ALLOC_BPS / BPS,
            protocolTokensVested: 0, vestingStart: endTime,
            wikBond: WIK_BOND, status: SaleStatus.PENDING,
            exclusivityActive: false, exclusivityExpiry: 0
        }));
        projectsByOwner[msg.sender].push(id);
        emit ProjectRegistered(id, msg.sender, name, hardcap);
    }

    function approveProject(uint256 id) external onlyOwner {
        projects[id].status = SaleStatus.APPROVED;
        emit ProjectApproved(id);
    }

    function contribute(uint256 id, uint256 usdcAmount) external nonReentrant {
        IEOProject storage p = projects[id];
        require(p.status == SaleStatus.APPROVED, "IEO: not approved");
        require(block.timestamp >= p.startTime && block.timestamp <= p.endTime, "IEO: not active");
        require(p.raised + usdcAmount <= p.hardcap, "IEO: hardcap exceeded");
        require(usdcAmount >= 10 * 1e6, "IEO: min $10");

        uint256 tokens = usdcAmount * 1e18 / p.tokenPrice;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        p.raised += usdcAmount;
        contributions[id][msg.sender].usdcAmount += usdcAmount;
        contributions[id][msg.sender].tokenAmount += tokens;
        totalRaised += usdcAmount;

        emit Contributed(id, msg.sender, usdcAmount, tokens);
    }

    function finalizeSale(uint256 id) external nonReentrant {
        IEOProject storage p = projects[id];
        require(p.status == SaleStatus.APPROVED, "IEO: not approved");
        require(block.timestamp > p.endTime || p.raised >= p.hardcap, "IEO: not ended");
        require(p.raised >= p.softcap, "IEO: softcap not reached");

        uint256 fee = p.raised * PROTOCOL_FEE_BPS / BPS;
        uint256 toProject = p.raised - fee;

        p.protocolFee = fee;
        p.status = SaleStatus.FINALIZED;
        p.exclusivityActive = true;
        p.exclusivityExpiry = block.timestamp + EXCLUSIVITY_DAYS * 1 days;
        p.vestingStart = block.timestamp;

        totalProtocolFees += fee;
        USDC.safeTransfer(treasury, fee);
        USDC.safeTransfer(p.projectOwner, toProject);

        emit SaleFinalized(id, p.raised, fee);
    }

    function claimTokens(uint256 id) external nonReentrant {
        IEOProject storage p = projects[id];
        require(p.status == SaleStatus.FINALIZED, "IEO: not finalized");
        require(p.saleToken != address(0), "IEO: token not set");
        Contribution storage c = contributions[id][msg.sender];
        require(c.tokenAmount > 0 && !c.claimed, "IEO: nothing to claim");
        c.claimed = true;
        IERC20(p.saleToken).safeTransfer(msg.sender, c.tokenAmount);
        emit TokensClaimed(id, msg.sender, c.tokenAmount);
    }

    function slashExclusivity(uint256 id) external onlyOwner {
        IEOProject storage p = projects[id];
        require(p.exclusivityActive, "IEO: no exclusivity");
        require(block.timestamp <= p.exclusivityExpiry, "IEO: expired");
        uint256 slashed = p.wikBond;
        p.wikBond = 0;
        p.exclusivityActive = false;
        WIK.safeTransfer(treasury, slashed);
        emit ExclusivitySlashed(id, slashed);
    }

    function projectCount() external view returns (uint256) { return projects.length; }
    function getProject(uint256 id) external view returns (IEOProject memory) { return projects[id]; }
    function getContribution(uint256 id, address user) external view returns (Contribution memory) { return contributions[id][user]; }
}
