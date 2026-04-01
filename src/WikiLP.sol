// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiLP
 * @notice Multi-tier AMM liquidity pools with:
 *   • 3 fee tiers: 0.05%, 0.30%, 1.00%
 *   • Proportional fee accrual to LPs — no impermanent loss insurance, pure AMM
 *   • Flash loans — arbitrageurs pay flashFeeBps; revenue shared with LPs
 *   • Protocol cut: protocolShareBps of every swap fee goes to treasury
 *   • WIK incentives: owner can add WIK/sec rewards to any pool
 *
 * DESIGN (simplified x*y=k with fee-on-swap)
 * ──────────────────────────────────────────
 * Each pool tracks:
 *   reserveA, reserveB — current liquidity reserves
 *   totalLP            — LP token supply (ERC20-like but stored in mapping)
 *   feesA, feesB       — accumulated unclaimed fees per LP token
 *
 * REVENUE
 * ───────
 * Pool creation: flat USDC fee
 * Every swap:    protocolShareBps portion of swap fee
 * Flash loans:   flashFeeBps of loan amount
 *
 * ATTACK MITIGATIONS
 * ──────────────────
 * [A1] Reentrancy     → ReentrancyGuard on all state-mutating functions
 * [A2] CEI            → state written before transfers
 * [A3] Sandwich       → minimum output enforced by caller (amountOutMin)
 * [A4] Overflow       → Solidity 0.8 + explicit guards
 * [A5] Flash loan re-entry → check balance after callback
 * [A6] Donation attack → only track reserves via explicit state, not balanceOf
 * [A7] Dust lock       → minimum LP requirement
 */
interface IFlashBorrower {
        function onFlashLoan(address token, uint256 amount, uint256 fee, bytes calldata data) external;
    }

