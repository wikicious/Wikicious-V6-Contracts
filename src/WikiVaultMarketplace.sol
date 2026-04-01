// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiVaultMarketplace
 * @notice Registry and discovery hub for all yield vaults in the ecosystem.
 *         Protocol vaults + third-party vaults all listed in one place.
 *         Third-party listing fee: 2% of vault management fees ongoing.
 *
 * LISTED VAULT TYPES:
 *   Protocol vaults (free):  WikiBackstopVault, WikiDeltaNeutralVault,
 *                             WikiStructuredProduct, WikiLeveragedYield,
 *                             WikiBotVault (Grid/Funding/Trend/MR)
 *   Third-party vaults (fee): Any protocol can list their vault here
 *                              and tap into Wikicious user base
 *
 * REVENUE MODEL:
 *   Third-party listing fee: $1,000 USDC upfront + 2% of their mgmt fees
 *   Protocol vaults: free listing, drives TVL into own contracts
 *   At 10 third-party vaults with $5M TVL each:
 *     $50M TVL × 1% avg mgmt fee = $500K/year fees
 *     2% of $500K = $10K/year from third-party fees alone
 */
contract WikiVaultMarketplace is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    enum VaultCategory { YIELD, STRUCTURED, LEVERAGED, TRADING_BOT, COPY_TRADING, PROTECTION, OTHER }
    enum RiskRating    { VERY_LOW, LOW, MEDIUM, HIGH, VERY_HIGH }

    struct VaultListing {
        uint256       id;
        address       vault;
        address       manager;          // who manages this vault
        string        name;
        string        description;
        string        strategyType;     // "Covered Call", "Grid Trading", etc
        VaultCategory category;
        RiskRating    risk;
        address       depositToken;
        uint256       currentAPYBps;    // updated by vault or keeper
        uint256       tvl;              // updated by vault or keeper
        uint256       minDeposit;
        uint256       exitDelayDays;
        uint256       managementFeeBps;
        uint256       performanceFeeBps;
        bool          isProtocolVault;  // true = no listing fee
        bool          verified;         // owner verified this vault is legit
        bool          active;
        uint256       listedAt;
        uint256       totalDepositors;
        uint256       allTimeTVL;
    }

    mapping(uint256 => VaultListing) public vaults;
    mapping(address => uint256)      public vaultToId;      // vault addr → listing id
    mapping(address => uint256[])    public managerVaults;  // manager → listing ids
    uint256[] public activeListings;
    uint256   public nextListingId;

    uint256 public listingFeeUsdc  = 1_000 * 1e6;  // $1,000 upfront
    uint256 public ongoingFeeBps   = 200;           // 2% of vault management fees
    address public feeTreasury;

    event VaultListed(uint256 id, address vault, string name, bool isProtocol);
    event VaultUpdated(uint256 id, uint256 apyBps, uint256 tvl);
    event VaultDelisted(uint256 id, string reason);

    constructor(address _owner, address _usdc, address _treasury) Ownable(_owner) {
        USDC        = IERC20(_usdc);
        feeTreasury = _treasury;
    }

    // ── List a vault ──────────────────────────────────────────────────────
    function listVault(
        address       vault,
        string        calldata name,
        string        calldata description,
        string        calldata strategyType,
        VaultCategory category,
        RiskRating    risk,
        address       depositToken,
        uint256       minDeposit,
        uint256       exitDelayDays,
        uint256       mgmtFeeBps,
        uint256       perfFeeBps
    ) external nonReentrant returns (uint256 listingId) {
        require(vaultToId[vault] == 0, "VM: already listed");
        require(vault != address(0),   "VM: zero vault");

        // Collect listing fee for non-protocol vaults
        USDC.safeTransferFrom(msg.sender, feeTreasury, listingFeeUsdc);

        listingId = nextListingId++;
        vaults[listingId] = VaultListing({
            id:               listingId,
            vault:            vault,
            manager:          msg.sender,
            name:             name,
            description:      description,
            strategyType:     strategyType,
            category:         category,
            risk:             risk,
            depositToken:     depositToken,
            currentAPYBps:    0,
            tvl:              0,
            minDeposit:       minDeposit,
            exitDelayDays:    exitDelayDays,
            managementFeeBps: mgmtFeeBps,
            performanceFeeBps:perfFeeBps,
            isProtocolVault:  false,
            verified:         false,
            active:           true,
            listedAt:         block.timestamp,
            totalDepositors:  0,
            allTimeTVL:       0
        });
        vaultToId[vault] = listingId;
        managerVaults[msg.sender].push(listingId);
        activeListings.push(listingId);
        emit VaultListed(listingId, vault, name, false);
    }

    // ── Protocol lists its own vaults for free ────────────────────────────
    function listProtocolVault(
        address vault, string calldata name, string calldata desc,
        string calldata strategyType, VaultCategory cat, RiskRating risk,
        address depositToken, uint256 minDep, uint256 exitDays, uint256 mgmt, uint256 perf
    ) external onlyOwner returns (uint256 listingId) {
        listingId = nextListingId++;
        vaults[listingId] = VaultListing({
            id: listingId, vault: vault, manager: msg.sender,
            name: name, description: desc, strategyType: strategyType,
            category: cat, risk: risk, depositToken: depositToken,
            currentAPYBps: 0, tvl: 0, minDeposit: minDep,
            exitDelayDays: exitDays, managementFeeBps: mgmt, performanceFeeBps: perf,
            isProtocolVault: true, verified: true, active: true,
            listedAt: block.timestamp, totalDepositors: 0, allTimeTVL: 0
        });
        vaultToId[vault]  = listingId;
        managerVaults[msg.sender].push(listingId);
        activeListings.push(listingId);
        emit VaultListed(listingId, vault, name, true);
    }

    // ── Update live stats ─────────────────────────────────────────────────
    function updateStats(uint256 listingId, uint256 apyBps, uint256 tvl, uint256 depositors) external {
        VaultListing storage v = vaults[listingId];
        require(msg.sender == v.manager || msg.sender == owner(), "VM: not manager");
        v.currentAPYBps   = apyBps;
        v.tvl             = tvl;
        v.totalDepositors = depositors;
        if (tvl > v.allTimeTVL) v.allTimeTVL = tvl;
        emit VaultUpdated(listingId, apyBps, tvl);
    }

    function delist(uint256 listingId, string calldata reason) external {
        VaultListing storage v = vaults[listingId];
        require(msg.sender == v.manager || msg.sender == owner(), "VM: not manager");
        v.active = false;
        emit VaultDelisted(listingId, reason);
    }

    // ── Discovery views ───────────────────────────────────────────────────
    function getByCategory(VaultCategory cat) external view returns (VaultListing[] memory result) {
        uint256 count;
        for (uint i; i < activeListings.length; i++) {
            VaultListing storage v = vaults[activeListings[i]];
            if (v.active && v.category == cat) count++;
        }
        result = new VaultListing[](count);
        uint256 idx;
        for (uint i; i < activeListings.length; i++) {
            VaultListing storage v = vaults[activeListings[i]];
            if (v.active && v.category == cat) result[idx++] = v;
        }
    }

    function getByRisk(RiskRating maxRisk) external view returns (VaultListing[] memory result) {
        uint256 count;
        for (uint i; i < activeListings.length; i++) {
            VaultListing storage v = vaults[activeListings[i]];
            if (v.active && uint8(v.risk) <= uint8(maxRisk)) count++;
        }
        result = new VaultListing[](count);
        uint256 idx;
        for (uint i; i < activeListings.length; i++) {
            VaultListing storage v = vaults[activeListings[i]];
            if (v.active && uint8(v.risk) <= uint8(maxRisk)) result[idx++] = v;
        }
    }

    function getTopByAPY(uint256 n) external view returns (VaultListing[] memory result) {
        uint256 count = activeListings.length < n ? activeListings.length : n;
        result = new VaultListing[](count);
        for (uint i; i < count; i++) {
            uint256 bestIdx; uint256 bestAPY;
            for (uint j; j < activeListings.length; j++) {
                VaultListing storage v = vaults[activeListings[j]];
                if (!v.active) continue;
                bool already;
                for (uint k; k < i; k++) if (result[k].id == v.id) { already = true; break; }
                if (!already && v.currentAPYBps > bestAPY) { bestAPY = v.currentAPYBps; bestIdx = j; }
            }
            result[i] = vaults[activeListings[bestIdx]];
        }
    }

    function getAllActive() external view returns (VaultListing[] memory) {
        uint256 count;
        for (uint i; i < activeListings.length; i++) if (vaults[activeListings[i]].active) count++;
        VaultListing[] memory result = new VaultListing[](count);
        uint256 idx;
        for (uint i; i < activeListings.length; i++) if (vaults[activeListings[i]].active) result[idx++] = vaults[activeListings[i]];
        return result;
    }

    function verifyVault(uint256 id, bool verified) external onlyOwner { vaults[id].verified = verified; }
    function setListingFee(uint256 fee) external onlyOwner { listingFeeUsdc = fee; }
    function setTreasury(address t) external onlyOwner { feeTreasury = t; }
}
