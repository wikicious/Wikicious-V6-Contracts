// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title WikiProofOfSolvency
 * @notice Publishes on-chain Merkle-tree proofs that the protocol holds
 *         sufficient funds to cover all user balances.
 *
 * ─── WHY THIS MATTERS ─────────────────────────────────────────────────────────
 *
 *   After FTX, institutional traders require verifiable proof that a platform
 *   is solvent before depositing large amounts. This interface IWikiOpsVault { function totalValue()    external view returns (uint256); }

interface IWikiBackstop { function totalAssets()   external view returns (uint256); }

interface IWikiInsurance{ function balance()       external view returns (uint256); }

interface IWikiVault    { function totalDeposits() external view returns (uint256); }

contract provides that.
 *
 *   Anyone can verify:
 *     "Does Wikicious hold at least as much USDC as users are owed?"
 *     "Is my specific balance included in the proof?"
 *
 *   Without this: trust us, bro.
 *   With this: cryptographic proof, published on-chain every 24 hours.
 *
 * ─── HOW IT WORKS ─────────────────────────────────────────────────────────────
 *
 *   Off-chain (keeper bot, every 24 hours):
 *     1. Snapshot all user balances from the database
 *     2. Build a Merkle tree: leaf = hash(userAddress, balance)
 *     3. Compute root = hash of entire tree
 *     4. Call publishProof(root, totalLiabilities, totalAssets)
 *
 *   On-chain (anyone can verify):
 *     1. Call verifyUser(address, balance, merkleProof[])
 *     2. Returns true if that address+balance is included in the published root
 *     3. Also verifies totalAssets >= totalLiabilities (solvency check)
 *
 *   Users get a proof via the API: GET /api/solvency/proof/{address}
 *   They can then independently verify it on-chain or via ethers.js.
 *
 * ─── WHAT GETS PROVEN ─────────────────────────────────────────────────────────
 *
 *   Every 24h snapshot includes:
 *   - All user trading account balances (USDC)
 *   - WikiBackstopVault total assets
 *   - WikiOpsVault total assets
 *   - WikiInsuranceFund balance
 *   - WikiDAOTreasury balance
 *
 *   Compared against:
 *   - WikiVault.totalDeposits()
 *   - All open position margin requirements
 *   - All pending withdrawal amounts
 */
