// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WikiMultiCollateral
 * @notice Deposit BTC, ETH, or other assets as margin collateral.
 *         Trade without converting to USDC. Biggest TVL multiplier available.
 *
 * SUPPORTED COLLATERAL (at launch):
 *   WBTC  — 80% LTV, Chainlink BTC/USD feed
 *   WETH  — 85% LTV, Chainlink ETH/USD feed
 *   wstETH— 80% LTV, needs ETH/USD + stETH ratio
 *   ARB   — 70% LTV, higher haircut due to lower liquidity
 *   USDC  — 100% LTV (base collateral, always accepted)
 *
 * LTV = Loan-to-Value = how much USDC buying power per $1 of collateral
 *   e.g. $10,000 WBTC at 80% LTV = $8,000 USDC margin buying power
 *
 * HEALTH FACTOR:
 *   health = (collateral_value_usd × LTV) / margin_used
 *   < 1.0 = liquidatable
 *   < 1.1 = danger zone (WikiLiqProtection triggers here)
 *   > 1.5 = healthy
 *
 * REVENUE:
 *   Liquidation fee: 0.5% of liquidated collateral value
 *   Protocol earns on every collateral liquidation
 *   TVL multiplier: 100 ETH depositors × $3,000 avg × 10× = massive volume
 */
interface IOracle {
        function getPrice(string calldata symbol) external view returns (uint256 price, uint256 timestamp);
    }

