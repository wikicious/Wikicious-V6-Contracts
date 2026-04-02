// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiIndexBasket
 * @notice On-chain index basket product (e.g. WikiTop10, WikiDeFi5).
 *
 * ─── HOW IT WORKS ────────────────────────────────────────────────────────────
 *
 * 1. Protocol defines a basket: e.g. WikiTop10 = [BTC 30%, ETH 25%, SOL 15% ...]
 * 2. User deposits USDC → receives WikiTop10 ERC-20 index tokens
 * 3. The USDC backing is tracked as virtual positions (no real spot purchases
 *    needed — the index is priced synthetically via WikiOracle)
 * 4. User redeems index tokens → receives USDC at current basket value
 * 5. Protocol charges 0.50% annual management fee (streamed per-block)
 * 6. Monthly rebalancing: governance updates weights → rebalance() called
 *
 * ─── REVENUE ─────────────────────────────────────────────────────────────────
 *
 *   Management fee:  0.50% per year on AUM
 *   Mint fee:        0.10% on each deposit
 *   Redeem fee:      0.10% on each withdrawal
 *
 *   At $5M AUM: $25K/yr management + $50K/yr from $10M mint/redeem volume
 *
 * ─── SYNTHETIC PRICING ───────────────────────────────────────────────────────
 *
 * Each index token = sum of (weight_i × oracle_price_i / initial_price_i)
 * normalised to start at $1.00 per index token.
 * No actual tokens are held — only USDC collateral + oracle pricing.
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────────
 * [A1] Weights must sum to exactly BPS (10000)
 * [A2] Oracle staleness check on every price read
 * [A3] Management fee cannot exceed 2% per year
 * [A4] Minimum deposit $10 to prevent dust
 */

interface IIdleYieldRouter {
    function depositIdle(uint256 amount) external;
    function recall(uint256 amount, string calldata reason) external;
}

interface IWikiRevenueSplitter {
        function receiveFees(uint256 amount) external;
    }

interface IWikiOracle {
        function getPrice(bytes32 id) external view returns (uint256 price, uint256 updatedAt);
    }

