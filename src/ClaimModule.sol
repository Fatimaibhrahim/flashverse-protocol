// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  ClaimModule
 * @author FlashVerse
 * @notice Production-grade Merkle-based airdrop & linear-vesting distribution module.
 * Supports ETH and any ERC-20 token.
 *
 * @dev    Security model
 * ─────────────
 * • Strict Checks-Effects-Interactions (CEI) in EVERY claim path.
 * • ReentrancyGuard on all external state-mutating functions.
 * • Per-airdrop ID uniqueness enforced via `exists` bitmap.
 * • Per-airdrop Merkle-root uniqueness enforced via `usedRoots` bitmap.
 * • Leaf pre-image includes (account, allocation, nonce, category) so
 * each wallet has exactly one leaf per airdrop; replay is impossible.
 * • Nonce-per-airdrop-per-account is incremented on every successful
 * claim, so old proofs are invalidated automatically.
 * • BatchClaim enforces CEI correctly: all state is written BEFORE any
 * external token transfer.
 * • Duplicate airdrop IDs within a single batch call are detected and
 * rejected in the validation phase, preventing double-spend.
 * • `tokens` parameter removed from batchClaim; token address is always
 * read from the immutable on-chain Airdrop struct.
 * • emergencyWithdraw is protected by both ADMIN_ROLE and nonReentrant.
 *
 * @dev    Vesting formula
 * ────────────────
 * before cliff  → 0
 * after full duration → 100 %
 * between cliff and duration → linear interpolation over elapsed time
 * from `start` (not from cliff end).
 */
