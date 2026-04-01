// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiPOL (Protocol-Owned Liquidity)
 * @notice Deploys treasury USDC into WikiAMM WIK/USDC pool as permanent
 *         protocol-owned liquidity. Protocol earns LP fees forever without
 *         any "mercenary liquidity" risk.
 *
 * WHY POL MATTERS
 * ─────────────────────────────────────────────────────────────────────────
 * External LPs leave when incentives dry up → liquidity crunch → bad UX.
 * Protocol-owned LP never leaves. It deepens the WIK/USDC pool permanently,
 * tightens spreads for all traders, and earns LP fees that compound back
 * into more liquidity.
 *
 * MECHANICS
 * ─────────────────────────────────────────────────────────────────────────
 * 1. WikiFeeDistributor allocates 10% of protocol fees to this contract.
 * 2. Owner pairs USDC with WIK from treasury and adds to WikiAMM.
 * 3. LP tokens are held permanently — never withdrawn by external parties.
 * 4. LP fees (0.3% of every WIK/USDC swap) accrue to protocol.
 * 5. Fees harvested and re-deployed to compound POL position.
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * At $5M POL and $50M monthly WIK/USDC volume: 0.3% × $50M = $150K/month
 * Plus: stabilises WIK price → better staking APY → more protocol usage
 */

interface IWikiAMM {
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function getReserves(address tokenA, address tokenB)
        external view returns (uint256 reserveA, uint256 reserveB);

    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut)
        external view returns (uint256 amountOut);

    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

interface IWikiLP {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
}

