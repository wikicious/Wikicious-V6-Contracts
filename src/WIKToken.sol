// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WIKToken — Wikicious Governance & Utility Token
 *
 * ─── TOTAL SUPPLY: 1,000,000,000 WIK (1 Billion, fixed forever) ─────────────
 *
 * ALLOCATION SCHEDULE (enforced in code at deploy — no hidden mint authority):
 * ┌─────────────────────────────┬────────┬──────────────────────────────────────┐
 * │ Allocation                  │   %    │ Vesting                              │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Community / Ecosystem       │  40%   │ Emitted over 4 years via staking     │
 * │   400M WIK                  │        │ + gauge voting + liquidity mining     │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Protocol-Owned Liquidity    │  15%   │ Locked forever in WikiPOL            │
 * │   150M WIK                  │        │ Earns LP fees for protocol — no sell │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Team & Advisors             │  15%   │ 1-year cliff + 3-year linear vesting │
 * │   150M WIK                  │        │ Enforced by WikiTokenVesting contract │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Investors / Seed            │  10%   │ 6-month cliff + 2-year linear vesting│
 * │   100M WIK                  │        │ Enforced by WikiTokenVesting contract │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Treasury (DAO-controlled)   │  10%   │ 48h timelock on all withdrawals      │
 * │   100M WIK                  │        │ Used for: salaries, grants, audits   │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Public Launch (IEO/IDO)     │   5%   │ Unlocked at TGE                      │
 * │    50M WIK                  │        │ Sold via WikiLaunchpad               │
 * ├─────────────────────────────┼────────┼──────────────────────────────────────┤
 * │ Reserve (emergency only)    │   5%   │ 2-year timelock, DAO vote to unlock  │
 * │    50M WIK                  │        │ For: major pivots, acquisitions      │
 * └─────────────────────────────┴────────┴──────────────────────────────────────┘
 *
 * ─── HOW FOUNDER WITHDRAWS PROFITS ──────────────────────────────────────────
 *
 *   Path 1 — Team tokens (month 13 onwards):
 *     WikiTokenVesting.claim() → receive WIK → sell gradually on market
 *     Max monthly unlock: ~3.47M WIK (150M / 36 months after cliff)
 *
 *   Path 2 — Treasury salary (from day 1, DAO vote required):
 *     WikiDAOTreasury.payContributor() → receive USDC monthly
 *     Typical range: $8K–$15K/month depending on protocol revenue
 *
 *   Path 3 — veWIK fee share (passive, from staking vested tokens):
 *     Lock WIK as veWIK → earn 40% of all trading fees in USDC weekly
 *     Example at 15% veWIK share + $10M daily volume: ~$10,800/month
 *
 *   Path 4 — POL compound returns (year 2+):
 *     WikiPOL LP fees accumulate in treasury → distributed via governance
 *
 * ─── CIRCULATING SUPPLY AT TGE ───────────────────────────────────────────────
 *
 *   TGE day:       50M WIK (5%) — IEO buyers only
 *   Month 1-6:     Small ecosystem emissions begin
 *   Month 7:       Investor tokens start vesting (+2.08M/mo)
 *   Month 13:      Team tokens start vesting (+4.17M/mo)
 *   Month 48:      Full community emission complete
 *
 *   This gradual schedule prevents supply shock and supports token price.
 *
 * ─── SECURITY ─────────────────────────────────────────────────────────────────
 *   [A1] All allocations minted to locked contracts at deploy — no owner wallet
 *   [A2] Owner (multisig) can only: set minters, update fee tiers
 *   [A3] MAX_SUPPLY is a hard constant — cannot be changed
 *   [A4] allocationSchedule() is public and immutable — full transparency
 */
