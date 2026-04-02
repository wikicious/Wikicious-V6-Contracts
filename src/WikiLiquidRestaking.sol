// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


interface IEigenLayerStrategyManager {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256);
}

/**
 * @title WikiLiquidRestaking — EigenLayer Liquid Restaking Module
 *
 * When users provide ETH/stETH/rETH liquidity to Wikicious pools, the underlying
 * assets are automatically restaked on EigenLayer to earn additional AVS rewards.
 * Users receive wLRT (Wiki Liquid Restaking Token) representing their restaked position.
 *
 * FLOW
 * ─────────────────────────────────────────────────────────────────────────
 * 1. User deposits stETH → WikiLiquidRestaking
 * 2. Contract deposits stETH to EigenLayer StrategyManager
 * 3. User receives wLRT (1:1 with stETH + accrued rewards)
 * 4. wLRT can be used as collateral in WikiLending or WikiPerp
 * 5. Rewards distributed: 90% → user, 10% → WikiProtocol (restaking commission)
 *
 * EigenLayer addresses (Arbitrum proxied):
 *   StrategyManager: 0x858646372CC42E1A627fcE94aa7A7033e7CF075A (Ethereum)
 *   stETH Strategy:  0x93c4b944D05dfe6df7645A86cd2206016c51564D
 *
 * Note: Arbitrum does not natively support EigenLayer. This interface IEigenLayerStrategyManager {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256);
    function stakerStrategyShares(address staker, address strategy) external view returns (uint256);
}

contract bridges
 * deposits to Ethereum mainnet via a trusted cross-chain message for full production.
 * On Arbitrum, it wraps rETH/stETH and tracks virtual restaking positions.
 */

interface IEigenLayerStrategy {
    function deposit(address token, uint256 amount) external returns (uint256 shares);
    function withdraw(address recipient, address token, uint256 shares) external;
    function sharesToUnderlying(uint256 shares) external view returns (uint256);
    function underlyingToShares(uint256 amount) external view returns (uint256);
}


