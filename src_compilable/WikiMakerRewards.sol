// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiMakerRewards
 * @notice WIK rewards distributed to market makers based on spread quality.
 *         Tighter spreads → higher share of daily WIK reward pool.
 *
 * MECHANIC
 * ─────────────────────────────────────────────────────────────────────────
 * Keeper bot scores each market maker every epoch (1 hour):
 *   score = (time_at_bid_ask / epoch_duration) × (1 / avg_spread_bps) × volume
 * Higher score = larger share of daily WIK pool.
 *
 * REVENUE IMPACT
 * ─────────────────────────────────────────────────────────────────────────
 * Tighter spreads → retail traders get better prices → more volume
 * More volume → more taker fee revenue
 * WIK cost of incentive is outweighed by taker fee increase
 * dYdX paid $20M/year in maker incentives → earned $200M in taker fees (10:1)
 */
contract WikiMakerRewards is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS              = 10_000;
    uint256 public constant EPOCH_DURATION   = 1 hours;
    uint256 public constant PRECISION        = 1e18;

    struct MakerStats {
        uint256 epochScore;        // score for current epoch
        uint256 pendingRewards;    // WIK owed, not yet claimed
        uint256 totalEarned;       // lifetime WIK earned
        uint256 lastEpoch;
        bool    registered;
    }

    struct Epoch {
        uint256 id;
        uint256 totalScore;
        uint256 wikAllocated;
        uint256 startTime;
        bool    distributed;
    }

    IERC20  public immutable WIK;

    mapping(address => MakerStats)  public makers;
    address[]                        public makerList;
    Epoch[]                          public epochs;

    uint256 public dailyWIKPool      = 10_000 * 1e18;  // 10K WIK/day
    uint256 public currentEpochId;
    uint256 public totalWIKDistributed;

    mapping(address => bool) public scorers; // keeper bots

    event MakerRegistered(address indexed maker);
    event ScoreSubmitted(uint256 indexed epoch, address maker, uint256 score);
    event EpochDistributed(uint256 indexed epoch, uint256 totalWIK, uint256 makers);
    event RewardsClaimed(address indexed maker, uint256 amount);

    constructor(address _wik, address _owner) Ownable(_owner) {
        require(_wik != address(0), "Wiki: zero _wik");
        require(_owner != address(0), "Wiki: zero _owner"); WIK = IERC20(_wik); }

    function registerMaker(address maker) external {
        require(scorers[msg.sender] || msg.sender == owner(), "MR: not authorized");
        if (!makers[maker].registered) {
            makers[maker].registered = true;
            makerList.push(maker);
            emit MakerRegistered(maker);
        }
    }

    function submitScore(address maker, uint256 score) external {
        require(scorers[msg.sender] || msg.sender == owner(), "MR: not scorer");
        require(makers[maker].registered, "MR: not registered");
        uint256 epoch = block.timestamp / EPOCH_DURATION;
        if (epoch > currentEpochId) _closeEpoch();
        makers[maker].epochScore += score;
        makers[maker].lastEpoch   = epoch;
        if (epochs.length == 0 || epochs[epochs.length-1].id != epoch) {
            epochs.push(Epoch({ id:epoch, totalScore:0, wikAllocated: dailyWIKPool / 24,
                startTime:epoch * EPOCH_DURATION, distributed:false }));
        }
        epochs[epochs.length-1].totalScore += score;
        emit ScoreSubmitted(epoch, maker, score);
    }

    function distributeEpoch(uint256 epochIdx) external nonReentrant {
        require(scorers[msg.sender] || msg.sender == owner(), "MR: not scorer");
        Epoch storage e = epochs[epochIdx];
        require(!e.distributed && block.timestamp >= (e.id+1) * EPOCH_DURATION, "MR: not ready");
        require(e.totalScore > 0, "MR: no scores");
        require(WIK.balanceOf(address(this)) >= e.wikAllocated, "MR: insufficient WIK");

        e.distributed = true;
        uint256 distributed;
        for (uint i; i < makerList.length; i++) {
            address m = makerList[i];
            if (makers[m].lastEpoch == e.id && makers[m].epochScore > 0) {
                uint256 share = makers[m].epochScore * e.wikAllocated / e.totalScore;
                makers[m].pendingRewards += share;
                makers[m].totalEarned    += share;
                distributed += share;
            }
            makers[m].epochScore = 0;
        }
        totalWIKDistributed += distributed;
        emit EpochDistributed(e.id, distributed, makerList.length);
    }

    function claimRewards() external nonReentrant {
        uint256 pending = makers[msg.sender].pendingRewards;
        require(pending > 0, "MR: nothing to claim");
        makers[msg.sender].pendingRewards = 0;
        WIK.safeTransfer(msg.sender, pending);
        emit RewardsClaimed(msg.sender, pending);
    }

    function _closeEpoch() internal {
        currentEpochId = block.timestamp / EPOCH_DURATION;
    }

    function setScorer(address s, bool e) external onlyOwner { scorers[s] = e; }
    function setDailyPool(uint256 wik) external onlyOwner { dailyWIKPool = wik; }
    function fundPool(uint256 amount) external { WIK.safeTransferFrom(msg.sender, address(this), amount); }
    function makerCount() external view returns (uint256) { return makerList.length; }
    function getMaker(address m) external view returns (MakerStats memory) { return makers[m]; }
    function epochCount() external view returns (uint256) { return epochs.length; }
    function getEpoch(uint256 i) external view returns (Epoch memory) { return epochs[i]; }
    function pendingPool() external view returns (uint256) { return WIK.balanceOf(address(this)); }
}
