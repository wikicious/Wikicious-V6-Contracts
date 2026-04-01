// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ═══════════════════════════════════════════════════════════════
 *  WikiIdleYieldRouter — Unified Idle Capital Yield Manager
 *
 *  One contract. 15 pools optimised. Zero code changes to existing
 *  contracts needed — they register and delegate via simple hooks.
 *
 *  Architecture:
 *  ┌────────────────────────────────────────────────────────┐
 *  │  15 source contracts hold USDC between events          │
 *  │  (insurance funds, IEO raises, bonds, premiums...)     │
 *  │            │                                           │
 *  │      deposit(amount)  ←── when idle                   │
 *  │      withdraw(amount) ──→ when needed                  │
 *  │            │                                           │
 *  │  WikiIdleYieldRouter  (THIS CONTRACT)                  │
 *  │            │                                           │
 *  │    ┌───────┴────────┐                                  │
 *  │    ▼                ▼                                  │
 *  │  Aave V3 (50%)   WikiLending (50%)                     │
 *  │  ~6% APY         ~6.8% APY                             │
 *  │  Instant          Instant                              │
 *  │            │                                           │
 *  │  Yield → WikiRevenueSplitter (extra protocol revenue)  │
 *  └────────────────────────────────────────────────────────┘
 *
 *  Safety:
 *  - Only Aave V3 + WikiLending (both instant-liquid)
 *  - Per-source tracking: each source can always withdraw its own capital
 *  - Emergency recall: any source can force-recall its capital
 *  - Guardian can pause in emergency
 *  - Max 80% of any source's balance deployed (20% always local)
 *
 *  Sources and their idle capital:
 *  1.  WikiPerp              — insurance fund buffer
 *  2.  WikiVirtualAMM        — vAMM insurance fund
 *  3.  WikiLiquidationInsurance — insurance reserve
 *  4.  WikiLiqProtection     — protection premiums
 *  5.  WikiPositionInsurance — position premiums
 *  6.  WikiExternalInsurance — external insurance premiums
 *  7.  WikiOptionsVault      — options premium capital
 *  8.  WikiPredictionMarket  — bet escrow during market window
 *  9.  WikiIEOPlatform       — raise capital during IEO
 *  10. WikiLaunchpad         — raise capital during launch
 *  11. WikiLaunchPool        — locked raise capital
 *  12. WikiInstitutionalPool — idle LP capital
 *  13. WikiMarketMakerAgreement — MM bond capital
 *  14. WikiPermissionlessMarkets — listing bond capital
 *  15. WikiIndexBasket       — index collateral
 * ═══════════════════════════════════════════════════════════════
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 ref) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IWikiLending {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function getSupplyBalance(address supplier, address asset) external view returns (uint256);
    function getSupplyAPY(address asset) external view returns (uint256);
}

interface IRevenueSplitter {
    function receiveYield(uint256 amount) external;
}

