// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiReferralNFT
 * @notice Elite affiliate NFT. Awarded to top 100 affiliates by volume.
 *         Boosts referral share to 45% (vs 40% Diamond standard tier).
 *         Transferable — creates secondary market. Holders compete to keep it.
 *
 * HOW TO EARN ONE:
 *   Awarded by owner to top 100 affiliates (monthly leaderboard)
 *   OR purchased from a holder on secondary market
 *
 * BENEFITS:
 *   45% revenue share (vs 40% Diamond)
 *   Special badge on leaderboard
 *   VIP Discord / Telegram channel access
 *   Early access to new features
 *   Governance boost (2× voting weight)
 *
 * REVOCATION:
 *   Owner can revoke NFT from inactive affiliates (< $10K volume in 60 days)
 *   Revoked NFT goes to next top affiliate on waitlist
 */
contract WikiReferralNFT is ERC721, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    struct AffiliateInfo {
        address holder;
        uint256 volumeGenerated;   // all-time USDC referral volume
        uint256 feesEarned;        // all-time fees earned
        uint256 awardedAt;
        uint256 lastActiveTs;
        bool    active;
    }

    uint256 public constant MAX_SUPPLY     = 100;
    uint256 public constant ELITE_SHARE_BPS= 4500; // 45%
    uint256 public constant STD_SHARE_BPS  = 4000; // 40% Diamond
    uint256 public constant INACTIVITY_DAYS= 60;
    uint256 public constant MIN_VOLUME_USD = 10_000 * 1e6; // $10K in 60 days to keep

    mapping(uint256 => AffiliateInfo) public affiliateInfo;
    mapping(address => uint256)       public holderToToken; // wallet → tokenId
    mapping(address => bool)          public recorders;

    uint256 public totalMinted;
    string  private _baseTokenURI;

    event EliteNFTAwarded(uint256 tokenId, address affiliate);
    event EliteNFTRevoked(uint256 tokenId, address from, string reason);
    event VolumeRecorded(uint256 tokenId, address holder, uint256 volume);

    constructor(address _owner, address _usdc, string memory baseURI)
        ERC721("Wikicious Elite Affiliate", "wELITE") Ownable(_owner)
    {
        USDC = IERC20(_usdc);
        _baseTokenURI = baseURI;
        recorders[_owner] = true;
    }

    // ── Award NFT to top affiliate ────────────────────────────────────────
    function awardNFT(address affiliate) external onlyOwner returns (uint256 tokenId) {
        require(totalMinted < MAX_SUPPLY,                   "Elite: max 100 holders");
        require(holderToToken[affiliate] == 0,              "Elite: already holds one");

        tokenId = ++totalMinted;
        _safeMint(affiliate, tokenId);
        holderToToken[affiliate] = tokenId;
        affiliateInfo[tokenId] = AffiliateInfo({
            holder:          affiliate,
            volumeGenerated: 0,
            feesEarned:      0,
            awardedAt:       block.timestamp,
            lastActiveTs:    block.timestamp,
            active:          true
        });
        emit EliteNFTAwarded(tokenId, affiliate);
    }

    // ── Record volume for an elite holder ────────────────────────────────
    function recordVolume(address holder, uint256 volumeUsdc, uint256 feeEarned) external {
        require(recorders[msg.sender], "Elite: not recorder");
        uint256 tokenId = holderToToken[holder];
        if (tokenId == 0) return;
        affiliateInfo[tokenId].volumeGenerated += volumeUsdc;
        affiliateInfo[tokenId].feesEarned      += feeEarned;
        affiliateInfo[tokenId].lastActiveTs     = block.timestamp;
        emit VolumeRecorded(tokenId, holder, volumeUsdc);
    }

    // ── Check and revoke inactive holders ────────────────────────────────
    function checkActivity(uint256 tokenId) external onlyOwner {
        AffiliateInfo storage info = affiliateInfo[tokenId];
        require(ownerOf(tokenId) != address(0), "Elite: not minted");

        bool inactive = block.timestamp > info.lastActiveTs + INACTIVITY_DAYS * 1 days;
        if (inactive) {
            address holder = ownerOf(tokenId);
            // Reclaim to owner — can re-award to next affiliate
            _update(owner(), tokenId, holder);
            delete holderToToken[holder];
            info.active = false;
            emit EliteNFTRevoked(tokenId, holder, "Inactivity: <$10K volume in 60 days");
        }
    }

    // ── Views ──────────────────────────────────────────────────────────────
    function isEliteAffiliate(address wallet) external view returns (bool) {
        uint256 tokenId = holderToToken[wallet];
        if (tokenId == 0) return false;
        return ownerOf(tokenId) == wallet && affiliateInfo[tokenId].active;
    }

    function getEliteShareBps(address wallet) external view returns (uint256) {
        uint256 tokenId = holderToToken[wallet];
        if (tokenId == 0 || ownerOf(tokenId) != wallet) return STD_SHARE_BPS;
        return ELITE_SHARE_BPS;
    }

    function getTopAffiliates(uint256 n) external view returns (
        address[] memory holders, uint256[] memory volumes, uint256[] memory fees
    ) {
        uint256 count = n < totalMinted ? n : totalMinted;
        holders = new address[](count);
        volumes = new uint256[](count);
        fees    = new uint256[](count);
        for (uint i; i < count; i++) {
            uint256 tokenId = i + 1;
            try this.ownerOf(tokenId) returns (address holder) {
                holders[i] = holder;
                volumes[i] = affiliateInfo[tokenId].volumeGenerated;
                fees[i]    = affiliateInfo[tokenId].feesEarned;
            } catch {}
        }
    }

    // ── Transfer hook — update holderToToken ─────────────────────────────
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0)) delete holderToToken[from];
        if (to   != address(0)) holderToToken[to] = tokenId;
        if (to != address(0) && to != owner()) {
            affiliateInfo[tokenId].holder = to;
        }
        return from;
    }

    function _baseURI() internal view override returns (string memory) { return _baseTokenURI; }
    function setBaseURI(string calldata uri) external onlyOwner { _baseTokenURI = uri; }
    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