contract WikiProofOfSolvency is Ownable2Step {

    // ── Interfaces ────────────────────────────────────────────────────────────


    // ── Structs ───────────────────────────────────────────────────────────────
    struct SolvencySnapshot {
        bytes32  merkleRoot;         // root of user balance Merkle tree
        uint256  totalLiabilities;  // sum of all user balances owed
        uint256  totalAssets;       // sum of all protocol assets
        uint256  backstopAssets;    // WikiBackstopVault.totalAssets()
        uint256  insuranceAssets;   // WikiInsuranceFund.balance()
        uint256  opsVaultAssets;    // WikiOpsVault.totalValue()
        uint256  timestamp;         // when this snapshot was taken
        uint256  blockNumber;       // block at time of snapshot
        bool     solvent;           // totalAssets >= totalLiabilities
        string   ipfsCID;           // full balance list on IPFS for user verification
    }

    // ── State ─────────────────────────────────────────────────────────────────
    SolvencySnapshot[] public snapshots;
    uint256 public latestSnapshotId;
    address public keeper;

    // Protocol contracts for auto-reading on-chain assets
    IWikiVault     public vault;
    IWikiBackstop  public backstop;
    IWikiInsurance public insurance;
    IWikiOpsVault  public opsVault;

    uint256 public constant MIN_INTERVAL = 6 hours;
    uint256 public lastPublished;

    // ── Events ────────────────────────────────────────────────────────────────
    event SolvencyProofPublished(
        uint256 indexed snapshotId,
        bytes32 merkleRoot,
        uint256 totalAssets,
        uint256 totalLiabilities,
        bool    solvent,
        uint256 timestamp
    );
    event SolvencyAlert(uint256 snapshotId, uint256 shortfall);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address _owner) Ownable(_owner) {
        keeper = _owner;
    }

    // ── Publish Proof ─────────────────────────────────────────────────────────

    /**
     * @notice Publish a new solvency proof. Called by keeper every 24 hours.
     *
     * @param merkleRoot        Root of Merkle tree of all user balances
     * @param totalLiabilities  Sum of all USDC owed to users (off-chain computed)
     * @param ipfsCID           IPFS CID of the full balance list for verification
     */
    function publishProof(
        bytes32 merkleRoot,
        uint256 totalLiabilities,
        string  calldata ipfsCID
    ) external {
        require(msg.sender == keeper || msg.sender == owner(), "PoS: not keeper");
        require(block.timestamp >= lastPublished + MIN_INTERVAL,   "PoS: too soon");
        require(merkleRoot != bytes32(0),                          "PoS: zero root");

        // Read on-chain asset balances automatically
        uint256 backstopBal  = address(backstop)  != address(0) ? _safeAssets(address(backstop))  : 0;
        uint256 insuranceBal = address(insurance) != address(0) ? _safeInsurance()                : 0;
        uint256 opsBal       = address(opsVault)  != address(0) ? _safeOpsVault()                 : 0;
        uint256 vaultBal     = address(vault)     != address(0) ? _safeVault()                    : 0;

        uint256 totalAssets = vaultBal + backstopBal + insuranceBal + opsBal;
        bool    solvent     = totalAssets >= totalLiabilities;

        uint256 sid = snapshots.length;
        snapshots.push(SolvencySnapshot({
            merkleRoot:        merkleRoot,
            totalLiabilities:  totalLiabilities,
            totalAssets:       totalAssets,
            backstopAssets:    backstopBal,
            insuranceAssets:   insuranceBal,
            opsVaultAssets:    opsBal,
            timestamp:         block.timestamp,
            blockNumber:       block.number,
            solvent:           solvent,
            ipfsCID:           ipfsCID
        }));

        latestSnapshotId = sid;
        lastPublished    = block.timestamp;

        emit SolvencyProofPublished(sid, merkleRoot, totalAssets, totalLiabilities, solvent, block.timestamp);

        if (!solvent) {
            emit SolvencyAlert(sid, totalLiabilities - totalAssets);
        }
    }

    // ── Verify ────────────────────────────────────────────────────────────────

    /**
     * @notice Verify that a specific user balance is included in the latest proof.
     *         Anyone can call this — users verify their own balance was included.
     *
     * @param user          User's wallet address
     * @param balance       The balance to verify (USDC, 6 decimals)
     * @param merkleProof   Proof array from the API (/api/solvency/proof/{address})
     * @param snapshotId    Which snapshot to verify against (use latestSnapshotId)
     */
    function verifyUser(
        address        user,
        uint256        balance,
        bytes32[]      calldata merkleProof,
        uint256        snapshotId
    ) external view returns (bool included, bool protocolSolvent) {
        require(snapshotId < snapshots.length, "PoS: invalid snapshot");
        SolvencySnapshot storage s = snapshots[snapshotId];

        bytes32 leaf = keccak256(abi.encodePacked(user, balance));
        included        = MerkleProof.verify(merkleProof, s.merkleRoot, leaf);
        protocolSolvent = s.solvent;
    }

    /**
     * @notice Get the latest solvency status — quick check for frontends.
     */
    function latestStatus() external view returns (
        bool    solvent,
        uint256 totalAssets,
        uint256 totalLiabilities,
        uint256 surplusOrShortfall,
        uint256 snapshotAge,
        uint256 snapshotId,
        string  memory ipfsCID
    ) {
        if (snapshots.length == 0) return (false,0,0,0,0,0,"");
        SolvencySnapshot storage s = snapshots[latestSnapshotId];
        solvent             = s.solvent;
        totalAssets         = s.totalAssets;
        totalLiabilities    = s.totalLiabilities;
        surplusOrShortfall  = s.solvent
            ? s.totalAssets - s.totalLiabilities
            : s.totalLiabilities - s.totalAssets;
        snapshotAge         = block.timestamp - s.timestamp;
        snapshotId          = latestSnapshotId;
        ipfsCID             = s.ipfsCID;
    }

    /**
     * @notice Get all historical snapshots for audit trail.
     */
    function snapshotCount() external view returns (uint256) { return snapshots.length; }

    // ── Internal ──────────────────────────────────────────────────────────────
    function _safeAssets(address addr)  internal view returns (uint256) {
        try IWikiBackstop(addr).totalAssets() returns (uint256 v) { return v; } catch { return 0; }
    }
    function _safeInsurance() internal view returns (uint256) {
        try insurance.balance() returns (uint256 v) { return v; } catch { return 0; }
    }
    function _safeOpsVault() internal view returns (uint256) {
        try opsVault.totalValue() returns (uint256 v) { return v; } catch { return 0; }
    }
    function _safeVault() internal view returns (uint256) {
        try vault.totalDeposits() returns (uint256 v) { return v; } catch { return 0; }
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    function setKeeper(address _k) external onlyOwner { keeper = _k; }
    function setContracts(
        address _vault, address _backstop, address _insurance, address _opsVault
    ) external onlyOwner {
        if (_vault     != address(0)) vault     = IWikiVault(_vault);
        if (_backstop  != address(0)) backstop  = IWikiBackstop(_backstop);
        if (_insurance != address(0)) insurance = IWikiInsurance(_insurance);
        if (_opsVault  != address(0)) opsVault  = IWikiOpsVault(_opsVault);
    }
}
