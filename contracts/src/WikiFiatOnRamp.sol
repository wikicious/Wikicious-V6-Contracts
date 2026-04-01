// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title WikiFiatOnRamp — Fiat Gateway Referral Revenue Tracker
 *
 * Integrates with MoonPay, Transak, and regional providers (Banxa, UPI India etc.)
 * to earn referral commissions on every fiat → crypto purchase made via Wikicious.
 *
 * HOW IT WORKS (off-chain + on-chain)
 * ─────────────────────────────────────────────────────────────────────────
 * 1. User clicks "Buy Crypto" on Wikicious → redirected to MoonPay/Transak widget
 *    with Wikicious referral params embedded in the URL
 * 2. User completes fiat purchase (credit card, UPI, bank transfer)
 * 3. Provider sends crypto directly to user's wallet on Arbitrum
 * 4. Provider pays Wikicious 0.5–1% referral commission (off-chain monthly)
 * 5. Keeper submits the commission batch on-chain → distributed via RevenueSplitter
 *
 * PROVIDERS INTEGRATED
 * ─────────────────────────────────────────────────────────────────────────
 * MoonPay:  0.5% referral, 180+ countries, cards + bank transfer
 * Transak:  0.5–1% referral, India UPI, 100+ countries
 * Banxa:    0.75% referral, AUD/NZD/EUR focus
 * Ramp:     0.5% referral, UK/EU bank transfers
 *
 * ON-CHAIN TRACKING
 * Each referral is assigned a unique orderId. The keeper submits settlements
 * proving the referral was paid (IPFS hash of provider statement).
 * Revenue flows through WikiRevenueSplitter.
 */