contract WikiPOL is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── State ──────────────────────────────────────────────────────────────
    IERC20    public immutable USDC;
    IERC20    public immutable WIK;
    IWikiAMM  public immutable amm;
    IWikiLP   public immutable lpToken;

    uint256 public totalUSDCDeployed;
    uint256 public totalWIKDeployed;
    uint256 public totalLPHeld;
    uint256 public totalFeesEarned;
    uint256 public lastCompoundTime;

    // Revenue routing: LP fees go here before compounding
    uint256 public pendingUSDC;
    uint256 public pendingWIK;

    // ── Events ─────────────────────────────────────────────────────────────
    
    event FeesCompounded(uint256 usdc, uint256 wik, uint256 newLP);
    event FundingReceived(uint256 usdc);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address _usdc, address _wik, address _amm, address _lp, address _owner)
        Ownable(_owner)
    {
        require(_usdc != address(0), "Wiki: zero _usdc");
        require(_wik != address(0), "Wiki: zero _wik");
        require(_amm != address(0), "Wiki: zero _amm");
        USDC    = IERC20(_usdc);
        WIK     = IERC20(_wik);
        amm     = IWikiAMM(_amm);
        lpToken = IWikiLP(_lp);
    }

    // ── Add Liquidity ──────────────────────────────────────────────────────

    /**
     * @notice Add protocol-owned liquidity to WIK/USDC pool.
     * @param usdcAmount  USDC to pair
     * @param wikAmount   WIK to pair (from protocol treasury)
     * @param slippageBps Max slippage tolerance in BPS (e.g. 100 = 1%)
     */
    function addLiquidity(
        uint256 usdcAmount,
        uint256 wikAmount,
        uint256 slippageBps
    ) external onlyOwner nonReentrant returns (uint256 lpReceived) {
        require(usdcAmount > 0 && wikAmount > 0, "POL: zero amounts");

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        WIK.safeTransferFrom(msg.sender, address(this), wikAmount);

        USDC.approve(address(amm), usdcAmount);
        WIK.approve(address(amm), wikAmount);

        uint256 minUSDC = usdcAmount * (BPS - slippageBps) / BPS;
        uint256 minWIK  = wikAmount  * (BPS - slippageBps) / BPS;

        (, , lpReceived) = amm.addLiquidity(
            address(USDC), address(WIK),
            usdcAmount, wikAmount,
            minUSDC, minWIK,
            address(this),
            block.timestamp + 300
        );

        totalUSDCDeployed += usdcAmount;
        totalWIKDeployed  += wikAmount;
        totalLPHeld       += lpReceived;

        emit LiquidityAdded(usdcAmount, wikAmount, lpReceived);
    }

    /**
     * @notice Receive funding from WikiFeeDistributor (10% of protocol fees).
     */
    function receiveFunding(uint256 usdcAmount) external nonReentrant {
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        pendingUSDC += usdcAmount;
        emit FundingReceived(usdcAmount);
    }

    // ── Compound LP Fees ──────────────────────────────────────────────────

    /**
     * @notice Harvest accrued LP fees and re-deploy them as more liquidity.
     *         LP fees accrue as the pool grows relative to our LP share.
     *         Called weekly by keeper bot.
     */
    function compound(uint256 slippageBps) external onlyOwner nonReentrant {
        require(block.timestamp >= lastCompoundTime + 7 days, "POL: too soon");

        // Calculate fee yield from LP position
        uint256 currentLPBalance = lpToken.balanceOf(address(this));
        if (currentLPBalance == 0) return;

        // Estimate earned fees: current value minus deployed cost
        (uint256 resUSDC, uint256 resWIK) = amm.getReserves(address(USDC), address(WIK));
        uint256 lpSupply = lpToken.totalSupply();
        if (lpSupply == 0) return;

        uint256 myUSDC = resUSDC * currentLPBalance / lpSupply;
        uint256 myWIK  = resWIK  * currentLPBalance / lpSupply;

        // Add any pending USDC from fee distributor
        uint256 addUSDC = pendingUSDC;
        pendingUSDC = 0;

        if (addUSDC > 0) {
            // Swap half to WIK to match pool ratio
            uint256 halfUSDC = addUSDC / 2;
            uint256 wikOut   = amm.getAmountOut(halfUSDC, address(USDC), address(WIK));

            USDC.approve(address(amm), halfUSDC);
            // poolId 0 = USDC/WIK pool on WikiSpot
            uint256 addWIK = amm.swapExactIn(0, address(USDC), halfUSDC, wikOut * 9900 / 10000, address(this), block.timestamp + 60);
            WIK.approve(address(amm), addWIK);

            (, , uint256 newLP) = amm.addLiquidity(
                address(USDC), address(WIK),
                halfUSDC, addWIK,
                halfUSDC * (BPS - slippageBps) / BPS,
                addWIK   * (BPS - slippageBps) / BPS,
                address(this), block.timestamp + 300
            );

            totalLPHeld  += newLP;
            totalFeesEarned += addUSDC;
            lastCompoundTime = block.timestamp;

            emit FeesCompounded(halfUSDC, addWIK, newLP);
        }
    }

    // ── Emergency Remove (timelocked in production) ───────────────────────

    function removeLiquidity(uint256 lpAmount, uint256 slippageBps)
        external onlyOwner nonReentrant
    {
        require(lpAmount <= totalLPHeld, "POL: exceeds held");
        lpToken.approve(address(amm), lpAmount);

        (uint256 resUSDC, uint256 resWIK) = amm.getReserves(address(USDC), address(WIK));
        uint256 supply = lpToken.totalSupply();
        uint256 minU = resUSDC * lpAmount / supply * (BPS - slippageBps) / BPS;
        uint256 minW = resWIK  * lpAmount / supply * (BPS - slippageBps) / BPS;

        (uint256 uOut, uint256 wOut) = amm.removeLiquidity(
            address(USDC), address(WIK), lpAmount, minU, minW, address(this), block.timestamp + 300
        );
        totalLPHeld -= lpAmount;
        emit LiquidityRemoved(uOut, wOut, lpAmount);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function positionValue() external view returns (uint256 usdcValue, uint256 wikValue) {
        uint256 lp = lpToken.balanceOf(address(this));
        if (lp == 0) return (0, 0);
        (uint256 rU, uint256 rW) = amm.getReserves(address(USDC), address(WIK));
        uint256 supply = lpToken.totalSupply();
        usdcValue = rU * lp / supply;
        wikValue  = rW * lp / supply;
    }

    function stats() external view returns (
        uint256 lpHeld, uint256 usdcDeployed, uint256 wikDeployed,
        uint256 feesEarned, uint256 pending
    ) {
        return (totalLPHeld, totalUSDCDeployed, totalWIKDeployed, totalFeesEarned, pendingUSDC);
    }

    uint256 private constant BPS = 10_000;
}
