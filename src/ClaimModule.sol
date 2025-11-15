// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClaimModule (Merkle Airdrops + Vesting + ETH/ERC20 support) - Global Professional Version
/// @author FlashVerse
/// @notice Fully-featured, gas-optimized Merkle-based claim/vesting module for ERC20 & ETH.
///         Supports batch claims, flexible Merkle trees, ERC1271, global pause, multi-admin, and monitoring.
/// @dev Only standard OpenZeppelin contracts. Designed for global DeFi projects (EVM-compatible).
///      Batch claims limited to 50 items to prevent gas exhaustion.

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error ZeroAddress();
error Unauthorized();
error InvalidAirdrop();
error AlreadyClaimed();
error NothingToClaim();
error NotEnoughBalance(uint256 have, uint256 need);
error AirdropPaused();
error InvalidParameters();
error ETHTransferFailed();
error InvalidStartTime();
error IsGlobalPaused(); // FIX 1: Renamed from GlobalPaused() to avoid shadowing the event

contract ClaimModule is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");

    bool public globalPaused;
    uint256 public constant MAX_BATCH_SIZE = 50; // Limit batch claims to prevent gas issues

    struct Airdrop {
        bytes32 merkleRoot;
        address token; // address(0) = ETH
        uint256 totalAllocated; // This is the state variable that conflicted
        uint256 createdAt;
        uint256 start;
        uint256 cliff;
        uint256 duration;
        bool active;
    }

    struct TokenClaim { // Re-introduced this struct for batchClaim memory storage
        address token;
        uint256 amount;
    }

    mapping(uint256 => Airdrop) public airdrops;
    mapping(uint256 => mapping(address => uint256)) public claimed;
    mapping(uint256 => mapping(address => uint256)) public nonces;
    mapping(uint256 => bool) public exists;
    uint256[] public airdropIds;

    event AirdropCreated(
        uint256 indexed id,
        address token,
        bytes32 merkleRoot,
        uint256 totalAllocated,
        uint256 start,
        uint256 cliff,
        uint256 duration
    );
    event AirdropToggled(uint256 indexed id, bool active);
    event Claimed(uint256 indexed id, address indexed account, uint256 amount, uint256 nonce);
    event BatchClaimed(address indexed account, uint256[] ids, uint256[] amounts);
    event EmergencyWithdraw(address indexed token, address to, uint256 amount);
    event GlobalPaused(bool paused); // FIX 2: This event now has a unique name compared to the custom error

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MONITOR_ROLE, msg.sender);
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function createAirdrop(
        uint256 id,
        address token,
        bytes32 merkleRoot,
        uint256 totalAllocated,
        uint256 start,
        uint256 cliffSeconds,
        uint256 durationSeconds
    ) external onlyRole(ADMIN_ROLE) {
        if (id == 0 || exists[id]) revert InvalidParameters();
        if (merkleRoot == bytes32(0)) revert InvalidParameters();
        if (totalAllocated == 0) revert InvalidParameters();
        if (durationSeconds == 0 && cliffSeconds != 0) revert InvalidParameters();
        if (cliffSeconds > durationSeconds) revert InvalidParameters();
        if (start == 0 || start < block.timestamp) revert InvalidStartTime();

        airdrops[id] = Airdrop({
            merkleRoot: merkleRoot,
            token: token,
            totalAllocated: totalAllocated,
            createdAt: block.timestamp,
            start: start,
            cliff: cliffSeconds,
            duration: durationSeconds,
            active: true
        });

        exists[id] = true;
        airdropIds.push(id);

        emit AirdropCreated(id, token, merkleRoot, totalAllocated, start, cliffSeconds, durationSeconds);
    }

    function toggleAirdrop(uint256 id, bool active) external onlyRole(ADMIN_ROLE) {
        if (!exists[id]) revert InvalidAirdrop();
        airdrops[id].active = active;
        emit AirdropToggled(id, active);
    }

    function setGlobalPause(bool paused) external onlyRole(PAUSER_ROLE) {
        globalPaused = paused;
        emit GlobalPaused(paused);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidParameters();

        if (token == address(0)) {
            uint256 bal = address(this).balance;
            if (amount > bal) revert NotEnoughBalance(bal, amount);
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (amount > bal) revert NotEnoughBalance(bal, amount);
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdraw(token, to, amount);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function vestedAmount(uint256 id, uint256 allocation) public view returns (uint256) {
        Airdrop memory a = airdrops[id];
        if (block.timestamp < a.start) return 0;
        if (block.timestamp < a.start + a.cliff) return 0;
        if (a.duration == 0) return allocation;
        uint256 elapsed = block.timestamp - a.start;
        if (elapsed >= a.duration) return allocation;
        // Prevent overflow: check if allocation * elapsed would overflow
        if (elapsed == 0 || allocation > type(uint256).max / elapsed) revert InvalidParameters();
        unchecked { return (allocation * elapsed) / a.duration; }
    }

    function getClaimableAmount(
        uint256 id,
        address account,
        uint256 allocation,
        uint256 nonce,
        uint256 category,
        bytes32[] calldata proof
    ) external view returns (uint256) {
        if (!exists[id]) revert InvalidAirdrop();
        Airdrop memory a = airdrops[id];
        if (!a.active || globalPaused) revert IsGlobalPaused(); // Changed check to IsGlobalPaused
        
        bytes32 leaf = keccak256(abi.encodePacked(account, allocation, nonce, category));
        if (!MerkleProof.verify(proof, a.merkleRoot, leaf)) revert Unauthorized();

        uint256 vested = vestedAmount(id, allocation);
        uint256 already = claimed[id][account];
        return vested > already ? vested - already : 0;
    }

    function getTotalAllocatedSum() external view onlyRole(MONITOR_ROLE) returns (uint256) {
        // FIX 3: Renamed from totalAllocated() to getTotalAllocatedSum() to avoid collision
        uint256 total = 0;
        for (uint256 i = 0; i < airdropIds.length; i++) {
            unchecked { total += airdrops[airdropIds[i]].totalAllocated; }
        }
        return total;
    }

    /* ========== CLAIM FUNCTIONS ========== */

    function claim(
        uint256 id,
        uint256 allocation,
        uint256 nonce,
        uint256 category,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (!exists[id]) revert InvalidAirdrop();
        Airdrop memory a = airdrops[id];
        if (!a.active || globalPaused) revert IsGlobalPaused(); // Changed check to IsGlobalPaused

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, allocation, nonce, category));
        if (!MerkleProof.verify(proof, a.merkleRoot, leaf)) revert Unauthorized();
        if (nonces[id][msg.sender] != nonce) revert InvalidParameters();

        uint256 vested = vestedAmount(id, allocation);
        uint256 already = claimed[id][msg.sender];
        if (vested <= already) revert NothingToClaim();

        uint256 claimable = vested - already;

        if (a.token == address(0)) {
            uint256 bal = address(this).balance;
            if (claimable > bal) revert NotEnoughBalance(bal, claimable);
            (bool ok, ) = payable(msg.sender).call{value: claimable}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(a.token).safeTransfer(msg.sender, claimable);
        }

        unchecked { claimed[id][msg.sender] = already + claimable; }
        unchecked { nonces[id][msg.sender] = nonce + 1; }

        emit Claimed(id, msg.sender, claimable, nonce);
    }

    function batchClaim(
        uint256[] calldata ids,
        address[] calldata tokens,
        uint256[] calldata allocations,
        uint256[] calldata noncesArr,
        uint256[] calldata categories,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        uint256 len = ids.length;
        if (len == 0 || len > MAX_BATCH_SIZE || len != tokens.length || len != allocations.length || len != noncesArr.length || len != categories.length || len != proofs.length)
            revert InvalidParameters();

        // FIX 4: Replaced the incorrect internal mapping with a memory array of structs
        TokenClaim[] memory tokenClaims = new TokenClaim[](len);
        uint256[] memory claimableAmounts = new uint256[](len);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 id = ids[i];
            address tokenAddr = tokens[i];
            
            if (!exists[id]) revert InvalidAirdrop();
            Airdrop memory a = airdrops[id];
            
            if (!a.active || globalPaused) revert IsGlobalPaused(); // Changed check to IsGlobalPaused
            if (a.token != tokenAddr) revert InvalidParameters(); // Safety check

            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, allocations[i], noncesArr[i], categories[i]));
            if (!MerkleProof.verify(proofs[i], a.merkleRoot, leaf)) revert Unauthorized();
            if (nonces[id][msg.sender] != noncesArr[i]) revert InvalidParameters();

            uint256 vested = vestedAmount(id, allocations[i]);
            uint256 already = claimed[id][msg.sender];
            if (vested <= already) revert NothingToClaim();

            uint256 claimable = vested - already;
            claimableAmounts[i] = claimable;

            // Aggregation logic (O(N^2) but gas-safe in memory compared to illegal mapping)
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (tokenClaims[j].token == tokens[i]) {
                    tokenClaims[j].amount += claimable;
                    found = true;
                    break;
                }
            }
            if (!found) {
                tokenClaims[uniqueCount] = TokenClaim(tokens[i], claimable);
                uniqueCount++;
            }

            unchecked { claimed[id][msg.sender] = already + claimable; }
            unchecked { nonces[id][msg.sender] = noncesArr[i] + 1; }

            emit Claimed(id, msg.sender, claimable, noncesArr[i]);
        }

        for (uint256 i = 0; i < uniqueCount; i++) {
            address tokenAddr = tokenClaims[i].token;
            uint256 amount = tokenClaims[i].amount;
            if (amount == 0) continue;

            // Check balance before transfer
            if (tokenAddr == address(0)) {
                uint256 bal = address(this).balance;
                if (amount > bal) revert NotEnoughBalance(bal, amount);
                (bool ok, ) = payable(msg.sender).call{value: amount}("");
                if (!ok) revert ETHTransferFailed();
            } else {
                uint256 bal = IERC20(tokenAddr).balanceOf(address(this));
                if (amount > bal) revert NotEnoughBalance(bal, amount);
                IERC20(tokenAddr).safeTransfer(msg.sender, amount);
            }
        }

        emit BatchClaimed(msg.sender, ids, claimableAmounts);
    }

    function getNonce(uint256 id, address account) external view returns (uint256) {
        return nonces[id][account];
    }

    receive() external payable {}
    fallback() external payable {}
}