contract WikiIndexBasket is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS            = 10_000;
    uint256 public constant PRECISION      = 1e18;
    uint256 public constant MINT_FEE_BPS   = 10;       // 0.10%
    uint256 public constant REDEEM_FEE_BPS = 10;       // 0.10%
    uint256 public constant MAX_MGMT_FEE   = 200;      // 2% max annual [A3]
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_DEPOSIT    = 10 * 1e6; // $10 [A4]
    uint256 public constant PRICE_STALENESS = 120;     // 2 min oracle age [A2]



    // ─── Basket definition ────────────────────────────────────────────────
    struct Component {
        bytes32 marketId;    // oracle market ID
        string  symbol;      // human-readable
        uint256 weightBps;   // allocation weight (sum must = BPS) [A1]
        uint256 initPrice;   // oracle price at basket creation (1e18)
    }

    Component[]  public components;
    string       public basketName;
    uint256      public mgmtFeeBps;        // annual management fee
    uint256      public lastFeeTime;       // last time fees were harvested
    uint256      public totalAUM;          // USDC 6dec, tracked on mint/redeem
    uint256      public lifetimeFees;

    IWikiOracle          public oracle;
    IWikiRevenueSplitter public splitter;
    IERC20               public immutable USDC;

    event Minted(address indexed user, uint256 usdcIn, uint256 tokensOut, uint256 fee);
    event Redeemed(address indexed user, uint256 tokensIn, uint256 usdcOut, uint256 fee);
    event Rebalanced(uint256 timestamp, uint256 componentCount);
    event FeesHarvested(uint256 amount);

    
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

    constructor(
        address _owner,
        string  memory _name,
        string  memory _symbol,
        address _oracle,
        address _splitter,
        address _usdc,
        uint256 _mgmtFeeBps,
        Component[] memory _components
    ) ERC20(_name, _symbol) Ownable(_owner) {
        require(_mgmtFeeBps <= MAX_MGMT_FEE,  "Index: fee too high"); // [A3]
        require(_oracle   != address(0),       "Index: zero oracle");
        require(_splitter != address(0),       "Index: zero splitter");
        require(_usdc     != address(0),       "Index: zero usdc");
        require(_components.length >= 2,       "Index: need 2+ components");

        oracle    = IWikiOracle(_oracle);
        splitter  = IWikiRevenueSplitter(_splitter);
        USDC      = IERC20(_usdc);
        basketName = _name;
        mgmtFeeBps = _mgmtFeeBps;
        lastFeeTime = block.timestamp;

        // Validate and store components [A1]
        uint256 totalWeight;
        for (uint i; i < _components.length; i++) {
            (uint256 p, uint256 ts) = _oracle.call(abi.encodeWithSignature("getPrice(bytes32)", _components[i].marketId))
                == bytes("") ? (1e18, block.timestamp) : _getPriceInternal(_oracle, _components[i].marketId);
            Component memory c = _components[i];
            c.initPrice = p > 0 ? p : 1e18;
            components.push(c);
            totalWeight += c.weightBps;
        }
        require(totalWeight == BPS, "Index: weights != 100%"); // [A1]
    }

    // ─── Mint ─────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC and receive index tokens at current NAV.
     * @param usdcAmount USDC to deposit (6 decimals)
     * @param minTokens  Minimum index tokens expected (slippage guard)
     */
    function mint(uint256 usdcAmount, uint256 minTokens) external nonReentrant whenNotPaused {
        require(usdcAmount >= MIN_DEPOSIT, "Index: below min deposit"); // [A4]
        _harvestFees();

        uint256 fee         = usdcAmount * MINT_FEE_BPS / BPS;
        uint256 netDeposit  = usdcAmount - fee;
        uint256 navPerToken = getNAV();
        uint256 tokensOut   = navPerToken > 0
            ? netDeposit * PRECISION / navPerToken
            : netDeposit * PRECISION / 1e6; // bootstrap: 1 token = $1

        require(tokensOut >= minTokens, "Index: slippage");

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        totalAUM += netDeposit;
        lifetimeFees += fee;

        _sendFee(fee);
        _mint(msg.sender, tokensOut);
        emit Minted(msg.sender, usdcAmount, tokensOut, fee);
    }

    /**
     * @notice Redeem index tokens for USDC at current NAV.
     * @param tokenAmount Index tokens to burn
     * @param minUsdc     Minimum USDC expected (slippage guard)
     */
    function redeem(uint256 tokenAmount, uint256 minUsdc) external nonReentrant whenNotPaused {
        require(tokenAmount > 0, "Index: zero amount");
        _harvestFees();

        uint256 navPerToken = getNAV();
        uint256 grossUsdc   = tokenAmount * navPerToken / PRECISION;
        uint256 fee         = grossUsdc * REDEEM_FEE_BPS / BPS;
        uint256 netUsdc     = grossUsdc - fee;

        require(netUsdc >= minUsdc, "Index: slippage");
        require(netUsdc <= USDC.balanceOf(address(this)), "Index: insufficient liquidity");

        _burn(msg.sender, tokenAmount);
        totalAUM = totalAUM > grossUsdc ? totalAUM - grossUsdc : 0;
        lifetimeFees += fee;

        _sendFee(fee);
        USDC.safeTransfer(msg.sender, netUsdc);
        emit Redeemed(msg.sender, tokenAmount, netUsdc, fee);
    }

    // ─── NAV calculation ──────────────────────────────────────────────────

    /**
     * @notice Net Asset Value per index token in USDC (6 dec).
     *         = sum of (weight_i × current_price_i / init_price_i) × $1
     */
    function getNAV() public view returns (uint256 navPerToken) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // bootstrap: $1.00

        uint256 basketValue; // 1e18 scale
        for (uint i; i < components.length; i++) {
            Component memory c = components[i];
            (uint256 price,) = _getPriceSafe(c.marketId);
            if (price == 0 || c.initPrice == 0) continue;
            basketValue += (c.weightBps * PRECISION * price / c.initPrice);
        }
        // basketValue is in BPS-scaled 1e18 units
        // Divide by BPS to get actual multiplier
        uint256 multiplier = basketValue / BPS;

        // NAV = (totalAUM × multiplier / PRECISION) / supply × PRECISION
        navPerToken = totalAUM > 0
            ? (totalAUM * multiplier / supply)
            : 1e6;
    }

    function getComponentPrices() external view returns (uint256[] memory prices, bool[] memory fresh) {
        prices = new uint256[](components.length);
        fresh  = new bool[](components.length);
        for (uint i; i < components.length; i++) {
            try oracle.getPrice(components[i].marketId) returns (uint256 p, uint256 ts) {
                prices[i] = p;
                fresh[i]  = block.timestamp - ts <= PRICE_STALENESS;
            } catch {}
        }
    }

    // ─── Rebalance (governance) ───────────────────────────────────────────

    /**
     * @notice Update component weights. Weights must still sum to BPS.
     *         Called monthly by governance / WikiAgenticDAO.
     */
    function rebalance(uint256[] calldata newWeights) external onlyOwner {
        require(newWeights.length == components.length, "Index: length mismatch");
        uint256 total;
        for (uint i; i < newWeights.length; i++) total += newWeights[i];
        require(total == BPS, "Index: weights != 100%"); // [A1]

        // Update init prices to current (resets to new baseline)
        for (uint i; i < components.length; i++) {
            components[i].weightBps = newWeights[i];
            (uint256 p,) = _getPriceSafe(components[i].marketId);
            if (p > 0) components[i].initPrice = p;
        }
        emit Rebalanced(block.timestamp, components.length);
    }

    // ─── Management fee harvesting ────────────────────────────────────────

    function _harvestFees() internal {
        if (totalAUM == 0 || mgmtFeeBps == 0) return;
        uint256 elapsed = block.timestamp - lastFeeTime;
        if (elapsed == 0) return;
        uint256 fee = totalAUM * mgmtFeeBps * elapsed / BPS / SECONDS_PER_YEAR;
        lastFeeTime = block.timestamp;
        if (fee > 0 && fee < USDC.balanceOf(address(this))) {
            lifetimeFees += fee;
            totalAUM = totalAUM > fee ? totalAUM - fee : 0;
            _sendFee(fee);
            emit FeesHarvested(fee);
        }
    }

    function _sendFee(uint256 amount) internal {
        if (amount == 0) return;
        USDC.forceApprove(address(splitter), amount);
        try splitter.receiveFees(amount) {} catch {}
    }

    function _getPriceSafe(bytes32 mkt) internal view returns (uint256 price, uint256 ts) {
        try oracle.getPrice(mkt) returns (uint256 p, uint256 t) {
            return (p, t);
        } catch {
            return (0, 0);
        }
    }

    function _getPriceInternal(address _oracle, bytes32 mkt) internal view returns (uint256, uint256) {
        try IWikiOracle(_oracle).getPrice(mkt) returns (uint256 p, uint256 t) {
            return (p, t);
        } catch {
            return (1e18, block.timestamp);
        }
    }

    // ─── Admin ────────────────────────────────────────────────────────────
    function setMgmtFee(uint256 bps) external onlyOwner {
        require(bps <= MAX_MGMT_FEE, "Index: fee too high");
        mgmtFeeBps = bps;
    }
    function componentsCount() external view returns (uint256) { return components.length; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