contract WikiMultiCollateral is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;


    struct CollateralAsset {
        address token;
        string  symbol;
        uint256 ltvBps;           // e.g. 8000 = 80% LTV
        uint256 liquidationBps;   // liquidation threshold, e.g. 8500 = 85%
        uint256 liquidationFeeBps;// fee on liquidation, e.g. 50 = 0.5%
        uint256 priceFeedId;      // oracle market ID
        bool    enabled;
        uint256 totalDeposited;   // protocol-wide total of this asset
        uint256 depositCap;       // max total deposit of this asset
    }

    struct UserCollateral {
        address token;
        uint256 amount;           // raw token amount
        uint256 valueUsd;         // last known USD value (6 dec)
        uint256 lastUpdate;
    }

    struct MarginAccount {
        address trader;
        UserCollateral[] collaterals;
        uint256 totalCollateralUsd; // sum of all collateral × LTV
        uint256 marginUsed;         // USDC equivalent margin in open positions
        uint256 lastHealthUpdate;
    }

    mapping(address => MarginAccount)         public accounts;
    mapping(uint256 => CollateralAsset)       public assets;      // assetId → config
    mapping(address => uint256)               public tokenToAsset; // token → assetId
    mapping(address => bool)                  public liquidators;

    IOracle public oracle;
    address public revenueSplitter;
    uint256 public nextAssetId;

    uint256 public constant BPS         = 10_000;
    uint256 public constant MIN_HEALTH  = 10_000; // 1.0 = liquidatable
    uint256 public constant WARN_HEALTH = 11_000; // 1.1 = danger

    event CollateralDeposited(address indexed trader, address token, uint256 amount, uint256 valueUsd);
    event CollateralWithdrawn(address indexed trader, address token, uint256 amount);
    event CollateralLiquidated(address indexed trader, address token, uint256 amount, uint256 fee);
    event AssetAdded(uint256 assetId, address token, string symbol, uint256 ltvBps);
    event HealthUpdated(address indexed trader, uint256 healthFactor);

    constructor(address _owner, address _oracle, address _revenueSplitter) Ownable(_owner) {
        oracle          = IOracle(_oracle);
        revenueSplitter = _revenueSplitter;
        liquidators[_owner] = true;
        _initDefaultAssets();
    }

    function _initDefaultAssets() internal {
        // USDC — 100% LTV
        _addAsset(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, "USDC",   10000, 10000, 0,   0, type(uint256).max);
        // WETH — 85% LTV
        _addAsset(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, "ETH/USD", 8500,  9000,  50,  1, 100_000 * 1e18);
        // WBTC — 80% LTV
        _addAsset(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f, "BTC/USD", 8000,  8500,  50,  2, 1_000 * 1e8);
        // ARB  — 70% LTV
        _addAsset(0x912CE59144191C1204E64559FE8253a0e49E6548, "ARB/USD", 7000,  7500,  100, 3, 5_000_000 * 1e18);
    }

    function _addAsset(address token, string memory symbol, uint256 ltv, uint256 liqThresh, uint256 liqFee, uint256 feedId, uint256 cap) internal {
        uint256 id = nextAssetId++;
        assets[id] = CollateralAsset({
            token: token, symbol: symbol, ltvBps: ltv,
            liquidationBps: liqThresh, liquidationFeeBps: liqFee,
            priceFeedId: feedId, enabled: true,
            totalDeposited: 0, depositCap: cap
        });
        tokenToAsset[token] = id;
        emit AssetAdded(id, token, symbol, ltv);
    }

    // ── Deposit collateral ────────────────────────────────────────────────
    function depositCollateral(address token, uint256 amount) external nonReentrant whenNotPaused {
        uint256 assetId = tokenToAsset[token];
        CollateralAsset storage asset = assets[assetId];
        require(asset.enabled, "MC: asset not supported");
        require(asset.totalDeposited + amount <= asset.depositCap, "MC: deposit cap reached");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        asset.totalDeposited += amount;

        // Find or create collateral entry
        MarginAccount storage acc = accounts[msg.sender];
        if (acc.trader == address(0)) acc.trader = msg.sender;

        bool found;
        for (uint i; i < acc.collaterals.length; i++) {
            if (acc.collaterals[i].token == token) {
                acc.collaterals[i].amount += amount;
                found = true; break;
            }
        }
        if (!found) {
            acc.collaterals.push(UserCollateral({ token: token, amount: amount, valueUsd: 0, lastUpdate: 0 }));
        }

        uint256 valueUsd = _getCollateralValueUsd(assetId, amount);
        emit CollateralDeposited(msg.sender, token, amount, valueUsd);
        _updateAccountHealth(msg.sender);
    }

    // ── Withdraw collateral ────────────────────────────────────────────────
    function withdrawCollateral(address token, uint256 amount) external nonReentrant {
        MarginAccount storage acc = accounts[msg.sender];
        for (uint i; i < acc.collaterals.length; i++) {
            if (acc.collaterals[i].token == token) {
                require(acc.collaterals[i].amount >= amount, "MC: insufficient collateral");
                acc.collaterals[i].amount -= amount;
                assets[tokenToAsset[token]].totalDeposited -= amount;
                // Health check after withdrawal
                _updateAccountHealth(msg.sender);
                require(_getHealthFactor(msg.sender) >= MIN_HEALTH * 120 / 100, "MC: would go below safe health");
                IERC20(token).safeTransfer(msg.sender, amount);
                emit CollateralWithdrawn(msg.sender, token, amount);
                return;
            }
        }
        revert("MC: no collateral of this token");
    }

    // ── Liquidation ───────────────────────────────────────────────────────
    function liquidate(address trader, address token) external nonReentrant {
        require(liquidators[msg.sender], "MC: not liquidator");
        _updateAccountHealth(trader);
        uint256 health = _getHealthFactor(trader);
        require(health < MIN_HEALTH, "MC: account healthy");

        MarginAccount storage acc = accounts[trader];
        for (uint i; i < acc.collaterals.length; i++) {
            if (acc.collaterals[i].token == token && acc.collaterals[i].amount > 0) {
                uint256 amount   = acc.collaterals[i].amount;
                uint256 assetId  = tokenToAsset[token];
                uint256 feePct   = assets[assetId].liquidationFeeBps;
                uint256 feeAmt   = amount * feePct / BPS;
                uint256 netAmt   = amount - feeAmt;

                acc.collaterals[i].amount = 0;
                assets[assetId].totalDeposited -= amount;

                // Fee to revenue splitter
                if (feeAmt > 0) IERC20(token).safeTransfer(revenueSplitter, feeAmt);
                // Remaining to liquidator
                IERC20(token).safeTransfer(msg.sender, netAmt);

                emit CollateralLiquidated(trader, token, amount, feeAmt);
                return;
            }
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function getHealthFactor(address trader) external view returns (uint256) {
        return _getHealthFactor(trader);
    }

    function getAvailableMargin(address trader) external view returns (uint256 availableUsd) {
        MarginAccount storage acc = accounts[trader];
        _updateAccountHealthView(trader, availableUsd);
        uint256 total = _getTotalCollateralUsd(trader);
        uint256 used  = acc.marginUsed;
        return total > used ? total - used : 0;
    }

    function getAccountSummary(address trader) external view returns (
        uint256 totalCollateralUsd,
        uint256 marginUsed,
        uint256 availableMargin,
        uint256 healthFactor,
        UserCollateral[] memory collaterals
    ) {
        MarginAccount storage acc = accounts[trader];
        totalCollateralUsd = _getTotalCollateralUsd(trader);
        marginUsed         = acc.marginUsed;
        availableMargin    = totalCollateralUsd > marginUsed ? totalCollateralUsd - marginUsed : 0;
        healthFactor       = _getHealthFactor(trader);
        collaterals        = acc.collaterals;
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _getCollateralValueUsd(uint256 assetId, uint256 amount) internal view returns (uint256) {
        CollateralAsset storage asset = assets[assetId];
        if (asset.priceFeedId == 0) return amount / 1e12; // USDC: just convert decimals
        try oracle.getPrice(asset.symbol) returns (uint256 price, uint256) {
            // price is 8 dec, amount varies by token — normalize to 6 dec USDC
            return amount * price / 1e20; // price(8dec) * amount / 1e20 -> USDC 6dec
        } catch { return 0; }
    }

    function _getTotalCollateralUsd(address trader) internal view returns (uint256 total) {
        MarginAccount storage acc = accounts[trader];
        for (uint i; i < acc.collaterals.length; i++) {
            uint256 assetId = tokenToAsset[acc.collaterals[i].token];
            uint256 val     = _getCollateralValueUsd(assetId, acc.collaterals[i].amount);
            uint256 ltv     = assets[assetId].ltvBps;
            total          += val * ltv / BPS;
        }
    }

    function _getHealthFactor(address trader) internal view returns (uint256) {
        MarginAccount storage acc = accounts[trader];
        if (acc.marginUsed == 0) return type(uint256).max;
        uint256 total = _getTotalCollateralUsd(trader);
        return total * BPS / acc.marginUsed;
    }

    function _updateAccountHealth(address trader) internal {
        uint256 health = _getHealthFactor(trader);
        accounts[trader].totalCollateralUsd = _getTotalCollateralUsd(trader);
        accounts[trader].lastHealthUpdate   = block.timestamp;
        emit HealthUpdated(trader, health);
    }

    function _updateAccountHealthView(address trader, uint256) internal pure {}

    // ── Admin ─────────────────────────────────────────────────────────────
    function addAsset(address token, string calldata symbol, uint256 ltv, uint256 liqThresh, uint256 liqFee, uint256 feedId, uint256 cap) external onlyOwner {
        _addAsset(token, symbol, ltv, liqThresh, liqFee, feedId, cap);
    }
    function setAssetEnabled(uint256 assetId, bool enabled) external onlyOwner { assets[assetId].enabled = enabled; }
    function setLiquidator(address liq, bool on) external onlyOwner { liquidators[liq] = on; }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