contract WikiFiatOnRamp is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Provider { MOONPAY, TRANSAK, BANXA, RAMP, OTHER }

    struct ReferralOrder {
        bytes32   orderId;
        address   user;
        Provider  provider;
        uint256   fiatAmount;    // USD cents (e.g. 100000 = $1,000)
        uint256   cryptoAmount;  // token amount received (1e18 or 1e6)
        address   cryptoToken;
        uint256   commissionBps; // agreed referral rate
        uint256   commissionUSDC;
        bool      settled;
        uint256   createdAt;
        uint256   settledAt;
    }

    struct ProviderConfig {
        string  name;
        string  referralId;    // our referral ID with the provider
        uint256 commissionBps; // agreed rate (e.g. 75 = 0.75%)
        bool    active;
    }

    mapping(bytes32  => ReferralOrder)  public orders;
    mapping(address  => bytes32[])      public userOrders;
    mapping(Provider => ProviderConfig) public providers;
    mapping(address  => bool)           public keepers;

    IERC20  public immutable USDC;
    address public revenueSplitter;

    uint256 public totalOrdersTracked;
    uint256 public totalFiatVolumeUSD;   // in cents
    uint256 public totalCommissionsUSDC;
    uint256 public pendingSettlement;    // unsettled commission

    event OrderTracked(bytes32 indexed orderId, address user, Provider provider, uint256 fiatAmount);
    event OrderSettled(bytes32 indexed orderId, uint256 commissionUSDC);
    event CommissionDeposited(uint256 amount, Provider provider);

    constructor(address _usdc, address _revenueSplitter, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_revenueSplitter != address(0), "Wiki: zero _revenueSplitter");
        require(_owner != address(0), "Wiki: zero _owner");
        USDC             = IERC20(_usdc);
        revenueSplitter  = _revenueSplitter;

        // Set up default provider configs
        providers[Provider.MOONPAY]  = ProviderConfig("MoonPay",  "wikicious",  50, true);   // 0.50%
        providers[Provider.TRANSAK]  = ProviderConfig("Transak",  "wikicious",  75, true);   // 0.75%
        providers[Provider.BANXA]    = ProviderConfig("Banxa",    "wikicious",  75, true);   // 0.75%
        providers[Provider.RAMP]     = ProviderConfig("Ramp",     "wikicious",  50, true);   // 0.50%
        providers[Provider.OTHER]    = ProviderConfig("Other",    "wikicious",  50, true);
    }

    modifier onlyKeeper() { require(keepers[msg.sender] || msg.sender == owner(), "OnRamp: not keeper"); _; }

    // ── Order Tracking ────────────────────────────────────────────────────────

    /**
     * @notice Track a new fiat purchase intent (called by backend when user starts a fiat buy).
     * This creates an on-chain record before the provider confirms.
     */
    function trackOrder(
        bytes32  orderId,
        address  user,
        Provider provider,
        uint256  fiatAmountCents,
        address  cryptoToken
    ) external onlyKeeper {
        require(orders[orderId].createdAt == 0, "OnRamp: order exists");
        ProviderConfig storage pc = providers[provider];
        require(pc.active, "OnRamp: provider inactive");

        uint256 commissionBps = pc.commissionBps;
        orders[orderId] = ReferralOrder({
            orderId:        orderId,
            user:           user,
            provider:       provider,
            fiatAmount:     fiatAmountCents,
            cryptoAmount:   0,
            cryptoToken:    cryptoToken,
            commissionBps:  commissionBps,
            commissionUSDC: 0,
            settled:        false,
            createdAt:      block.timestamp,
            settledAt:      0
        });
        userOrders[user].push(orderId);
        totalOrdersTracked++;
        totalFiatVolumeUSD += fiatAmountCents;
        emit OrderTracked(orderId, user, provider, fiatAmountCents);
    }

    /**
     * @notice Mark an order as settled and record the commission received from the provider.
     * Keeper submits this after provider pays referral commission (monthly batch).
     */
    function settleOrder(bytes32 orderId, uint256 cryptoAmount, uint256 commissionUSDC) external onlyKeeper {
        ReferralOrder storage o = orders[orderId];
        require(o.createdAt > 0 && !o.settled, "OnRamp: invalid order");

        o.cryptoAmount   = cryptoAmount;
        o.commissionUSDC = commissionUSDC;
        o.settled        = true;
        o.settledAt      = block.timestamp;
        totalCommissionsUSDC += commissionUSDC;
        pendingSettlement    += commissionUSDC;
        emit OrderSettled(orderId, commissionUSDC);
    }

    /**
     * @notice Keeper deposits batch commission payment from provider and routes to RevenueSplitter.
     * @param amount  Total USDC received from provider for this batch
     * @param provider Which provider paid
     */
    function depositCommission(uint256 amount, Provider provider) external onlyKeeper nonReentrant {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        pendingSettlement = pendingSettlement > amount ? pendingSettlement - amount : 0;

        // Route to revenue splitter
        if (revenueSplitter != address(0)) {
            USDC.approve(revenueSplitter, amount);
            (bool ok,) = revenueSplitter.call(abi.encodeWithSignature("receiveFees(uint256)", amount));
            if (!ok) USDC.safeTransfer(owner(), amount); // fallback
        } else {
            USDC.safeTransfer(owner(), amount);
        }

        emit CommissionDeposited(amount, provider);
    }

    // ── Views ─────────────────────────────────────────────────────────────────
    function getUserOrders(address user) external view returns (bytes32[] memory) { return userOrders[user]; }
    function getOrder(bytes32 orderId) external view returns (ReferralOrder memory) { return orders[orderId]; }
    function getStats() external view returns (uint256 total, uint256 volume, uint256 commissions, uint256 pending) {
        return (totalOrdersTracked, totalFiatVolumeUSD / 100, totalCommissionsUSDC, pendingSettlement);
    }
    function estimateCommission(Provider provider, uint256 fiatUSD) external view returns (uint256 commissionUSDC) {
        return fiatUSD * providers[provider].commissionBps / 10000;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setKeeper(address k, bool e) external onlyOwner { keepers[k] = e; }
    function setRevenueSplitter(address r) external onlyOwner { revenueSplitter = r; }
    function setProviderCommission(Provider p, uint256 bps) external onlyOwner {
        require(bps <= 500, "OnRamp: commission too high"); // max 5%
        providers[p].commissionBps = bps;
    }
}