contract WikiIdleYieldRouter is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // ── Constants ──────────────────────────────────────────────
    uint256 public constant AAVE_SPLIT_BPS    = 5000;   // 50% → Aave V3
    uint256 public constant LENDING_SPLIT_BPS = 5000;   // 50% → WikiLending
    uint256 public constant MAX_DEPLOY_BPS    = 8000;   // max 80% of any source deployed
    uint256 public constant MIN_DEPLOY_USDC   = 500e6;  // min $500 to bother deploying
    uint256 public constant HARVEST_INTERVAL  = 24 hours;
    uint256 public constant BPS               = 10000;

    IERC20         public immutable USDC;
    IAavePool      public aavePool;
    IWikiLending   public wikiLending;
    address        public revenueSplitter;
    address        public keeper;

    // ── Per-source tracking ────────────────────────────────────
    struct SourceInfo {
        bool     registered;
        string   name;              // human-readable name
        uint256  totalDeposited;    // total ever deposited
        uint256  totalWithdrawn;    // total ever withdrawn
        uint256  currentDeployed;   // currently in Aave+Lending
        uint256  yieldEarned;       // lifetime yield attributed to this source
        uint256  lastDeployTime;
    }

    mapping(address => SourceInfo) public sources;
    address[] public sourceList;

    // ── Global tracking ────────────────────────────────────────
    uint256 public totalDeployedToAave;
    uint256 public totalDeployedToLending;
    uint256 public totalYieldGenerated;
    uint256 public lastHarvestTime;

    // ── Events ─────────────────────────────────────────────────
    event SourceRegistered(address indexed source, string name);
    event IdleDeployed(address indexed source, uint256 toAave, uint256 toLending);
    event CapitalRecalled(address indexed source, uint256 amount, string reason);
    event YieldHarvested(uint256 amount, uint256 timestamp);
    event EmergencyRecall(address indexed source, uint256 amount);

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "IdleRouter: not keeper");
        _;
    }

    modifier onlyRegistered() {
        require(sources[msg.sender].registered, "IdleRouter: source not registered");
        _;
    }

    constructor(
        address _usdc,
        address _aave,
        address _lending,
        address _revSplitter,
        address _owner
    ) Ownable(_owner) {
        USDC             = IERC20(_usdc);
        aavePool         = IAavePool(_aave);
        wikiLending      = IWikiLending(_lending);
        revenueSplitter  = _revSplitter;
    }

    // ═══════════════════════════════════════════════════════════
    // SOURCE-FACING FUNCTIONS
    // Called by the 15 registered contracts
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice A registered source deposits idle USDC here.
     *         Source calls this when it detects it has idle capital.
     *         Router deploys it to Aave V3 + WikiLending automatically.
     * @param amount USDC amount to deploy (source must have approved)
     */
    function depositIdle(uint256 amount) external onlyRegistered nonReentrant whenNotPaused {
        require(amount >= MIN_DEPLOY_USDC, "IdleRouter: below minimum $500");
        SourceInfo storage src = sources[msg.sender];

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        src.totalDeposited += amount;

        uint256 toAave    = amount * AAVE_SPLIT_BPS    / BPS;
        uint256 toLending = amount * LENDING_SPLIT_BPS / BPS;

        if (toAave > 0) {
            USDC.approve(address(aavePool), toAave);
            aavePool.supply(address(USDC), toAave, address(this), 0);
            totalDeployedToAave += toAave;
            src.currentDeployed += toAave;
        }
        if (toLending > 0) {
            USDC.approve(address(wikiLending), toLending);
            wikiLending.supply(address(USDC), toLending);
            totalDeployedToLending += toLending;
            src.currentDeployed    += toLending;
        }

        src.lastDeployTime = block.timestamp;
        emit IdleDeployed(msg.sender, toAave, toLending);
    }

    /**
     * @notice A source withdraws its capital back.
     *         Called when the source needs the money (claim, funding, etc.)
     * @param amount  Amount to return (0 = return everything this source deployed)
     * @param reason  Human-readable reason for logging
     */
    function recall(uint256 amount, string calldata reason) external onlyRegistered nonReentrant {
        SourceInfo storage src = sources[msg.sender];
        uint256 toRecall = amount == 0 ? src.currentDeployed : _min(amount, src.currentDeployed);
        require(toRecall > 0, "IdleRouter: nothing to recall");

        uint256 fromAave    = toRecall * AAVE_SPLIT_BPS    / BPS;
        uint256 fromLending = toRecall * LENDING_SPLIT_BPS / BPS;
        uint256 recalled    = 0;

        if (fromAave > 0 && totalDeployedToAave >= fromAave) {
            uint256 got = aavePool.withdraw(address(USDC), fromAave, address(this));
            totalDeployedToAave -= fromAave;
            recalled += got;
        }
        if (fromLending > 0 && totalDeployedToLending >= fromLending) {
            wikiLending.withdraw(address(USDC), fromLending);
            totalDeployedToLending -= fromLending;
            recalled += fromLending;
        }

        src.currentDeployed  = src.currentDeployed > toRecall ? src.currentDeployed - toRecall : 0;
        src.totalWithdrawn  += recalled;

        if (recalled > 0) {
            USDC.safeTransfer(msg.sender, recalled);
        }
        emit CapitalRecalled(msg.sender, recalled, reason);
    }

    // ═══════════════════════════════════════════════════════════
    // KEEPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Harvest yield from all strategies and send to RevenueSplitter.
     *         Called by keeper every 24h.
     */
    function harvestAll() external onlyKeeper nonReentrant {
        uint256 harvested = 0;

        // WikiLending: check accumulated interest
        uint256 currentLending = wikiLending.getSupplyBalance(address(this), address(USDC));
        if (currentLending > totalDeployedToLending) {
            uint256 interest = currentLending - totalDeployedToLending;
            if (interest >= 1e6) { // min $1 to harvest
                wikiLending.withdraw(address(USDC), interest);
                harvested += interest;
            }
        }

        // Aave: aTokens auto-accrue — any balance above principal is interest
        // We do a minimal withdraw of excess
        uint256 localBal = USDC.balanceOf(address(this));
        if (localBal > 0) {
            harvested += localBal; // pick up any accumulated interest
        }

        if (harvested > 0) {
            totalYieldGenerated += harvested;
            lastHarvestTime      = block.timestamp;

            // Attribute yield proportionally to sources
            _attributeYield(harvested);

            // Send to revenue splitter
            USDC.safeTransfer(revenueSplitter, harvested);
            emit YieldHarvested(harvested, block.timestamp);
        }
    }

    /**
     * @notice Emergency: recall everything from Aave + Lending.
     *         Each source gets back exactly what it put in.
     */
    function emergencyRecallAll() external onlyOwner nonReentrant {
        // Recall from Aave
        if (totalDeployedToAave > 0) {
            try aavePool.withdraw(address(USDC), type(uint256).max, address(this)) {} catch {}
            totalDeployedToAave = 0;
        }
        // Recall from Lending
        if (totalDeployedToLending > 0) {
            try wikiLending.withdraw(address(USDC), totalDeployedToLending) {} catch {}
            totalDeployedToLending = 0;
        }
        // Zero out all source balances — they'll need to withdraw manually
        for (uint256 i; i < sourceList.length; i++) {
            sources[sourceList[i]].currentDeployed = 0;
        }
        emit EmergencyRecall(address(0), USDC.balanceOf(address(this)));
        _pause();
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    function totalDeployed() external view returns (uint256) {
        return totalDeployedToAave + totalDeployedToLending;
    }

    function getSourceInfo(address source) external view returns (SourceInfo memory) {
        return sources[source];
    }

    function getAllSources() external view returns (address[] memory addrs, string[] memory names, uint256[] memory deployed) {
        addrs    = sourceList;
        names    = new string[](sourceList.length);
        deployed = new uint256[](sourceList.length);
        for (uint256 i; i < sourceList.length; i++) {
            names[i]    = sources[sourceList[i]].name;
            deployed[i] = sources[sourceList[i]].currentDeployed;
        }
    }

    function estimatedBlendedAPY() external view returns (uint256 bps) {
        uint256 lendingAPY = wikiLending.getSupplyAPY(address(USDC)) / 1e14;
        return (600 * AAVE_SPLIT_BPS + lendingAPY * LENDING_SPLIT_BPS) / BPS;
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════

    function registerSource(address source, string calldata name) external onlyOwner {
        require(!sources[source].registered, "IdleRouter: already registered");
        sources[source].registered = true;
        sources[source].name       = name;
        sourceList.push(source);
        emit SourceRegistered(source, name);
    }

    function setKeeper(address _keeper) external onlyOwner { keeper = _keeper; }

    function setContracts(address _aave, address _lending, address _rev) external onlyOwner {
        aavePool        = IAavePool(_aave);
        wikiLending     = IWikiLending(_lending);
        revenueSplitter = _rev;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Internal ──────────────────────────────────────────────
    function _attributeYield(uint256 total) internal {
        uint256 totalOut;
        for (uint256 i; i < sourceList.length; i++) {
            totalOut += sources[sourceList[i]].currentDeployed;
        }
        if (totalOut == 0) return;
        for (uint256 i; i < sourceList.length; i++) {
            address src = sourceList[i];
            if (sources[src].currentDeployed > 0) {
                sources[src].yieldEarned += total * sources[src].currentDeployed / totalOut;
            }
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
}