contract WIKToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes, Ownable2Step {

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant MAX_SUPPLY       = 1_000_000_000 * 1e18; // 1B total

    // Allocation amounts (must sum to MAX_SUPPLY)
    uint256 public constant COMMUNITY_ALLOC  =   400_000_000 * 1e18; // 40%
    uint256 public constant POL_ALLOC        =   150_000_000 * 1e18; // 15%
    uint256 public constant TEAM_ALLOC       =   150_000_000 * 1e18; // 15%
    uint256 public constant INVESTOR_ALLOC   =   100_000_000 * 1e18; // 10%
    uint256 public constant TREASURY_ALLOC   =   100_000_000 * 1e18; // 10%
    uint256 public constant PUBLIC_ALLOC     =    50_000_000 * 1e18; //  5%
    uint256 public constant RESERVE_ALLOC    =    50_000_000 * 1e18; //  5%

    // ── Allocation destination addresses (set at deploy) ─────────────────────

    address public immutable communityEmitter;  // WikiStaking + WikiGaugeVoting
    address public immutable polVault;          // WikiPOL — locked forever
    address public immutable teamVesting;       // WikiTokenVesting (team)
    address public immutable investorVesting;   // WikiTokenVesting (investors)
    address public immutable treasury;          // WikiDAOTreasury
    address public immutable publicSale;        // WikiLaunchpad IEO contract
    address public immutable reserve;           // WikiDAOTreasury reserve (timelocked)

    // ── Fee discount tiers ────────────────────────────────────────────────────

    struct Tier {
        uint256 minWIK;
        uint256 makerDiscount; // bps discount on maker fee
        uint256 takerDiscount; // bps discount on taker fee
    }
    Tier[5] public tiers;

    // ── Minters (WikiStaking, WikiGaugeVoting for emissions) ─────────────────
    mapping(address => bool) public minters;

    // ── Events ────────────────────────────────────────────────────────────────
    event MinterSet(address indexed minter, bool enabled);
    event AllocationMinted(string indexed name, address indexed to, uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _multisig     3-of-5 multisig — will own this contract
     * @param _communityEmitter WikiStaking + WikiGaugeVoting emission controller
     * @param _polVault     WikiPOL — tokens locked here earn LP fees forever
     * @param _teamVesting  WikiTokenVesting deployed for team (1yr cliff + 3yr)
     * @param _investorVesting WikiTokenVesting for investors (6mo cliff + 2yr)
     * @param _treasury     WikiDAOTreasury — DAO-controlled, pays salaries etc
     * @param _publicSale   WikiLaunchpad — sells 5% at TGE
     * @param _reserve      WikiDAOTreasury reserve slot — timelocked 2 years
     */
    constructor(
        address _multisig,
        address _communityEmitter,
        address _polVault,
        address _teamVesting,
        address _investorVesting,
        address _treasury,
        address _publicSale,
        address _reserve
    )
        ERC20("Wikicious", "WIK")
        ERC20Permit("Wikicious")
        Ownable(_multisig)
    {
        // Validate — no zero addresses [A1]
        require(_multisig         != address(0), "WIK: zero multisig");
        require(_communityEmitter != address(0), "WIK: zero community");
        require(_polVault         != address(0), "WIK: zero POL");
        require(_teamVesting      != address(0), "WIK: zero teamVesting");
        require(_investorVesting  != address(0), "WIK: zero investorVesting");
        require(_treasury         != address(0), "WIK: zero treasury");
        require(_publicSale       != address(0), "WIK: zero publicSale");
        require(_reserve          != address(0), "WIK: zero reserve");

        // Store immutable destinations
        communityEmitter = _communityEmitter;
        polVault         = _polVault;
        teamVesting      = _teamVesting;
        investorVesting  = _investorVesting;
        treasury         = _treasury;
        publicSale       = _publicSale;
        reserve          = _reserve;

        // ── Mint all allocations to their locked contracts — NOT to owner ────
        // [A1] Owner wallet receives zero tokens. All allocations go to contracts.

        _mint(_communityEmitter, COMMUNITY_ALLOC);
        emit AllocationMinted("Community/Ecosystem", _communityEmitter, COMMUNITY_ALLOC);

        _mint(_polVault, POL_ALLOC);
        emit AllocationMinted("Protocol-Owned Liquidity", _polVault, POL_ALLOC);

        _mint(_teamVesting, TEAM_ALLOC);
        emit AllocationMinted("Team & Advisors", _teamVesting, TEAM_ALLOC);

        _mint(_investorVesting, INVESTOR_ALLOC);
        emit AllocationMinted("Investors/Seed", _investorVesting, INVESTOR_ALLOC);

        _mint(_treasury, TREASURY_ALLOC);
        emit AllocationMinted("Treasury", _treasury, TREASURY_ALLOC);

        _mint(_publicSale, PUBLIC_ALLOC);
        emit AllocationMinted("Public Sale (IEO)", _publicSale, PUBLIC_ALLOC);

        _mint(_reserve, RESERVE_ALLOC);
        emit AllocationMinted("Reserve", _reserve, RESERVE_ALLOC);

        // Verify total supply = 1B exactly [A3]
        require(totalSupply() == MAX_SUPPLY, "WIK: supply mismatch");

        // ── Fee discount tiers ────────────────────────────────────────────────
        tiers[0] = Tier(0,                0,  0);
        tiers[1] = Tier(  1_000 * 1e18,  10,  5);  // 1K  WIK → 10%/5%  discount
        tiers[2] = Tier( 10_000 * 1e18,  20, 10);  // 10K WIK → 20%/10%
        tiers[3] = Tier( 50_000 * 1e18,  30, 20);  // 50K WIK → 30%/20%
        tiers[4] = Tier(100_000 * 1e18,  50, 30);  // 100K WIK→ 50%/30%
    }

    // ── Public allocation viewer [A4] ─────────────────────────────────────────

    /**
     * @notice Returns the complete allocation schedule on-chain.
     *         Fully transparent — anyone can verify how tokens are distributed.
     */
    function allocationSchedule() external view returns (
        string memory note,
        uint256 totalSupply_,
        AllocationInfo[] memory allocations
    ) {
        note = "All allocations minted to locked contracts at deploy. Owner wallet received 0 tokens.";
        totalSupply_ = MAX_SUPPLY;

        allocations = new AllocationInfo[](7);
        allocations[0] = AllocationInfo("Community/Ecosystem", 40, COMMUNITY_ALLOC, communityEmitter, "4-year emission via WikiStaking + WikiGaugeVoting");
        allocations[1] = AllocationInfo("Protocol-Owned Liquidity", 15, POL_ALLOC, polVault, "Locked forever in WikiPOL. Earns LP fees. Cannot be sold.");
        allocations[2] = AllocationInfo("Team & Advisors", 15, TEAM_ALLOC, teamVesting, "1-year cliff + 3-year linear. Claim via WikiTokenVesting.");
        allocations[3] = AllocationInfo("Investors/Seed", 10, INVESTOR_ALLOC, investorVesting, "6-month cliff + 2-year linear. Claim via WikiTokenVesting.");
        allocations[4] = AllocationInfo("Treasury (DAO)", 10, TREASURY_ALLOC, treasury, "DAO-controlled. Pays salaries, grants, audits. 48h timelock.");
        allocations[5] = AllocationInfo("Public Sale (IEO)", 5, PUBLIC_ALLOC, publicSale, "Sold at TGE via WikiLaunchpad. Fully unlocked day 1.");
        allocations[6] = AllocationInfo("Reserve", 5, RESERVE_ALLOC, reserve, "2-year timelock. DAO vote required to unlock.");
    }

    struct AllocationInfo {
        string  name;
        uint256 pct;
        uint256 amount;
        address destination;
        string  vestingNote;
    }

    // ── Fee discount ──────────────────────────────────────────────────────────

    function getDiscount(address user) external view returns (
        uint256 makerDiscount,
        uint256 takerDiscount
    ) {
        uint256 bal = balanceOf(user);
        for (uint256 i = 4; i > 0; i--) {
            if (bal >= tiers[i].minWIK) {
                return (tiers[i].makerDiscount, tiers[i].takerDiscount);
            }
        }
    }

    // ── Minter management (community emissions) ───────────────────────────────

    function setMinter(address minter, bool enabled) external onlyOwner {
        minters[minter] = enabled;
        emit MinterSet(minter, enabled);
    }

    /**
     * @notice Mint additional community emissions (up to MAX_SUPPLY).
     *         Only callable by authorised minter contracts (WikiStaking, WikiGaugeVoting).
     *         Note: community allocation is pre-minted to communityEmitter.
     *         This function is for any future additional emission slots.
     */
    function mint(address to, uint256 amount) external {
        require(minters[msg.sender], "WIK: not minter");
        require(totalSupply() + amount <= MAX_SUPPLY, "WIK: max supply exceeded");
        _mint(to, amount);
    }

    // ── Required overrides ────────────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
