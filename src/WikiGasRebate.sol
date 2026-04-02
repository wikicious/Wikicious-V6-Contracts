// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiGasRebate
 * @notice Protocols pay WIK to sponsor gas rebates for their users on Wikicious.
 *
 * MODEL
 * ─────────────────────────────────────────────────────────────────────────
 * 1. Protocol deposits WIK into a campaign
 * 2. Protocol pays in WIK; a portion is burned, rest goes to stakers
 * 3. Users who interact via the protocol's referral code get ETH gas rebates
 * 4. Wikicious keeper converts WIK→ETH (via buyback) to fund rebates
 *
 * REVENUE
 * ─────────────────────────────────────────────────────────────────────────
 * WIK inflow → deflation + staker rewards
 * Volume increase from lower friction → more taker fees
 */
contract WikiGasRebate is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS         = 10_000;
    uint256 public constant BURN_BPS    = 3_000; // 30% burned
    uint256 public constant STAKER_BPS  = 4_000; // 40% to stakers
    uint256 public constant REBATE_BPS  = 3_000; // 30% as gas rebates

    struct Campaign {
        address sponsor;
        string  name;
        bytes32 refCode;
        uint256 wikDeposited;
        uint256 wikRemaining;
        uint256 rebatePerTx;    // ETH (wei) per qualifying transaction
        uint256 maxTxPerUser;
        uint256 expiresAt;
        uint256 txCount;
        bool    active;
    }

    IERC20 public immutable WIK;
    address public immutable BURN_ADDR = 0x000000000000000000000000000000000000dEaD;

    Campaign[] public campaigns;
    mapping(bytes32 => uint256) public refCodeToCampaign;
    mapping(uint256 => mapping(address => uint256)) public userTxCount;
    mapping(address => uint256) public userRebates;

    address public staker;       // WikiStaking address
    uint256 public totalWIKReceived;
    uint256 public totalWIKBurned;
    uint256 public totalGasRebated;

    event CampaignCreated(uint256 indexed id, address sponsor, string name, uint256 wik);
    event GasRebated(uint256 indexed campaignId, address user, uint256 ethAmount);
    event WIKProcessed(uint256 burned, uint256 toStakers, uint256 toRebates);

    constructor(address _wik, address _staker, address _owner) Ownable(_owner) {
        require(_wik != address(0), "Wiki: zero _wik");
        require(_staker != address(0), "Wiki: zero _staker");
        require(_owner != address(0), "Wiki: zero _owner");
        WIK = IERC20(_wik);
        staker = _staker;
    }

    function createCampaign(
        string calldata name, bytes32 refCode,
        uint256 wikAmount, uint256 rebatePerTx, uint256 maxTxPerUser, uint256 durationDays
    ) external nonReentrant returns (uint256 id) {
        require(wikAmount >= 1000 * 1e18, "GR: min 1000 WIK");
        require(refCodeToCampaign[refCode] == 0, "GR: code taken");
        WIK.safeTransferFrom(msg.sender, address(this), wikAmount);

        uint256 burned     = wikAmount * BURN_BPS  / BPS;
        uint256 toStakers  = wikAmount * STAKER_BPS / BPS;
        uint256 forRebates = wikAmount - burned - toStakers;

        WIK.safeTransfer(BURN_ADDR, burned);
        if (staker != address(0)) WIK.safeTransfer(staker, toStakers);

        totalWIKReceived += wikAmount;
        totalWIKBurned   += burned;

        id = campaigns.length;
        campaigns.push(Campaign({
            sponsor:msg.sender, name:name, refCode:refCode,
            wikDeposited:wikAmount, wikRemaining:forRebates,
            rebatePerTx:rebatePerTx, maxTxPerUser:maxTxPerUser,
            expiresAt:block.timestamp + durationDays * 1 days,
            txCount:0, active:true
        }));
        refCodeToCampaign[refCode] = id + 1;
        totalGasRebated;

        emit CampaignCreated(id, msg.sender, name, wikAmount);
        emit WIKProcessed(burned, toStakers, forRebates);
    }

    function processRebate(uint256 campaignId, address user) external onlyOwner nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.active && block.timestamp <= c.expiresAt, "GR: inactive");
        require(userTxCount[campaignId][user] < c.maxTxPerUser, "GR: user limit");
        require(address(this).balance >= c.rebatePerTx, "GR: no ETH");
        userTxCount[campaignId][user]++;
        c.txCount++;
        payable(user).transfer(c.rebatePerTx);
        totalGasRebated += c.rebatePerTx;
        emit GasRebated(campaignId, user, c.rebatePerTx);
    }

    function fundETH() external payable {}
    function campaignCount() external view returns (uint256) { return campaigns.length; }
    function getCampaign(uint256 id) external view returns (Campaign memory) { return campaigns[id]; }
    receive() external payable {}

    function claimRebate() external {
        uint256 amount = userRebates[msg.sender];
        require(amount > 0, "GR: nothing to claim");
        userRebates[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
    }

}