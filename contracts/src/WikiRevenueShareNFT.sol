// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WikiRevenueShareNFT
 * @notice Limited 1,000 NFT collection. Each NFT earns 0.01% of all
 *         protocol fees forever. Total 10% of fees split among holders.
 *
 * ECONOMICS:
 *   Mint price:   500 USDC per NFT
 *   Total supply: 1,000 NFTs
 *   Mint revenue: $500,000 upfront to protocol
 *   Each NFT:     0.01% of all fees forever
 *   All 1,000:    10% of all fees
 *
 * AT $10M DAILY VOLUME:
 *   Monthly fees: $210,000
 *   10% to NFTs:  $21,000/month split among 1,000 holders
 *   Per NFT:      $21/month → $252/year
 *   At $500 mint: 2-year payback, then pure profit forever
 *
 * AT $100M DAILY VOLUME:
 *   Per NFT:      $210/month → $2,520/year
 *   NFT secondary value: $10,000+ (perpetual income stream)
 *
 * HOLDER BENEFITS:
 *   - Perpetual fee share (0.01% each)
 *   - Governance voting weight (1 vote per NFT)
 *   - VIP trading fee discount (10% reduced fees)
 *   - Early access to new features
 *   - Transferable — can sell on secondary market
 */
contract WikiRevenueShareNFT is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    uint256 public constant MAX_SUPPLY         = 1000;
    uint256 public constant MINT_PRICE         = 500 * 1e6;  // $500 USDC
    uint256 public constant SHARE_PER_NFT_BPS  = 1;          // 0.01% per NFT
    uint256 public constant BPS                = 10_000;

    uint256 public totalMinted;
    uint256 public totalFeesDeposited;
    uint256 public totalFeesClaimed;

    // Accumulated fees per token (scaled by 1e18 for precision)
    uint256 public accFeesPerToken;
    mapping(uint256 => uint256) public tokenDebt;   // tokenId → fees already accounted for
    mapping(uint256 => uint256) public tokenClaimed; // tokenId → total USDC claimed

    bool public mintOpen;
    string private _baseTokenURI;

    
    event FeesDeposited(uint256 amount, uint256 newAccPerToken);
    event FeeClaimed(uint256 indexed tokenId, address indexed owner, uint256 amount);

    constructor(
        address _owner,
        address _usdc,
        string memory baseURI
    ) ERC721("Wikicious Revenue Share", "wREV") Ownable(_owner) {
        USDC = IERC20(_usdc);
        _baseTokenURI = baseURI;
    }

    // ── Minting ───────────────────────────────────────────────────────────
    function mint(uint256 quantity) external nonReentrant {
        require(mintOpen,                              "NFT: mint not open");
        require(totalMinted + quantity <= MAX_SUPPLY,  "NFT: sold out");
        require(quantity >= 1 && quantity <= 10,       "NFT: 1-10 per tx");

        uint256 cost = MINT_PRICE * quantity;
        USDC.safeTransferFrom(msg.sender, address(this), cost);

        for (uint i; i < quantity; i++) {
            uint256 id = ++totalMinted;
            _safeMint(msg.sender, id);
            tokenDebt[id] = accFeesPerToken; // new token starts with current acc
            emit Minted(msg.sender, id);
        }
    }

    // ── Fee distribution — called by WikiRevenueSplitter ─────────────────
    function depositFees(uint256 amount) external {
        require(amount > 0, "NFT: zero fees");
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        if (totalMinted > 0) {
            accFeesPerToken += amount * 1e18 / totalMinted;
        }
        totalFeesDeposited += amount;
        emit FeesDeposited(amount, accFeesPerToken);
    }

    // ── Claim accumulated fees ────────────────────────────────────────────
    function claimFees(uint256 tokenId) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "NFT: not owner");
        uint256 pending = _pendingFees(tokenId);
        require(pending > 0, "NFT: nothing to claim");

        tokenDebt[tokenId]    = accFeesPerToken;
        tokenClaimed[tokenId] += pending;
        totalFeesClaimed      += pending;

        USDC.safeTransfer(msg.sender, pending);
        emit FeeClaimed(tokenId, msg.sender, pending);
    }

    function claimAllFees(uint256[] calldata tokenIds) external nonReentrant {
        uint256 total;
        for (uint i; i < tokenIds.length; i++) {
            require(ownerOf(tokenIds[i]) == msg.sender, "NFT: not owner");
            uint256 pending = _pendingFees(tokenIds[i]);
            if (pending > 0) {
                tokenDebt[tokenIds[i]]    = accFeesPerToken;
                tokenClaimed[tokenIds[i]] += pending;
                total += pending;
            }
        }
        require(total > 0, "NFT: nothing to claim");
        totalFeesClaimed += total;
        USDC.safeTransfer(msg.sender, total);
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function pendingFees(uint256 tokenId) external view returns (uint256) {
        return _pendingFees(tokenId);
    }

    function pendingFeesAll(address holder) external view returns (uint256 total) {
        uint256 balance = balanceOf(holder);
        // Note: ERC721 doesn't have enumerable by default — frontend enumerates
        // This is a placeholder — production uses ERC721Enumerable
        return total;
    }

    function projectedAnnualYield(uint256 dailyVolumeUsdc) external pure returns (
        uint256 perNftPerMonth, uint256 perNftPerYear, uint256 paybackMonths
    ) {
        uint256 dailyFees        = dailyVolumeUsdc * 7 / 10000; // 0.07% blended
        uint256 monthlyFees      = dailyFees * 30;
        uint256 nftShareMonthly  = monthlyFees * 10 / 100;      // 10% total to NFTs
        perNftPerMonth           = nftShareMonthly / MAX_SUPPLY;
        perNftPerYear            = perNftPerMonth * 12;
        paybackMonths            = perNftPerMonth > 0 ? MINT_PRICE / perNftPerMonth : 9999;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _pendingFees(uint256 tokenId) internal view returns (uint256) {
        uint256 acc = accFeesPerToken - tokenDebt[tokenId];
        return acc / 1e18; // scale back down
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        // Claim on transfer — fees go to old owner before transfer
        if (from != address(0) && to != address(0)) {
            uint256 pending = _pendingFees(tokenId);
            if (pending > 0) {
                tokenClaimed[tokenId] += pending;
                totalFeesClaimed      += pending;
                USDC.safeTransfer(from, pending);
            }
        }
        tokenDebt[tokenId] = accFeesPerToken;
        return from;
    }

    function _baseURI() internal view override returns (string memory) { return _baseTokenURI; }

    function setMintOpen(bool open) external onlyOwner { mintOpen = open; }
    function setBaseURI(string calldata uri) external onlyOwner { _baseTokenURI = uri; }
    function withdrawMintRevenue(address to) external onlyOwner {
        uint256 bal = USDC.balanceOf(address(this)) - (totalFeesDeposited - totalFeesClaimed);
        if (bal > 0) USDC.safeTransfer(to, bal);
    }
}