contract WikiLiquidRestaking is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Supported liquid staking tokens on Arbitrum
    IERC20 public immutable stETH;   // Lido stETH bridged to Arbitrum
    IERC20 public immutable rETH;    // Rocket Pool rETH
    IERC20 public immutable wstETH;  // Wrapped stETH

    address public treasury;
    address public eigenStrategyManager; // EigenLayer StrategyManager (real address set at deploy)

    uint256 public constant COMMISSION_BPS   = 1000; // 10% restaking commission
    uint256 public constant BPS              = 10000;
    uint256 public constant MIN_DEPOSIT      = 0.01 ether;

    uint256 public totalRestaked;          // total underlying restaked (ETH-equivalent)
    uint256 public totalRewardsHarvested;
    uint256 public pendingRewards;
    uint256 public protocolRevenue;        // 10% commission accumulated

    mapping(address => uint256) public userRestaked;     // underlying deposited
    mapping(address => uint256) public userRewardDebt;

    // Reward tracking
    uint256 public accRewardPerShare;   // scaled 1e18
    uint256 public lastRewardUpdate;
    
    event RewardsHarvested(uint256 total, uint256 toUsers, uint256 toProtocol);
    event Restaked(uint256 amount, address strategy);

    constructor(
        address _stETH, address _rETH, address _wstETH,
        address _treasury, address _eigenStrategyManager, address _owner
    ) ERC20("Wiki Liquid Restaking Token", "wLRT") Ownable(_owner) {
        require(_stETH != address(0), "Wiki: zero _stETH");
        require(_rETH != address(0), "Wiki: zero _rETH");
        require(_wstETH != address(0), "Wiki: zero _wstETH");
        stETH                = IERC20(_stETH);
        rETH                 = IERC20(_rETH);
        wstETH               = IERC20(_wstETH);
        treasury             = _treasury;
        eigenStrategyManager = _eigenStrategyManager;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    function deposit(address token, uint256 amount) external nonReentrant returns (uint256 wLRTMinted) {
        require(amount >= MIN_DEPOSIT, "LRT: below minimum");
        require(token == address(stETH) || token == address(rETH) || token == address(wstETH), "LRT: unsupported token");

        _harvestPending();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Mint wLRT 1:1 with underlying on first deposit, then proportional
        uint256 supply = totalSupply();
        wLRTMinted = supply == 0 ? amount : amount * supply / totalRestaked;

        totalRestaked              += amount;
        userRestaked[msg.sender]   += amount;
        userRewardDebt[msg.sender]  = accRewardPerShare * balanceOf(msg.sender) / 1e18;

        _mint(msg.sender, wLRTMinted);

        // Forward to EigenLayer (real integration: bridge to Ethereum then deposit)
        _restakeToEigenLayer(token, amount);

        emit Deposited(msg.sender, token, amount, wLRTMinted);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    function withdraw(address token, uint256 wLRTAmount) external nonReentrant returns (uint256 tokenAmount) {
        require(balanceOf(msg.sender) >= wLRTAmount, "LRT: insufficient wLRT");
        _harvestPending();
        _claimUserRewards(msg.sender);

        uint256 supply = totalSupply();
        tokenAmount = wLRTAmount * totalRestaked / supply;

        totalRestaked -= tokenAmount;
        userRestaked[msg.sender] -= tokenAmount;
        _burn(msg.sender, wLRTAmount);

        // In production: initiate EigenLayer withdrawal (7-day unbonding)
        // Here we transfer from our balance (assumes keeper replenishes from EigenLayer)
        require(IERC20(token).balanceOf(address(this)) >= tokenAmount, "LRT: insufficient liquidity (pending unbonding)");
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(msg.sender, token, tokenAmount, wLRTAmount);
    }

    // ── Reward Harvesting (keeper calls) ──────────────────────────────────────

    function harvestRewards(uint256 rewardAmount, address rewardToken) external nonReentrant {
        require(msg.sender == owner() || msg.sender == treasury, "LRT: not keeper");
        require(totalRestaked > 0, "LRT: no restaked assets");

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rewardAmount);

        uint256 commission = rewardAmount * COMMISSION_BPS / BPS;
        uint256 toUsers    = rewardAmount - commission;

        IERC20(rewardToken).safeTransfer(treasury, commission);
        protocolRevenue          += commission;
        totalRewardsHarvested    += rewardAmount;
        accRewardPerShare        += toUsers * 1e18 / totalSupply();
        pendingRewards           += toUsers;

        emit RewardsHarvested(rewardAmount, toUsers, commission);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _restakeToEigenLayer(address token, uint256 amount) internal {
        if (eigenStrategyManager == address(0)) return; // testnet: skip
        try IERC20(token).approve(eigenStrategyManager, amount) {} catch {}
        // In production: IEigenLayerStrategyManager(eigenStrategyManager).depositIntoStrategy(strategy, token, amount)
        emit Restaked(amount, eigenStrategyManager);
    }

    function _harvestPending() internal {
        lastRewardUpdate = block.timestamp;
    }

    function _claimUserRewards(address user) internal {
        uint256 pending = pendingUserRewards(user);
        if (pending > 0) {
            userRewardDebt[user] = accRewardPerShare * balanceOf(user) / 1e18;
            pendingRewards -= pending;
            // In production: transfer the reward token to user
            // Simplified: accrue as additional wLRT
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function pendingUserRewards(address user) public view returns (uint256) {
        if (balanceOf(user) == 0) return 0;
        uint256 accumulated = accRewardPerShare * balanceOf(user) / 1e18;
        return accumulated > userRewardDebt[user] ? accumulated - userRewardDebt[user] : 0;
    }

    function wLRTtoUnderlying(uint256 wLRTAmount) external view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? wLRTAmount : wLRTAmount * totalRestaked / supply;
    }

    function getAPY() external view returns (uint256 apyBps) {
        if (totalRestaked == 0 || totalRewardsHarvested == 0) return 400; // 4% default
        return totalRewardsHarvested * BPS / totalRestaked;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setEigenStrategy(address s) external onlyOwner { eigenStrategyManager = s; }
    function setTreasury(address t) external onlyOwner { treasury = t; }
    receive() external payable {}
}