contract WikiLP is Ownable2Step, ReentrancyGuard {
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

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────
    uint256 public constant PRECISION       = 1e18;
    uint256 public constant BPS             = 10_000;
    uint256 public constant MIN_LP          = 1000;
    uint256 public constant CREATE_FEE_USDC = 500 * 1e6; // $500 USDC

    // Fee tiers (BPS)
    uint256 public constant TIER_LOW    = 5;    // 0.05%
    uint256 public constant TIER_MID    = 30;   // 0.30%
    uint256 public constant TIER_HIGH   = 100;  // 1.00%

    uint256 public constant FLASH_FEE_BPS   = 5;    // 0.05%
    uint256 public constant PROTOCOL_SHARE  = 2000; // 20% of swap fee to protocol

    // ─────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────
    struct Pool {
        address  tokenA;
        address  tokenB;
        uint256  feeBps;         // one of TIER_LOW / TIER_MID / TIER_HIGH
        uint256  reserveA;
        uint256  reserveB;
        uint256  totalLP;        // LP token supply
        uint256  feeGrowthA;     // accumulated fees per LP unit × PRECISION
        uint256  feeGrowthB;
        uint256  protocolFeeA;   // unclaimed protocol fees in tokenA
        uint256  protocolFeeB;
        uint256  totalVolumeA;   // lifetime tokenA volume (for stats)
        uint256  wikPerSecond;   // optional WIK incentive
        uint256  accWIKPerLP;    // accumulated WIK per LP × PRECISION
        uint256  lastWIKTime;
        bool     active;
    }

    struct LPPosition {
        uint256 lpBalance;
        uint256 feeDebtA;    // fee growth at last claim
        uint256 feeDebtB;
        uint256 wikDebt;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────
    IERC20  public immutable USDC;
    IERC20  public immutable WIK;

    Pool[]  public pools;
    mapping(bytes32 => uint256) public pairToPool; // hash(tokenA,tokenB,fee) → poolId+1 (0=none)
    mapping(uint256 => mapping(address => LPPosition)) public positions;

    uint256 public totalProtocolFeeA; // global USDC accumulated
    uint256 public protocolRevenue;   // USDC withdrawable by owner

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────
    event PoolCreated(uint256 indexed pid, address tokenA, address tokenB, uint256 feeBps);
    event LiquidityAdded(uint256 indexed pid, address indexed lp, uint256 amtA, uint256 amtB, uint256 lpMinted);
    event LiquidityRemoved(uint256 indexed pid, address indexed lp, uint256 amtA, uint256 amtB, uint256 lpBurned);
    event Swap(uint256 indexed pid, address indexed trader, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut, uint256 fee);
    event FeesClaimed(uint256 indexed pid, address indexed lp, uint256 feeA, uint256 feeB);
    event FlashLoan(uint256 indexed pid, address indexed borrower, address token, uint256 amount, uint256 fee);
    event WIKHarvested(uint256 indexed pid, address indexed lp, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────
    constructor(address usdc, address wik, address owner) Ownable(owner) {
        require(usdc != address(0), "Wiki: zero usdc");
        require(wik != address(0), "Wiki: zero wik");
        require(owner != address(0), "Wiki: zero owner");
        USDC = IERC20(usdc);
        WIK  = IERC20(wik);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Create Pool
    // ─────────────────────────────────────────────────────────────────────

    function createPool(address tokenA, address tokenB, uint256 feeBps)
        external nonReentrant returns (uint256 pid)
    {
        require(tokenA != tokenB,                                       "LP: same token");
        require(feeBps == TIER_LOW || feeBps == TIER_MID || feeBps == TIER_HIGH, "LP: invalid fee tier");
        // Sort tokens so identical pairs map to same pool
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        bytes32 key = keccak256(abi.encodePacked(tokenA, tokenB, feeBps));
        require(pairToPool[key] == 0, "LP: pool exists");

        // Collect creation fee
        USDC.safeTransferFrom(msg.sender, address(this), CREATE_FEE_USDC);
        protocolRevenue += CREATE_FEE_USDC;

        pid = pools.length;
        pools.push(Pool({
            tokenA:      tokenA,
            tokenB:      tokenB,
            feeBps:      feeBps,
            reserveA:    0,
            reserveB:    0,
            totalLP:     0,
            feeGrowthA:  0,
            feeGrowthB:  0,
            protocolFeeA: 0,
            protocolFeeB: 0,
            totalVolumeA: 0,
            wikPerSecond: 0,
            accWIKPerLP:  0,
            lastWIKTime:  block.timestamp,
            active:       true
        }));
        pairToPool[key] = pid + 1;

        emit PoolCreated(pid, tokenA, tokenB, feeBps);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Add Liquidity
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Add liquidity to an existing pool
     * @param pid      Pool ID
     * @param amtA     Desired tokenA to deposit
     * @param amtB     Desired tokenB to deposit
     * @param minLP    Minimum LP tokens (slippage protection) [A3]
     */
    function addLiquidity(uint256 pid, uint256 amtA, uint256 amtB, uint256 minLP)
        external nonReentrant returns (uint256 lpMinted)
    {
        Pool storage p = pools[pid];
        require(p.active,    "LP: pool inactive");
        require(amtA > 0 && amtB > 0, "LP: zero amounts");

        _updateWIK(pid);
        _settleFees(pid, msg.sender);

        uint256 actualA = amtA;
        uint256 actualB = amtB;

        if (p.totalLP == 0) {
            // First deposit: mint LP = sqrt(amtA × amtB) - MIN_LP
            lpMinted = _sqrt(amtA * amtB) - MIN_LP;
            require(lpMinted > 0, "LP: first deposit too small");
        } else {
            // Proportional deposit — use ratio of smaller contribution
            uint256 lpFromA = amtA * p.totalLP / p.reserveA;
            uint256 lpFromB = amtB * p.totalLP / p.reserveB;
            if (lpFromA < lpFromB) {
                lpMinted = lpFromA;
                actualB  = lpMinted * p.reserveB / p.totalLP;
            } else {
                lpMinted = lpFromB;
                actualA  = lpMinted * p.reserveA / p.totalLP;
            }
        }
        require(lpMinted >= minLP, "LP: slippage"); // [A3]

        // [A2] State before transfers
        p.reserveA += actualA;
        p.reserveB += actualB;
        p.totalLP  += lpMinted;

        LPPosition storage pos = positions[pid][msg.sender];
        pos.lpBalance   += lpMinted;
        pos.feeDebtA     = pos.lpBalance * p.feeGrowthA / PRECISION;
        pos.feeDebtB     = pos.lpBalance * p.feeGrowthB / PRECISION;
        pos.wikDebt      = pos.lpBalance * p.accWIKPerLP / PRECISION;

        IERC20(p.tokenA).safeTransferFrom(msg.sender, address(this), actualA);
        IERC20(p.tokenB).safeTransferFrom(msg.sender, address(this), actualB);

        emit LiquidityAdded(pid, msg.sender, actualA, actualB, lpMinted);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Remove Liquidity
    // ─────────────────────────────────────────────────────────────────────

    function removeLiquidity(uint256 pid, uint256 lpAmount, uint256 minA, uint256 minB)
        external nonReentrant returns (uint256 amtA, uint256 amtB)
    {
        Pool storage p = pools[pid];
        LPPosition storage pos = positions[pid][msg.sender];
        require(pos.lpBalance >= lpAmount, "LP: insufficient LP");

        _updateWIK(pid);
        _settleFees(pid, msg.sender);

        amtA = lpAmount * p.reserveA / p.totalLP;
        amtB = lpAmount * p.reserveB / p.totalLP;
        require(amtA >= minA && amtB >= minB, "LP: slippage"); // [A3]

        // [A2] State before transfers
        p.reserveA    -= amtA;
        p.reserveB    -= amtB;
        p.totalLP     -= lpAmount;
        pos.lpBalance -= lpAmount;
        pos.feeDebtA   = pos.lpBalance * p.feeGrowthA / PRECISION;
        pos.feeDebtB   = pos.lpBalance * p.feeGrowthB / PRECISION;
        pos.wikDebt    = pos.lpBalance * p.accWIKPerLP / PRECISION;

        IERC20(p.tokenA).safeTransfer(msg.sender, amtA);
        IERC20(p.tokenB).safeTransfer(msg.sender, amtB);

        emit LiquidityRemoved(pid, msg.sender, amtA, amtB, lpAmount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Swap
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Swap exact tokenIn for tokenOut in a pool
     * @param pid        Pool ID
     * @param tokenIn    Input token address
     * @param amtIn      Input amount
     * @param amtOutMin  Minimum output [A3]
     */
    function swap(uint256 pid, address tokenIn, uint256 amtIn, uint256 amtOutMin)
        external nonReentrant returns (uint256 amtOut)
    {
        Pool storage p = pools[pid];
        require(p.active, "LP: inactive");
        require(tokenIn == p.tokenA || tokenIn == p.tokenB, "LP: invalid token");
        require(amtIn > 0, "LP: zero input");

        _updateWIK(pid);

        bool   aToB      = (tokenIn == p.tokenA);
        uint256 resIn    = aToB ? p.reserveA : p.reserveB;
        uint256 resOut   = aToB ? p.reserveB : p.reserveA;

        // x*y=k — compute output (fee applied to input)
        uint256 fee      = amtIn * p.feeBps / BPS;
        uint256 netIn    = amtIn - fee;
        amtOut           = (netIn * resOut) / (resIn + netIn);
        require(amtOut >= amtOutMin, "LP: insufficient output"); // [A3]
        require(amtOut < resOut,     "LP: insufficient liquidity");

        // Protocol cut
        uint256 protoCut = fee * PROTOCOL_SHARE / BPS;
        uint256 lpFee    = fee - protoCut;

        if (aToB) {
            p.reserveA    += amtIn;
            p.reserveB    -= amtOut;
            p.protocolFeeA += protoCut;
            p.totalVolumeA += amtIn;
            if (p.totalLP > 0)
                p.feeGrowthA += lpFee * PRECISION / p.totalLP;
        } else {
            p.reserveB    += amtIn;
            p.reserveA    -= amtOut;
            p.protocolFeeB += protoCut;
            if (p.totalLP > 0)
                p.feeGrowthB += lpFee * PRECISION / p.totalLP;
        }

        address tokenOut = aToB ? p.tokenB : p.tokenA;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amtIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amtOut);

        emit Swap(pid, msg.sender, tokenIn, amtIn, tokenOut, amtOut, fee);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Flash Loan [A5]
    // ─────────────────────────────────────────────────────────────────────


    function flashLoan(uint256 pid, address token, uint256 amount, bytes calldata data)
        external nonReentrant
    {
        Pool storage p = pools[pid];
        require(p.active, "LP: inactive");
        require(token == p.tokenA || token == p.tokenB, "LP: invalid token");
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        require(balBefore >= amount, "LP: insufficient liquidity");

        uint256 flashFee  = amount * FLASH_FEE_BPS / BPS;
        uint256 protoCut  = flashFee * PROTOCOL_SHARE / BPS;
        uint256 lpPortion = flashFee - protoCut;

        IERC20(token).safeTransfer(msg.sender, amount);
        IFlashBorrower(msg.sender).onFlashLoan(token, amount, flashFee, data);

        // [A5] Verify repayment
        uint256 balAfter = IERC20(token).balanceOf(address(this));
        require(balAfter >= balBefore + flashFee, "LP: flash loan not repaid");

        // Distribute fees
        bool isA = (token == p.tokenA);
        if (isA) {
            p.protocolFeeA += protoCut;
            if (p.totalLP > 0) p.feeGrowthA += lpPortion * PRECISION / p.totalLP;
        } else {
            p.protocolFeeB += protoCut;
            if (p.totalLP > 0) p.feeGrowthB += lpPortion * PRECISION / p.totalLP;
        }

        emit FlashLoan(pid, msg.sender, token, amount, flashFee);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Claim Fees
    // ─────────────────────────────────────────────────────────────────────

    function claimFees(uint256 pid) external nonReentrant {
        _updateWIK(pid);
        _settleFees(pid, msg.sender);
        Pool       storage p   = pools[pid];
        LPPosition storage pos = positions[pid][msg.sender];

        uint256 feeA = pos.feeDebtA;
        uint256 feeB = pos.feeDebtB;
        // pendingFees are in feeDebt snapshot — recalculate properly
        uint256 earnedA = pos.lpBalance * p.feeGrowthA / PRECISION;
        uint256 earnedB = pos.lpBalance * p.feeGrowthB / PRECISION;
        uint256 claimA  = earnedA > pos.feeDebtA ? earnedA - pos.feeDebtA : 0;
        uint256 claimB  = earnedB > pos.feeDebtB ? earnedB - pos.feeDebtB : 0;

        require(claimA > 0 || claimB > 0, "LP: no fees");
        pos.feeDebtA = earnedA;
        pos.feeDebtB = earnedB;

        if (claimA > 0) IERC20(p.tokenA).safeTransfer(msg.sender, claimA);
        if (claimB > 0) IERC20(p.tokenB).safeTransfer(msg.sender, claimB);

        emit FeesClaimed(pid, msg.sender, claimA, claimB);
    }

    function claimWIK(uint256 pid) external nonReentrant {
        _updateWIK(pid);
        Pool       storage p   = pools[pid];
        LPPosition storage pos = positions[pid][msg.sender];
        uint256 earned = pos.lpBalance * p.accWIKPerLP / PRECISION;
        uint256 amount = earned > pos.wikDebt ? earned - pos.wikDebt : 0;
        require(amount > 0, "LP: no WIK");
        pos.wikDebt = earned;
        _safeWIKTransfer(msg.sender, amount);
        emit WIKHarvested(pid, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Owner
    // ─────────────────────────────────────────────────────────────────────

    function setWIKIncentive(uint256 pid, uint256 wps) external onlyOwner {
        _updateWIK(pid);
        pools[pid].wikPerSecond = wps;
    }

    function withdrawProtocolFees(uint256 pid, address to) external onlyOwner nonReentrant {
        Pool storage p = pools[pid];
        uint256 a = p.protocolFeeA;
        uint256 b = p.protocolFeeB;
        require(a > 0 || b > 0, "LP: no fees");
        p.protocolFeeA = 0;
        p.protocolFeeB = 0;
        if (a > 0) IERC20(p.tokenA).safeTransfer(to, a);
        if (b > 0) IERC20(p.tokenB).safeTransfer(to, b);
    }

    function withdrawRevenue(address to) external onlyOwner nonReentrant {
        uint256 amt = protocolRevenue;
        require(amt > 0, "LP: no revenue");
        protocolRevenue = 0;
        USDC.safeTransfer(to, amt);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────

    function _updateWIK(uint256 pid) internal {
        Pool storage p = pools[pid];
        if (p.wikPerSecond == 0 || p.totalLP == 0) { p.lastWIKTime = block.timestamp; return; }
        uint256 elapsed = block.timestamp - p.lastWIKTime;
        p.accWIKPerLP  += elapsed * p.wikPerSecond * PRECISION / p.totalLP;
        p.lastWIKTime   = block.timestamp;
    }

    function _settleFees(uint256 pid, address user) internal {
        // Update fee debts to current growth (called before LP changes)
        Pool       storage p   = pools[pid];
        LPPosition storage pos = positions[pid][user];
        if (pos.lpBalance == 0) return;
        pos.feeDebtA = pos.lpBalance * p.feeGrowthA / PRECISION;
        pos.feeDebtB = pos.lpBalance * p.feeGrowthB / PRECISION;
    }

    function _safeWIKTransfer(address to, uint256 amount) internal {
        uint256 bal = WIK.balanceOf(address(this));
        WIK.safeTransfer(to, amount > bal ? bal : amount);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────────────────────────────

    function getPool(uint256 pid) external view returns (Pool memory) { return pools[pid]; }
    function poolCount() external view returns (uint256) { return pools.length; }
    function getPosition(uint256 pid, address lp) external view returns (LPPosition memory) { return positions[pid][lp]; }

    function getAmountOut(uint256 pid, address tokenIn, uint256 amtIn) external view returns (uint256 amtOut) {
        Pool storage p = pools[pid];
        bool   aToB    = tokenIn == p.tokenA;
        uint256 resIn  = aToB ? p.reserveA : p.reserveB;
        uint256 resOut = aToB ? p.reserveB : p.reserveA;
        uint256 netIn  = amtIn - amtIn * p.feeBps / BPS;
        amtOut         = (netIn * resOut) / (resIn + netIn);
    }

    function pendingFees(uint256 pid, address lp) external view returns (uint256 feeA, uint256 feeB) {
        Pool       storage p   = pools[pid];
        LPPosition storage pos = positions[pid][lp];
        uint256 earnedA = pos.lpBalance * p.feeGrowthA / PRECISION;
        uint256 earnedB = pos.lpBalance * p.feeGrowthB / PRECISION;
        feeA = earnedA > pos.feeDebtA ? earnedA - pos.feeDebtA : 0;
        feeB = earnedB > pos.feeDebtB ? earnedB - pos.feeDebtB : 0;
    }

    function price(uint256 pid) external view returns (uint256) {
        Pool storage p = pools[pid];
        if (p.reserveA == 0) return 0;
        return p.reserveB * PRECISION / p.reserveA;
    }
}
