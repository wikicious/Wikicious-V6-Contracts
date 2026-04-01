// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiPaymaster — ERC-4337 Paymaster for gasless trading
 *
 * Implements EIP-4337 IPaymaster interface. Users pay gas in any whitelisted
 * token instead of ETH. The Paymaster converts tokens → ETH to cover gas.
 *
 * ERC-4337 EntryPoint on Arbitrum: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789
 *
 * GAS PAYMENT MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * User signs UserOperation specifying: paymasterAndData = [paymaster, token, maxTokenCost]
 *   1. EntryPoint calls validatePaymasterUserOp() → paymaster validates + locks tokens
 *   2. EntryPoint executes UserOperation
 *   3. EntryPoint calls postOp() → paymaster deducts actual token cost + 12% markup
 *   4. Markup goes to protocolRevenue
 *
 * SUPPORTED PAYMENT TOKENS
 *   USDC, WETH, ARB, WIK, LINK (any token with a Chainlink price feed)
 *
 * REVENUE
 *   10–15% markup on all gas costs → pure protocol revenue
 *   High frequency (every gasless tx) × small margin = significant at scale
 */

interface IEntryPoint {
    function depositTo(address account) external payable;
    function getDepositInfo(address account) external view returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint64 withdrawTime);
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;
}

interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee;
        address recipient; uint256 deadline; uint256 amountIn;
        uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// Minimal ERC-4337 UserOperation struct
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes   initCode;
    bytes   callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes   paymasterAndData;
    bytes   signature;
}

contract WikiPaymaster is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ERC-4337 EntryPoint on Arbitrum
    IEntryPoint public immutable entryPoint;
    // Uniswap V3 SwapRouter on Arbitrum
    IUniswapV3SwapRouter public constant SWAP_ROUTER = IUniswapV3SwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    uint256 public constant GAS_MARKUP_BPS = 1200; // 12% markup on gas cost
    uint256 public constant BPS            = 10000;
    uint256 public constant ETH_DECIMALS   = 18;

    struct TokenConfig {
        bool    enabled;
        address priceFeed;   // Chainlink price feed (token/USD)
        uint8   decimals;
        uint24  poolFee;     // Uniswap V3 fee tier for token→WETH swap
    }

    mapping(address => TokenConfig)    public  supportedTokens;
    mapping(address => uint256)        public  userTokenDeposits; // pending deductions
    mapping(address => bool)           public  freeGasUsers;      // VIP users: zero cost

    uint256 public protocolRevenue;   // ETH accumulated from markup
    uint256 public totalGasSponsored; // ETH total sponsored (for free-gas users)

    event GasPaidInToken(address indexed user, address token, uint256 tokenAmount, uint256 ethAmount, uint256 markup);
    event TokenAdded(address token, address priceFeed);
    event VIPGranted(address user, bool enabled);

    constructor(address _entryPoint, address _owner) Ownable(_owner) {
        require(_entryPoint != address(0), "Wiki: zero _entryPoint");
        require(_owner != address(0), "Wiki: zero _owner");
        entryPoint = IEntryPoint(_entryPoint);
    }

    // ── ERC-4337 IPaymaster ────────────────────────────────────────────────

    /**
     * @notice Called by EntryPoint to validate the paymaster will cover this op.
     * Verifies the user has approved enough tokens and that the token is supported.
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /*userOpHash*/,
        uint256 maxCost          // max ETH the op could cost
    ) external returns (bytes memory context, uint256 validationData) {
        require(msg.sender == address(entryPoint), "Paymaster: not EntryPoint");

        // Decode token from paymasterAndData (bytes 20..40 = token address)
        address token;
        if (userOp.paymasterAndData.length >= 52) {
            assembly { token := mload(add(userOp.paymasterAndData, 52)) }
        }

        if (freeGasUsers[userOp.sender]) {
            // VIP: protocol covers gas at cost
            context = abi.encode(userOp.sender, address(0), maxCost);
            return (context, 0); // 0 = valid
        }

        require(token != address(0) && supportedTokens[token].enabled, "Paymaster: token not supported");

        // Calculate max token cost with markup
        uint256 tokenCost = _ethToToken(token, maxCost * (BPS + GAS_MARKUP_BPS) / BPS);
        require(IERC20(token).allowance(userOp.sender, address(this)) >= tokenCost, "Paymaster: insufficient allowance");

        context = abi.encode(userOp.sender, token, maxCost);
        validationData = 0; // valid
    }

    /**
     * @notice Called after UserOperation execution to settle actual gas cost.
     */
    function postOp(
        uint8   /*mode*/,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /*actualUserOpFeePerGas*/
    ) external nonReentrant {
        require(msg.sender == address(entryPoint), "Paymaster: not EntryPoint");
        (address user, address token, /*maxCost*/) = abi.decode(context, (address, address, uint256));

        if (token == address(0)) {
            // VIP user — protocol absorbs gas
            totalGasSponsored += actualGasCost;
            return;
        }

        uint256 withMarkup = actualGasCost * (BPS + GAS_MARKUP_BPS) / BPS;
        uint256 markup     = withMarkup - actualGasCost;
        uint256 tokenCost  = _ethToToken(token, withMarkup);

        // Pull tokens from user and swap to ETH to replenish
        IERC20(token).safeTransferFrom(user, address(this), tokenCost);
        _swapTokenForETH(token, tokenCost, actualGasCost);
        protocolRevenue += markup;

        emit GasPaidInToken(user, token, tokenCost, actualGasCost, markup);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _ethToToken(address token, uint256 ethAmount) internal view returns (uint256) {
        TokenConfig storage tc = supportedTokens[token];
        IPriceFeed feed = IPriceFeed(tc.priceFeed);
        (, int256 price,, uint256 updatedAt,) = feed.latestRoundData();
        if (price <= 0) return 0;
        require(block.timestamp - updatedAt <= 3600, "Paymaster: stale price feed"); // 1h staleness check
        // ethAmount (wei) → token amount
        // price is token/USD in 8 decimals, ETH/USD also needed for conversion
        // Simplified: use a 2-step Chainlink read in production
        return ethAmount * 1e8 / uint256(price) * (10 ** tc.decimals) / 1e18;
    }

    function _swapTokenForETH(address token, uint256 tokenIn, uint256 minEthOut) internal {
        IERC20(token).approve(address(SWAP_ROUTER), tokenIn);
        try SWAP_ROUTER.exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn:           token,
            tokenOut:          0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH Arbitrum
            fee:               supportedTokens[token].poolFee,
            recipient:         address(this),
            deadline:          block.timestamp + 60,
            amountIn:          tokenIn,
            amountOutMinimum:  minEthOut * 90 / 100, // 10% slippage tolerance
            sqrtPriceLimitX96: 0
        })) returns (uint256) {} catch {}
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function addToken(address token, address priceFeed, uint8 decimals, uint24 poolFee) external onlyOwner {
        supportedTokens[token] = TokenConfig({ enabled:true, priceFeed:priceFeed, decimals:decimals, poolFee:poolFee });
        emit TokenAdded(token, priceFeed);
    }

    function setVIPAccess(address user, bool enabled) external onlyOwner {
        freeGasUsers[user] = enabled;
        emit VIPGranted(user, enabled);
    }

    function depositToEntryPoint() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdrawRevenue() external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue; protocolRevenue = 0;
        payable(owner()).transfer(amt);
    }

    receive() external payable {}
}