contract ClaimModule is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  ROLES
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");

    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public constant MAX_BATCH_SIZE = 50;

    // ═══════════════════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    struct Airdrop {
        bytes32 merkleRoot;
        address token;          // address(0) → native ETH
        uint256 totalAllocated;
        uint256 createdAt;
        uint256 start;
        uint256 cliff;          // seconds after `start` before any tokens vest
        uint256 duration;       // total vesting window in seconds (0 = instant)
        bool    active;
    }

    // Internal helper used only inside batchClaim to aggregate transfers.
    struct TokenClaim {
        address token;
        uint256 amount;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════════════════

    bool public globalPaused;

    /// @notice airdropId → Airdrop data
    mapping(uint256 => Airdrop) public airdrops;

    /// @notice airdropId → account → total tokens already transferred
    mapping(uint256 => mapping(address => uint256)) public claimed;

    /// @notice airdropId → account → current nonce (increments on every claim)
    mapping(uint256 => mapping(address => uint256)) public nonces;

    /// @notice airdropId → true if it has been created
    mapping(uint256 => bool) public exists;

    /// @notice merkleRoot → true if already used in any airdrop
    mapping(bytes32 => bool) public usedRoots;

    /// @notice Ordered list of all registered airdrop IDs (for off-chain indexing)
    uint256[] public airdropIds;

    // ═══════════════════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error InvalidAirdrop();
    error AirdropNotActive();
    error GloballyPaused();
    error InvalidParameters();
    error InvalidStartTime();
    error RootAlreadyUsed();
    error InvalidProof();
    error InvalidNonce();
    error NothingToClaim();
    error ETHTransferFailed();
    error BatchSizeExceeded();
    error BatchLengthMismatch();
    error DuplicateIdInBatch(uint256 id);

    // ═══════════════════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event AirdropCreated(
        uint256 indexed id,
        address indexed token,
        bytes32 merkleRoot,
        uint256 totalAllocated,
        uint256 start,
        uint256 cliff,
        uint256 duration
    );
    event AirdropToggled(uint256 indexed id, bool active);
    event GlobalPauseSet(bool paused);
    event Claimed(
        uint256 indexed id,
        address indexed account,
        uint256 amount,
        uint256 nonce
    );
    event BatchClaimed(
        address indexed account,
        uint256[] ids,
        uint256[] amounts
    );
    event EmergencyWithdraw(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ═══════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE,         admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(MONITOR_ROLE,       admin);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (globalPaused) revert GloballyPaused();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ADMIN — AIRDROP MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a new airdrop.
     *
     * @param id              Unique numeric identifier for this airdrop (≥ 1).
     * @param token           ERC-20 token address, or address(0) for native ETH.
     * @param merkleRoot      Root of the Merkle tree; must never have been used before.
     * @param totalAllocated  Total tokens available for this airdrop (informational).
     * @param start           Unix timestamp at which vesting begins (must be ≥ block.timestamp).
     * @param cliffSeconds    Seconds after `start` before any tokens are claimable.
     * @param durationSeconds Total length of the vesting window in seconds.
     * Pass 0 for instant (no vesting); cliff must then also be 0.
     *
     * @dev   Both `id` and `merkleRoot` are globally unique across all airdrops.
     */
    function createAirdrop(
        uint256 id,
        address token,
        bytes32 merkleRoot,
        uint256 totalAllocated,
        uint256 start,
        uint256 cliffSeconds,
        uint256 durationSeconds
    ) external onlyRole(ADMIN_ROLE) {
        // ── Checks ──────────────────────────────────────────────────────
        if (id == 0 || exists[id])                       revert InvalidParameters();
        if (merkleRoot == bytes32(0) || usedRoots[merkleRoot]) revert RootAlreadyUsed();
        if (totalAllocated == 0)                          revert InvalidParameters();
        if (start < block.timestamp)                      revert InvalidStartTime();

        // cliff/duration consistency
        if (durationSeconds == 0 && cliffSeconds != 0)  revert InvalidParameters();
        if (cliffSeconds > durationSeconds)              revert InvalidParameters();

        // ── Effects ─────────────────────────────────────────────────────
        airdrops[id] = Airdrop({
            merkleRoot:     merkleRoot,
            token:          token,
            totalAllocated: totalAllocated,
            createdAt:      block.timestamp,
            start:          start,
            cliff:          cliffSeconds,
            duration:       durationSeconds,
            active:         true
        });

        exists[id]          = true;
        usedRoots[merkleRoot] = true;
        airdropIds.push(id);

        emit AirdropCreated(id, token, merkleRoot, totalAllocated, start, cliffSeconds, durationSeconds);
    }

    /**
     * @notice Enable or disable a specific airdrop without destroying its data.
     */
    function toggleAirdrop(uint256 id, bool active) external onlyRole(ADMIN_ROLE) {
        if (!exists[id]) revert InvalidAirdrop();
        airdrops[id].active = active;
        emit AirdropToggled(id, active);
    }

    /**
     * @notice Pause or unpause all claim operations globally.
     */
    function setGlobalPause(bool paused) external onlyRole(PAUSER_ROLE) {
        globalPaused = paused;
        emit GlobalPauseSet(paused);
    }

    /**
     * @notice Withdraw any tokens or ETH from this contract in an emergency.
     * @dev    Should only be used if funds become stranded (e.g., a bad airdrop config).
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdraw(token, to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the vested portion of `allocation` for airdrop `id` at the
     * current block timestamp.
     *
     * @param id         Airdrop identifier.
     * @param allocation Total allocation for the querying account.
     * @return           Amount that has vested so far (before subtracting already-claimed).
     */
    function vestedAmount(uint256 id, uint256 allocation) public view returns (uint256) {
        Airdrop memory a = airdrops[id];

        // Before cliff: nothing vested.
        if (block.timestamp < a.start + a.cliff) return 0;

        // Instant (no vesting) or past the end: fully vested.
        if (a.duration == 0 || block.timestamp >= a.start + a.duration) return allocation;

        // Linear vesting: elapsed time since `start` / total duration.
        uint256 elapsed = block.timestamp - a.start;
        return (allocation * elapsed) / a.duration;
    }

    /**
     * @notice Returns how many tokens `account` can claim right now for airdrop `id`.
     *
     * @param id         Airdrop identifier.
     * @param account    Wallet to check.
     * @param allocation Leaf allocation for this account.
     * @param nonce      Leaf nonce for this account.
     * @param category   Leaf category for this account.
     * @param proof      Merkle proof.
     * @return           Claimable amount (0 if proof invalid, paused, or nothing new vested).
     */
    function getClaimableAmount(
        uint256 id,
        address account,
        uint256 allocation,
        uint256 nonce,
        uint256 category,
        bytes32[] calldata proof
    ) external view returns (uint256) {
        if (!exists[id] || globalPaused) return 0;

        Airdrop memory a = airdrops[id];
        if (!a.active) return 0;

        bytes32 leaf = _buildLeaf(account, allocation, nonce, category);
        if (!MerkleProof.verify(proof, a.merkleRoot, leaf)) return 0;
        if (nonces[id][account] != nonce) return 0;

        uint256 vested  = vestedAmount(id, allocation);
        uint256 already = claimed[id][account];
        return vested > already ? vested - already : 0;
    }

    /**
     * @notice Returns the full list of registered airdrop IDs.
     */
    function getAirdropIds() external view returns (uint256[] memory) {
        return airdropIds;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CLAIM — SINGLE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim newly vested tokens for a single airdrop.
     *
     * @param id         Airdrop to claim from.
     * @param allocation Total allocation encoded in the Merkle leaf.
     * @param nonce      Nonce encoded in the Merkle leaf (must match on-chain nonce).
     * @param category   Category encoded in the Merkle leaf (e.g., team, public, etc.).
     * @param proof      Merkle proof for the leaf (account, allocation, nonce, category).
     */
    function claim(
        uint256 id,
        uint256 allocation,
        uint256 nonce,
        uint256 category,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        // ── Checks ──────────────────────────────────────────────────────
        if (!exists[id]) revert InvalidAirdrop();

        Airdrop memory a = airdrops[id];
        if (!a.active) revert AirdropNotActive();

        bytes32 leaf = _buildLeaf(msg.sender, allocation, nonce, category);
        if (!MerkleProof.verify(proof, a.merkleRoot, leaf)) revert InvalidProof();
        if (nonces[id][msg.sender] != nonce)                revert InvalidNonce();

        uint256 vested  = vestedAmount(id, allocation);
        uint256 already = claimed[id][msg.sender];
        if (vested <= already) revert NothingToClaim();

        uint256 claimable = vested - already;

        // ── Effects ─────────────────────────────────────────────────────
        claimed[id][msg.sender]  = already + claimable;
        nonces[id][msg.sender]   = nonce + 1;

        emit Claimed(id, msg.sender, claimable, nonce);

        // ── Interactions ─────────────────────────────────────────────────
        _transfer(a.token, msg.sender, claimable);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  CLAIM — BATCH
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim from multiple airdrops in a single transaction.
     *
     * @dev    Strict CEI is maintained:
     * 1. ALL checks (proof, nonce, existence, active, vested > claimed).
     * 2. Detect duplicate IDs in the batch (prevent double-spend).
     * 3. Compute claimable amounts and aggregate by token.
     * 4. Write ALL state changes (claimed, nonces) and emit events.
     * 5. Execute ALL transfers last.
     *
     * The `tokens` parameter present in the original implementation has been
     * removed; the token address is always sourced from the on-chain struct.
     *
     * @param ids         Airdrop IDs to claim from (no duplicates allowed).
     * @param allocations Merkle-leaf allocations (parallel to ids).
     * @param noncesArr   Merkle-leaf nonces (parallel to ids).
     * @param categories  Merkle-leaf categories (parallel to ids).
     * @param proofs      Merkle proofs (parallel to ids).
     */
    function batchClaim(
        uint256[]   calldata ids,
        uint256[]   calldata allocations,
        uint256[]   calldata noncesArr,
        uint256[]   calldata categories,
        bytes32[][] calldata proofs
    ) external nonReentrant whenNotPaused {
        uint256 len = ids.length;

        // ── Checks: array sizes ──────────────────────────────────────────
        if (len == 0 || len > MAX_BATCH_SIZE)         revert BatchSizeExceeded();
        if (
            len != allocations.length ||
            len != noncesArr.length   ||
            len != categories.length  ||
            len != proofs.length
        ) revert BatchLengthMismatch();

        // ── Checks: validate every entry + detect duplicate IDs ──────────
        // We use a temporary in-memory bitmap (limited to MAX_BATCH_SIZE = 50
        // so a simple boolean array is cheap and safe).
        bool[] memory seenIdx = new bool[](len);

        for (uint256 i = 0; i < len; ) {
            uint256 id = ids[i];

            // Duplicate detection: compare against all previous entries.
            for (uint256 j = 0; j < i; ) {
                if (ids[j] == id) revert DuplicateIdInBatch(id);
                unchecked { ++j; }
            }

            if (!exists[id]) revert InvalidAirdrop();

            Airdrop memory a = airdrops[id];
            if (!a.active) revert AirdropNotActive();

            bytes32 leaf = _buildLeaf(msg.sender, allocations[i], noncesArr[i], categories[i]);
            if (!MerkleProof.verify(proofs[i], a.merkleRoot, leaf)) revert InvalidProof();
            if (nonces[id][msg.sender] != noncesArr[i])             revert InvalidNonce();

            uint256 vested = vestedAmount(id, allocations[i]);
            if (vested <= claimed[id][msg.sender]) revert NothingToClaim();

            seenIdx[i] = true; // mark validated (unused beyond this; here for clarity)
            unchecked { ++i; }
        }

        // ── Compute claimable amounts & aggregate transfers by token ──────
        uint256[]    memory claimableAmounts = new uint256[](len);
        TokenClaim[] memory tokenClaims      = new TokenClaim[](len);
        uint256 uniqueTokens = 0;

        for (uint256 i = 0; i < len; ) {
            uint256 id        = ids[i];
            Airdrop memory a  = airdrops[id];

            uint256 vested    = vestedAmount(id, allocations[i]);
            uint256 already   = claimed[id][msg.sender];
            uint256 claimable = vested - already;

            claimableAmounts[i] = claimable;

            // Aggregate by token address.
            bool found = false;
            for (uint256 j = 0; j < uniqueTokens; ) {
                if (tokenClaims[j].token == a.token) {
                    tokenClaims[j].amount += claimable;
                    found = true;
                    break;
                }
                unchecked { ++j; }
            }
            if (!found) {
                tokenClaims[uniqueTokens] = TokenClaim(a.token, claimable);
                unchecked { ++uniqueTokens; }
            }

            unchecked { ++i; }
        }

        // ── Effects: update ALL state before any external call ────────────
        for (uint256 i = 0; i < len; ) {
            uint256 id    = ids[i];
            uint256 nonce = noncesArr[i];

            claimed[id][msg.sender] += claimableAmounts[i];
            nonces[id][msg.sender]   = nonce + 1;

            emit Claimed(id, msg.sender, claimableAmounts[i], nonce);
            unchecked { ++i; }
        }

        emit BatchClaimed(msg.sender, ids, claimableAmounts);

        // ── Interactions: execute all transfers last ───────────────────────
        for (uint256 i = 0; i < uniqueTokens; ) {
            _transfer(tokenClaims[i].token, msg.sender, tokenClaims[i].amount);
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Build the Merkle leaf for (account, allocation, nonce, category).
    * Double-hashing prevents second-pre-image attacks against the tree.
     */
    function _buildLeaf(
        address account,
        uint256 allocation,
        uint256 nonce,
        uint256 category
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(account, allocation, nonce, category))
            )
        );
    }

    /**
     * @dev Unified transfer helper for ETH and ERC-20.
     * Always call AFTER all state changes (CEI).
     */
    function _transfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  RECEIVE
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Accept ETH deposits (used to fund ETH-based airdrops).
    receive() external payable {}
}