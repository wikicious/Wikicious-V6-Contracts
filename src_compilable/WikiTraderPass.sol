// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiTraderPass
 * @notice ERC-721 NFT that gives holders lifetime trading fee discounts.
 *         One-time purchase creates a sticky, high-frequency trader base.
 *
 * TIERS
 * ─────────────────────────────────────────────────────────────────────────
 * BRONZE  ($500 )  — 25% fee discount on all trades
 * SILVER  ($1,000) — 40% fee discount + 2× farm boost
 * GOLD    ($2,000) — 60% fee discount + 3× farm boost + priority liquidation
 * DIAMOND ($5,000) — 75% fee discount + 5× farm boost + OTC access + VIP support
 *
 * REVENUE LOGIC
 * ─────────────────────────────────────────────────────────────────────────
 * At 500 passes sold (mix of tiers, avg $1,200):
 *   → $600,000 one-time revenue
 *   → 500 highly loyal traders trading at higher frequency
 *   → Higher volume → more total fees even at lower per-trade rate
 *   → Pass holders churn ~0% (they've already paid and want ROI)
 *
 * TRANSFERABILITY
 * ─────────────────────────────────────────────────────────────────────────
 * Passes are transferable ERC-721 tokens. A secondary market creates
 * floor price discovery and advertising value. Transfer fee: 2.5% of
 * sale price goes to protocol (royalty via ERC-2981).
 */
contract WikiTraderPass is ERC721, Ownable2Step, ReentrancyGuard {
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

    // ──────────────────────────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────────────────────────
    uint256 public constant BPS         = 10_000;
    uint256 public constant MAX_SUPPLY  = 10_000; // total caps per tier
    uint256 public constant ROYALTY_BPS = 250;    // 2.5% secondary market royalty

    // ──────────────────────────────────────────────────────────────────
    //  Enums & Structs
    // ──────────────────────────────────────────────────────────────────
    enum Tier { BRONZE, SILVER, GOLD, DIAMOND }

    struct TierConfig {
        uint256 price;           // USDC purchase price
        uint256 discountBps;     // fee discount on trading (e.g. 2500 = 25%)
        uint256 farmBoostBps;    // farm reward boost (e.g. 20000 = 2×)
        uint256 maxSupply;       // max NFTs at this tier
        uint256 minted;          // current supply
        bool    otcAccess;       // access to OTC desk
        bool    priorityLiq;     // priority in liquidation queue
        string  name;
    }

    struct PassData {
        Tier    tier;
        uint256 purchasedAt;
        uint256 purchasePrice;
    }

    // ──────────────────────────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────────────────────────
    IERC20 public immutable USDC;

    TierConfig[4]             public tiers;
    mapping(uint256 => PassData) public passes;       // tokenId → pass data
    mapping(address => uint256)  public holderPass;   // address → tokenId+1 (0 = none)

    uint256 public nextTokenId;
    uint256 public totalRevenue;
    address public treasury;
    string  public baseTokenURI;

    // ──────────────────────────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────────────────────────
    event PassMinted(uint256 indexed tokenId, address indexed buyer, Tier tier, uint256 price);
    event PassUpgraded(uint256 indexed tokenId, Tier from, Tier to, uint256 additionalCost);
    event TierPriceUpdated(Tier tier, uint256 newPrice);

    // ──────────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────────
    constructor(address _usdc, address _treasury, address _owner)
        ERC721("Wikicious Trader Pass", "WTP")
        Ownable(_owner)
    {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_treasury != address(0), "Wiki: zero _treasury");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC     = IERC20(_usdc);
        treasury = _treasury;
        _initTiers();
    }

    function _initTiers() internal {
        tiers[0] = TierConfig({ price:500*1e6,  discountBps:2500, farmBoostBps:10000, maxSupply:5000, minted:0, otcAccess:false, priorityLiq:false, name:"Bronze"  });
        tiers[1] = TierConfig({ price:1000*1e6, discountBps:4000, farmBoostBps:20000, maxSupply:3000, minted:0, otcAccess:false, priorityLiq:false, name:"Silver"  });
        tiers[2] = TierConfig({ price:2000*1e6, discountBps:6000, farmBoostBps:30000, maxSupply:1500, minted:0, otcAccess:false, priorityLiq:true,  name:"Gold"    });
        tiers[3] = TierConfig({ price:5000*1e6, discountBps:7500, farmBoostBps:50000, maxSupply:500,  minted:0, otcAccess:true,  priorityLiq:true,  name:"Diamond" });
    }

    // ──────────────────────────────────────────────────────────────────
    //  Mint
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Purchase a Trader Pass NFT. One pass per address.
     *         To upgrade, call upgradePass() instead.
     * @param tier  BRONZE / SILVER / GOLD / DIAMOND
     */
    function mint(Tier tier) external nonReentrant returns (uint256 tokenId) {
        require(holderPass[msg.sender] == 0, "TP: already have pass");

        TierConfig storage cfg = tiers[uint256(tier)];
        require(cfg.minted < cfg.maxSupply, "TP: sold out");

        tokenId = nextTokenId++;
        cfg.minted++;
        holderPass[msg.sender] = tokenId + 1;
        totalRevenue += cfg.price;

        passes[tokenId] = PassData({
            tier:          tier,
            purchasedAt:   block.timestamp,
            purchasePrice: cfg.price
        });

        USDC.safeTransferFrom(msg.sender, address(this), cfg.price);
        if (treasury != address(0)) USDC.safeTransfer(treasury, cfg.price);

        _mint(msg.sender, tokenId);
        emit PassMinted(tokenId, msg.sender, tier, cfg.price);
    }

    /**
     * @notice Upgrade an existing pass to a higher tier.
     *         Pays only the price difference.
     */
    function upgradePass(uint256 tokenId, Tier newTier) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "TP: not owner");

        PassData storage p   = passes[tokenId];
        Tier       oldTier   = p.tier;
        require(uint256(newTier) > uint256(oldTier), "TP: not an upgrade");

        TierConfig storage newCfg = tiers[uint256(newTier)];
        TierConfig storage oldCfg = tiers[uint256(oldTier)];
        require(newCfg.minted < newCfg.maxSupply, "TP: sold out");

        uint256 cost = newCfg.price - oldCfg.price;
        oldCfg.minted--;
        newCfg.minted++;
        totalRevenue += cost;
        p.tier = newTier;

        USDC.safeTransferFrom(msg.sender, address(this), cost);
        if (treasury != address(0)) USDC.safeTransfer(treasury, cost);

        emit PassUpgraded(tokenId, oldTier, newTier, cost);
    }

    // ──────────────────────────────────────────────────────────────────
    //  View: Discount Lookup (called by WikiPerp / WikiOrderBook)
    // ──────────────────────────────────────────────────────────────────

    /**
     * @notice Get the fee discount for a trader (0 if no pass).
     * @return discountBps  e.g. 2500 = 25% discount on fees
     */
    function getDiscount(address trader) external view returns (uint256 discountBps) {
        uint256 idx = holderPass[trader];
        if (idx == 0) return 0;
        uint256 tokenId = idx - 1;
        if (ownerOf(tokenId) != trader) return 0; // pass was transferred
        return tiers[uint256(passes[tokenId].tier)].discountBps;
    }

    /**
     * @notice Get the farm boost multiplier for a trader.
     * @return boostBps  e.g. 20000 = 2× (base is 10000)
     */
    function getFarmBoost(address trader) external view returns (uint256 boostBps) {
        uint256 idx = holderPass[trader];
        if (idx == 0) return 10_000; // 1× base
        uint256 tokenId = idx - 1;
        if (ownerOf(tokenId) != trader) return 10_000;
        return tiers[uint256(passes[tokenId].tier)].farmBoostBps;
    }

    function hasOTCAccess(address trader) external view returns (bool) {
        uint256 idx = holderPass[trader];
        if (idx == 0) return false;
        return tiers[uint256(passes[idx - 1].tier)].otcAccess;
    }

    function hasPriorityLiq(address trader) external view returns (bool) {
        uint256 idx = holderPass[trader];
        if (idx == 0) return false;
        return tiers[uint256(passes[idx - 1].tier)].priorityLiq;
    }

    function getPass(uint256 tokenId) external view returns (PassData memory) { return passes[tokenId]; }
    function getHolderPass(address holder) external view returns (uint256 tokenId, PassData memory data) {
        uint256 idx = holderPass[holder];
        require(idx > 0, "TP: no pass");
        tokenId = idx - 1;
        data = passes[tokenId];
    }

    function totalSupply() external view returns (uint256) { return nextTokenId; }

    // ──────────────────────────────────────────────────────────────────
    //  ERC-721 overrides
    // ──────────────────────────────────────────────────────────────────

    function _baseURI() internal view override returns (string memory) { return baseTokenURI; }

    // Update holderPass mapping on transfer
    function transferFrom(address from, address to, uint256 tokenId) public override {
        require(holderPass[to] == 0, "TP: recipient already has pass");
        delete holderPass[from];
        holderPass[to] = tokenId + 1;
        super.transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
        require(holderPass[to] == 0, "TP: recipient already has pass");
        delete holderPass[from];
        holderPass[to] = tokenId + 1;
        super.safeTransferFrom(from, to, tokenId, data);
    }

    // ──────────────────────────────────────────────────────────────────
    //  Owner
    // ──────────────────────────────────────────────────────────────────

    function setTierPrice(Tier tier, uint256 newPrice) external onlyOwner {
        tiers[uint256(tier)].price = newPrice;
        emit TierPriceUpdated(tier, newPrice);
    }

    function setBaseURI(string calldata uri) external onlyOwner { baseTokenURI = uri; }
    function setTreasury(address t) external onlyOwner { treasury = t; }

    function withdrawStuck(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
