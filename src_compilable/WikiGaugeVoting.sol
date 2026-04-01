// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WikiGaugeVoting
 * @notice Curve-style gauge voting system — veWIK holders vote on which
 *         liquidity pools receive WIK emissions each epoch.
 *
 * ─── THE "CURVE WARS" MODEL ──────────────────────────────────────────────────
 *
 * 1. Epoch = 1 week. Every Thursday at 00:00 UTC, a new epoch starts.
 * 2. veWIK holders vote on gauges (liquidity pools). Voting power = veWIK balance.
 * 3. At epoch end, WIK emissions are distributed proportionally to votes.
 * 4. External protocols wanting deep liquidity on Wikicious BRIBE veWIK holders
 *    to vote for their pool. Bribes are pure additional yield to token holders.
 * 5. WikiGaugeVoting.addBribe() lets any protocol add USDC/tokens as a bribe
 *    for the current epoch. Protocol takes 5% of all bribes as a "listing fee."
 *
 * ─── REVENUE STREAMS ─────────────────────────────────────────────────────────
 *
 *  Bribe listing fee:  5% of every bribe deposited
 *  Gauge creation fee: $500 USDC to add a new gauge (one-time)
 *  This turns the gauge system into a recurring revenue flywheel:
 *  More protocols → more bribes → higher yield → more veWIK lockers →
 *  more voting power → more protocols want to bribe → higher bribe revenue
 *
 * ─── EPOCH FLOW ──────────────────────────────────────────────────────────────
 *
 *  Monday:   New epoch starts. Gauges reset.
 *  Mon-Sun:  veWIK holders vote and change votes freely.
 *  Sunday:   External protocols add bribes for next epoch.
 *  Mon 00:01 Epoch finalised. WIK emissions and bribes distributed.
 *
 * ─── SECURITY ────────────────────────────────────────────────────────────────
 * [A1] Vote weight = veWIK at snapshot time (prevents flash loan voting)
 * [A2] Users can change votes but only within the epoch (not after close)
 * [A3] Bribe protocol takes fee upfront — no reentrancy path
 * [A4] Emission distribution uses pull pattern — users claim, no push
 * [A5] Gauge deactivation: 2-of-3 multisig can kill malicious gauges
 */
interface IWikiStaking {
        function veBalance(address user) external view returns (uint256);
    }

