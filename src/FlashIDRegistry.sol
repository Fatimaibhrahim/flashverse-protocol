// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FlashIDRegistry
/// @author Fatima / FlashVerse
/// @notice A simple, secure, and gas-efficient registry for FlashIDs (human-readable names ↔ addresses).
/// @dev Uses internal storage with keccak256 hashing for uniqueness and fast lookups. Stores original strings for display.
/// IMPORTANT: This contract performs case-normalization (lowercase) automatically for IDs to ensure consistency.
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; 

// --- Custom Errors ---
error InvalidLength(uint256 length);
error InvalidID();
error AlreadyRegistered(address user);
error IDTaken(string id);
error NotRegistered(address user);
error IDNotFound(string id);
error Unauthorized();

// --- Contract ---
contract FlashIDRegistry is Ownable {
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// -------------------------
    /// Events
    /// -------------------------
    event IDRegistered(address indexed user, string id, bytes32 indexed idHash);
    event IDUpdated(address indexed user, string oldId, string newId, bytes32 indexed oldHash, bytes32 indexed newHash);
    event IDRevoked(address indexed user, string id, bytes32 indexed idHash);
    event IDReserved(address indexed admin, string id, address indexed to, bytes32 indexed idHash);
    event IDForceRevoked(address indexed admin, address indexed user, string id, bytes32 indexed idHash);

    /// -------------------------
    /// Storage
    /// -------------------------
    mapping(address => bytes32) private _idHashOf;
    mapping(bytes32 => address) private _ownerOfHash;
    mapping(bytes32 => string) private _idStringOf;
    uint256 public totalRegistered;

    /// -------------------------
    /// Configurable limits
    /// -------------------------
    uint256 public constant MIN_LENGTH = 3;
    uint256 public constant MAX_LENGTH = 32;

    /// -------------------------
    /// Modifiers & helpers
    /// -------------------------

    function _onlyRegistered() internal view {
        if (_idHashOf[msg.sender] == bytes32(0)) revert NotRegistered(msg.sender);
    }
    
    modifier onlyRegistered() {
        _onlyRegistered();
        _;
    }

    /// @dev Compute stable hash for an id string (after normalization) using assembly for gas optimization.
    function _hashId(string memory id) internal pure returns (bytes32) {
        // Optimizing keccak256 using assembly to reduce gas cost (addresses forge lint note)
        bytes memory data = bytes(id);
        bytes32 result;
        assembly {
            // keccak256(memory_pointer, length_of_data)
            result := keccak256(add(data, 32), mload(data))
        }
        return result;
    }

    /// @dev Normalize ID to lowercase for consistency and check for invalid characters (like spaces).
    function _toLower(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);

        for (uint i = 0; i < bStr.length; i++) {
            // Check for space (0x20)
            if (bStr[i] == 0x20) revert InvalidID();

            // Convert uppercase (A-Z) to lowercase (a-z)
            if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
    }

    /// @dev Validate ID length.
    function _validateId(string memory id) internal pure { 
        uint256 len = bytes(id).length;
        if (len < MIN_LENGTH || len > MAX_LENGTH) revert InvalidLength(len);
    }

    /// -------------------------
    /// Core user functions
    /// -------------------------

    /// @notice Register a new FlashID for your account.
    /// @param id The name to register.
    function registerId(string calldata id) external { 
        string memory normalizedId = _toLower(id);
        _validateId(normalizedId);

        if (_idHashOf[msg.sender] != bytes32(0)) revert AlreadyRegistered(msg.sender);

        bytes32 idHash = _hashId(normalizedId);
        if (_ownerOfHash[idHash] != address(0)) revert IDTaken(normalizedId);

        // Store
        _idHashOf[msg.sender] = idHash;
        _ownerOfHash[idHash] = msg.sender;
        _idStringOf[idHash] = normalizedId;
        totalRegistered += 1;

        emit IDRegistered(msg.sender, normalizedId, idHash);
    }

    /// @notice Update your FlashID to a new name.
    /// @param newId The new name.
    function updateId(string calldata newId) external onlyRegistered { 
        string memory normalizedNewId = _toLower(newId);
        _validateId(normalizedNewId);

        bytes32 oldHash = _idHashOf[msg.sender];
        string memory oldId = _idStringOf[oldHash];
        bytes32 newHash = _hashId(normalizedNewId);

        // If same as current, do nothing
        if (newHash == oldHash) {
            emit IDUpdated(msg.sender, oldId, normalizedNewId, oldHash, newHash);
            return;
        }

        if (_ownerOfHash[newHash] != address(0)) revert IDTaken(normalizedNewId);

        // Clear old
        delete _ownerOfHash[oldHash];
        delete _idStringOf[oldHash];

        // Set new
        _idHashOf[msg.sender] = newHash;
        _ownerOfHash[newHash] = msg.sender;
        _idStringOf[newHash] = normalizedNewId;

        emit IDUpdated(msg.sender, oldId, normalizedNewId, oldHash, newHash);
    }

    /// @notice Revoke your FlashID (removal).
    function revokeId() external onlyRegistered { 
        bytes32 idHash = _idHashOf[msg.sender];
        string memory id = _idStringOf[idHash];

        // Clear
        delete _idHashOf[msg.sender];
        delete _ownerOfHash[idHash];
        delete _idStringOf[idHash];
        totalRegistered -= 1;

        emit IDRevoked(msg.sender, id, idHash);
    }

    /// -------------------------
    /// View helpers
    /// -------------------------

    /// @notice Get the FlashID (string) for a given address, or "" if not registered.
    /// @param user The address to query.
    /// @return The registered ID or empty string.
    function getId(address user) external view returns (string memory) { 
        bytes32 h = _idHashOf[user];
        if (h == bytes32(0)) return "";
        return _idStringOf[h];
    }

    /// @notice Resolve the address for a given ID, or address(0) if not found.
    /// @param id The ID to resolve (case-insensitive due to normalization).
    /// @return The owner address or zero address.
    function resolveAddress(string calldata id) external view returns (address) {
        string memory normalizedId = _toLower(id);
        bytes32 h = _hashId(normalizedId);
        return _ownerOfHash[h];
    }

    /// @notice Check if an ID is taken.
    /// @param id The ID to check (case-insensitive).
    /// @return True if taken.
    function isTaken(string calldata id) external view returns (bool) {
        string memory normalizedId = _toLower(id);
        bytes32 h = _hashId(normalizedId);
        return _ownerOfHash[h] != address(0);
    }

    /// @notice Check if an address is registered.
    /// @param user The address to check.
    /// @return True if registered.
    function isRegistered(address user) external view returns (bool) {
        return _idHashOf[user] != bytes32(0);
    }

    /// -------------------------
    /// Admin functions (owner)
    /// -------------------------

    /// @notice Reserve an ID on behalf of an address (admin-only).
    /// @param id The ID to reserve (will be normalized).
    /// @param to The address to assign it to.
    function adminReserve(string calldata id, address to) external onlyOwner {
        string memory normalizedId = _toLower(id);
        _validateId(normalizedId);

        bytes32 h = _hashId(normalizedId);
        if (_ownerOfHash[h] != address(0)) revert IDTaken(normalizedId);
        
        // Corrected check: bytes32 against bytes32(0)
        if (_idHashOf[to] != bytes32(0)) revert AlreadyRegistered(to);

        _idHashOf[to] = h;
        _ownerOfHash[h] = to;
        _idStringOf[h] = normalizedId;
        totalRegistered += 1;

        emit IDReserved(msg.sender, normalizedId, to, h);
    }

    /// @notice Force revoke a user's registration (admin-only).
    /// @param user The address to revoke from.
    function adminForceRevoke(address user) external onlyOwner {
        bytes32 h = _idHashOf[user];
        if (h == bytes32(0)) revert NotRegistered(user);

        string memory id = _idStringOf[h];

        delete _idHashOf[user];
        delete _ownerOfHash[h];
        delete _idStringOf[h];
        totalRegistered -= 1;

        emit IDForceRevoked(msg.sender, user, id, h);
    }

    /// -------------------------
    /// Misc
    /// -------------------------
    
    /// @notice Get the idHash registered for an address (for debugging/indexers).
    /// @param user The address.
    /// @return The idHash or zero.
    function idHashOf(address user) external view returns (bytes32) {
        return _idHashOf[user];
    }

    /// @notice Get the owner of a specific idHash.
    /// @param idHash The hash.
    /// @return The owner address or zero.
    function ownerOfHash(bytes32 idHash) external view returns (address) {
        return _ownerOfHash[idHash];
    }
}