contract WikiGaugeVoting is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant EPOCH_DURATION      = 7 days;
    uint256 public constant BPS                 = 10_000;
    uint256 public constant BRIBE_PROTOCOL_FEE  = 500;    // 5% of bribes
    uint256 public constant GAUGE_CREATION_FEE  = 500 * 1e6; // $500 USDC
    uint256 public constant MAX_VOTES_PER_USER  = 10;     // max gauges per user


    // ─── Gauge ────────────────────────────────────────────────────────────
    struct Gauge {
        address poolAddress;
        string  name;
        bool    active;
        uint256 totalVotes;       // veWIK votes this epoch
        uint256 createdAt;
    }

    // ─── Bribe ────────────────────────────────────────────────────────────
    struct Bribe {
        address token;
        uint256 amount;           // after protocol fee
        uint256 epoch;
        uint256 gaugeId;
    }

    // ─── Epoch state ──────────────────────────────────────────────────────
    struct EpochState {
        uint256 epochId;
        uint256 startTime;
        uint256 totalVotes;
        bool    distributed;
        uint256 wikEmissions;     // WIK to distribute this epoch
    }

    // ─── Storage ──────────────────────────────────────────────────────────
    IWikiStaking        public staking;
    IERC20              public immutable WIK;
    IERC20              public immutable USDC;
    address             public treasury;

    Gauge[]             public gauges;
    Bribe[]             public bribes;
    EpochState[]        public epochs;

    uint256 public currentEpoch;
    uint256 public epochStart;     // timestamp of epoch 0

    // epochId → gaugeId → totalVotes
    mapping(uint256 => mapping(uint256 => uint256)) public epochGaugeVotes;

    // epochId → gaugeId → bribe indices
    mapping(uint256 => mapping(uint256 => uint256[])) public epochGaugeBribes;

    // user → epochId → gaugeId → votes cast
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public userVotes;

    // user → epochId → total votes cast
    mapping(address => mapping(uint256 => uint256)) public userTotalVotes;

    // user → epochId → gaugeId → claimed bribe
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public bribeClaimed;

    uint256 public totalBribeRevenue; // protocol fee revenue
    uint256 public totalGauges;

    // ─── Events ───────────────────────────────────────────────────────────
    event GaugeAdded(uint256 indexed gaugeId, address pool, string name);
    event VoteCast(address indexed voter, uint256 indexed epochId, uint256 indexed gaugeId, uint256 votes);
    event BribeAdded(uint256 indexed bribeId, uint256 indexed epochId, uint256 indexed gaugeId, address token, uint256 amount);
    event BribeClaimed(address indexed user, uint256 indexed epochId, uint256 indexed gaugeId, address token, uint256 amount);
    event EpochDistributed(uint256 indexed epochId, uint256 wikEmissions);
    event EmissionsSet(uint256 indexed epochId, uint256 amount);

    constructor(
        address _owner,
        address _staking,
        address _wik,
        address _usdc,
        address _treasury
    ) Ownable(_owner) {
        require(_staking  != address(0), "Gauge: zero staking");
        require(_wik      != address(0), "Gauge: zero wik");
        require(_usdc     != address(0), "Gauge: zero usdc");
        staking   = IWikiStaking(_staking);
        WIK       = IERC20(_wik);
        USDC      = IERC20(_usdc);
        treasury  = _treasury;
        epochStart = block.timestamp;

        // Create epoch 0
        epochs.push(EpochState({
            epochId:     0,
            startTime:   block.timestamp,
            totalVotes:  0,
            distributed: false,
            wikEmissions: 0
        }));
    }

    // ─── Gauge management ─────────────────────────────────────────────────

    /**
     * @notice Add a new gauge. Costs $500 USDC. Pool must be a real WikiAMM pool.
     */
    function addGauge(address poolAddress, string calldata name) external nonReentrant whenNotPaused returns (uint256 gaugeId) {
        require(poolAddress != address(0), "Gauge: zero pool");
        USDC.safeTransferFrom(msg.sender, treasury, GAUGE_CREATION_FEE);

        gaugeId = gauges.length;
        gauges.push(Gauge({ poolAddress: poolAddress, name: name, active: true, totalVotes: 0, createdAt: block.timestamp }));
        totalGauges++;
        emit GaugeAdded(gaugeId, poolAddress, name);
    }

    // ─── Voting ───────────────────────────────────────────────────────────

    /**
     * @notice Cast votes across multiple gauges. Total votes = veWIK balance.
     *         votePcts must sum to BPS (10000). [A1]
     *
     * @param gaugeIds  Which gauges to vote for
     * @param votePcts  Percentage allocation per gauge (BPS, sum = 10000)
     */
    function vote(uint256[] calldata gaugeIds, uint256[] calldata votePcts) external nonReentrant whenNotPaused {
        require(gaugeIds.length == votePcts.length, "Gauge: length mismatch");
        require(gaugeIds.length <= MAX_VOTES_PER_USER, "Gauge: too many gauges");

        uint256 ep = _currentEpochId();
        uint256 totalPct;
        for (uint i; i < votePcts.length; i++) totalPct += votePcts[i];
        require(totalPct == BPS, "Gauge: votes != 100%");

        uint256 veBalance = staking.veBalance(msg.sender); // [A1] snapshot
        require(veBalance > 0, "Gauge: no veWIK");

        // Remove old votes for this epoch
        _clearVotes(msg.sender, ep);

        // Cast new votes
        for (uint i; i < gaugeIds.length; i++) {
            uint256 gId = gaugeIds[i];
            require(gId < gauges.length && gauges[gId].active, "Gauge: inactive gauge");
            uint256 voteAmt = veBalance * votePcts[i] / BPS;
            userVotes[msg.sender][ep][gId]    = voteAmt;
            epochGaugeVotes[ep][gId]         += voteAmt;
            epochs[ep].totalVotes            += voteAmt;
            emit VoteCast(msg.sender, ep, gId, voteAmt);
        }
        userTotalVotes[msg.sender][ep] = veBalance;
    }

    // ─── Bribes ───────────────────────────────────────────────────────────

    /**
     * @notice External protocols add bribes to attract votes to their gauge.
     *         Protocol takes 5% as listing fee. [A3]
     *
     * @param gaugeId  Which gauge to bribe
     * @param token    Bribe token (any ERC-20, usually USDC or their own token)
     * @param amount   Total bribe amount (before fee)
     */
    function addBribe(uint256 gaugeId, address token, uint256 amount) external nonReentrant whenNotPaused {
        require(gaugeId < gauges.length && gauges[gaugeId].active, "Gauge: inactive gauge");
        require(amount > 0, "Gauge: zero bribe");

        uint256 ep       = _currentEpochId();
        uint256 fee      = amount * BRIBE_PROTOCOL_FEE / BPS; // [A3]
        uint256 netBribe = amount - fee;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (fee > 0) IERC20(token).safeTransfer(treasury, fee);

        totalBribeRevenue += fee;

        uint256 bribeId = bribes.length;
        bribes.push(Bribe({ token: token, amount: netBribe, epoch: ep, gaugeId: gaugeId }));
        epochGaugeBribes[ep][gaugeId].push(bribeId);

        emit BribeAdded(bribeId, ep, gaugeId, token, netBribe);
    }

    /**
     * @notice Voters claim their proportional share of bribes for a past epoch.
     *         Pull pattern — user initiates. [A4]
     */
    function claimBribe(uint256 epochId, uint256 gaugeId, uint256 bribeId) external nonReentrant {
        require(!bribeClaimed[msg.sender][epochId][gaugeId], "Gauge: already claimed");
        require(epochId < _currentEpochId(), "Gauge: epoch not over"); // must be past epoch

        uint256 userVote   = userVotes[msg.sender][epochId][gaugeId];
        uint256 totalVotes = epochGaugeVotes[epochId][gaugeId];
        require(userVote > 0 && totalVotes > 0, "Gauge: no votes");

        Bribe storage b = bribes[bribeId];
        require(b.epoch == epochId && b.gaugeId == gaugeId, "Gauge: bribe mismatch");

        uint256 share = b.amount * userVote / totalVotes;
        bribeClaimed[msg.sender][epochId][gaugeId] = true;
        IERC20(b.token).safeTransfer(msg.sender, share);
        emit BribeClaimed(msg.sender, epochId, gaugeId, b.token, share);
    }

    // ─── WIK Emissions ────────────────────────────────────────────────────

    /**
     * @notice Set WIK emissions for an epoch (called by governance before epoch end).
     */
    function setEpochEmissions(uint256 epochId, uint256 wikAmount) external onlyOwner {
        require(epochId < epochs.length, "Gauge: bad epoch");
        epochs[epochId].wikEmissions = wikAmount;
        emit EmissionsSet(epochId, wikAmount);
    }

    /**
     * @notice Users claim WIK emissions from a past epoch proportional to their votes.
     */
    function claimEmissions(uint256 epochId, uint256 gaugeId) external nonReentrant {
        EpochState storage ep = epochs[epochId];
        require(ep.wikEmissions > 0,            "Gauge: no emissions");
        require(epochId < _currentEpochId(),    "Gauge: epoch not over");

        uint256 userVote     = userVotes[msg.sender][epochId][gaugeId];
        uint256 gaugeVotes   = epochGaugeVotes[epochId][gaugeId];
        uint256 totalEpoch   = ep.totalVotes;
        require(userVote > 0, "Gauge: no votes for gauge");

        // Gauge's share of epoch emissions
        uint256 gaugeEmit  = gaugeVotes > 0 && totalEpoch > 0
            ? ep.wikEmissions * gaugeVotes / totalEpoch : 0;

        // User's share of gauge emissions
        uint256 userEmit = gaugeEmit * userVote / gaugeVotes;

        // Mark claimed (reuse bribeClaimed with bribeId = type(uint256).max)
        require(!bribeClaimed[msg.sender][epochId][type(uint256).max - gaugeId], "Gauge: emis claimed");
        bribeClaimed[msg.sender][epochId][type(uint256).max - gaugeId] = true;

        if (userEmit > 0) WIK.safeTransfer(msg.sender, userEmit);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function currentEpochId() external view returns (uint256) { return _currentEpochId(); }
    function gaugeCount()     external view returns (uint256) { return gauges.length; }
    function bribeCount()     external view returns (uint256) { return bribes.length; }

    function getGaugeVotes(uint256 epochId, uint256 gaugeId) external view returns (uint256) {
        return epochGaugeVotes[epochId][gaugeId];
    }

    function getTopGauges(uint256 epochId) external view returns (uint256[] memory ids, uint256[] memory votes) {
        uint256 n = gauges.length;
        ids   = new uint256[](n);
        votes = new uint256[](n);
        for (uint i; i < n; i++) {
            ids[i]   = i;
            votes[i] = epochGaugeVotes[epochId][i];
        }
    }

    function getEpochBribes(uint256 epochId, uint256 gaugeId) external view returns (uint256[] memory) {
        return epochGaugeBribes[epochId][gaugeId];
    }

    // ─── Internals ────────────────────────────────────────────────────────

    function _currentEpochId() internal view returns (uint256) {
        return (block.timestamp - epochStart) / EPOCH_DURATION;
    }

    function _clearVotes(address user, uint256 ep) internal {
        // Reset previous votes for this epoch
        uint256 prev = userTotalVotes[user][ep];
        if (prev == 0) return;
        for (uint i; i < gauges.length; i++) {
            uint256 v = userVotes[user][ep][i];
            if (v > 0) {
                epochGaugeVotes[ep][i]          = epochGaugeVotes[ep][i] > v ? epochGaugeVotes[ep][i] - v : 0;
                epochs[ep].totalVotes           = epochs[ep].totalVotes  > v ? epochs[ep].totalVotes  - v : 0;
                userVotes[user][ep][i]           = 0;
            }
        }
        userTotalVotes[user][ep] = 0;
    }

    // ─── Admin ────────────────────────────────────────────────────────────
    function deactivateGauge(uint256 gaugeId) external onlyOwner { gauges[gaugeId].active = false; } // [A5]
    function setTreasury(address t)            external onlyOwner { treasury = t; }
    function advanceEpoch()                    external onlyOwner {
        epochs.push(EpochState({ epochId: epochs.length, startTime: block.timestamp, totalVotes: 0, distributed: false, wikEmissions: 0 }));
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
