// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SmartAccountMultiSig (n-of-m) + ERC-1271 + batch exec + validateUserOp hook
/// @author Fatima / FlashVerse
/// @notice Multi-owner smart account wallet with threshold signatures, nonce, batch execution, and ERC-1271 support.
/// @dev No upgradeable imports — uses OpenZeppelin standard contracts only.

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

error ZeroAddress();
error InvalidSignature();
error Unauthorized();
error ExecutionFailed();
error LengthMismatch();
error DuplicateSigner(address signer);
error ThresholdOutOfRange(uint256 haveOwners, uint256 requested);
error OwnerAlready(address owner);
error OwnerNotFound(address owner);

contract SmartAccountMultiSig is IERC1271 {
    using ECDSA for bytes32;

    uint256 public nonce;
    uint256 public threshold;
    address[] public owners;
    mapping(address => bool) public isOwner;

    event Executed(address indexed target, uint256 value, bytes data);
    event BatchExecuted(uint256 count);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 newThreshold);

    constructor(address[] memory _owners, uint256 _threshold) {
        uint256 len = _owners.length;
        if (len == 0) revert ZeroAddress();
        if (_threshold == 0 || _threshold > len) revert ThresholdOutOfRange(len, _threshold);

        for (uint i = 0; i < len; i++) {
            address o = _owners[i];
            if (o == address(0)) revert ZeroAddress();
            if (isOwner[o]) revert OwnerAlready(o);
            isOwner[o] = true;
            owners.push(o);
            emit OwnerAdded(o);
        }
        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }

    // ----------------- INTERNAL UTILS -----------------
    function _execHash(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 _nonce,
        address self
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encodePacked("SMART_ACCOUNT_EXECUTE", self, target, value, keccak256(data), _nonce)
                )
            )
        );
    }

    function _batchHash(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        uint256 _nonce,
        address self
    ) internal pure returns (bytes32) {
        // FIX 1: Use abi.encode for arrays instead of abi.encodePacked
        bytes32 agg = keccak256(abi.encode(targets, values, datas));
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked("SMART_ACCOUNT_BATCH", self, agg, _nonce))
            )
        );
    }

    function _recoverUniqueSigners(bytes32 hash, bytes calldata signatures)
        internal
        view
        returns (uint256 uniqueCount)
    {
        uint256 sigLen = 65;
        if (signatures.length % sigLen != 0) revert InvalidSignature();
        uint256 count = signatures.length / sigLen;

        // FIX 2: Removed illegal mapping(address => bool) memory seen;
        address[] memory uniqueSigners = new address[](count);
        uniqueCount = 0;

        for (uint256 i = 0; i < count; i++) {
            uint256 offset = i * sigLen;
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := calldataload(add(signatures.offset, offset))
                s := calldataload(add(signatures.offset, add(offset, 32)))
                v := byte(0, calldataload(add(signatures.offset, add(offset, 64))))
            }

            bytes memory sig = new bytes(65);
            assembly {
                mstore(add(sig, 32), r)
                mstore(add(sig, 64), s)
                mstore8(add(sig, 96), v)
            }

            address signer = hash.recover(sig);
            if (signer == address(0)) revert InvalidSignature();
            if (!isOwner[signer]) revert Unauthorized();

            // Prevent duplicates via local check
            for (uint j = 0; j < uniqueCount; j++) {
                if (uniqueSigners[j] == signer) revert DuplicateSigner(signer);
            }

            uniqueSigners[uniqueCount] = signer;
            unchecked {
                uniqueCount++;
            }
        }

        if (uniqueCount < threshold) revert InvalidSignature();
    }

    // ----------------- EXECUTION -----------------
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes calldata signatures
    ) external payable returns (bytes memory) {
        bytes32 h = _execHash(target, value, data, nonce, address(this));
        _recoverUniqueSigners(h, signatures);
        unchecked {
            nonce++;
        }

        (bool ok, bytes memory res) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed();
        emit Executed(target, value, data);
        return res;
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes calldata signatures,
        bool allowFailures
    ) external payable returns (bool[] memory successes) {
        if (targets.length != values.length || targets.length != datas.length) revert LengthMismatch();
        bytes32 h = _batchHash(targets, values, datas, nonce, address(this));
        _recoverUniqueSigners(h, signatures);
        unchecked {
            nonce++;
        }

        successes = new bool[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, ) = targets[i].call{value: values[i]}(datas[i]);
            successes[i] = ok;
            if (!ok && !allowFailures) revert ExecutionFailed();
        }
        emit BatchExecuted(targets.length);
    }

    // ----------------- OWNER MANAGEMENT -----------------
    function addOwner(address newOwner) external {
        // FIX: Enforce call through execute() or executeBatch()
        require(msg.sender == address(this), "Unauthorized");
        
        if (newOwner == address(0)) revert ZeroAddress();
        if (isOwner[newOwner]) revert OwnerAlready(newOwner);
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    function removeOwner(address ownerToRemove) external {
        // FIX: Enforce call through execute() or executeBatch()
        require(msg.sender == address(this), "Unauthorized");
        
        if (!isOwner[ownerToRemove]) revert OwnerNotFound(ownerToRemove);
        isOwner[ownerToRemove] = false;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        if (threshold > owners.length) threshold = owners.length;
        emit OwnerRemoved(ownerToRemove);
    }

    function setThreshold(uint256 newThreshold) external {
        // FIX: Enforce call through execute() or executeBatch()
        require(msg.sender == address(this), "Unauthorized");

        if (newThreshold == 0 || newThreshold > owners.length)
            revert ThresholdOutOfRange(owners.length, newThreshold);
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    // ----------------- ERC-1271 -----------------
    function isValidSignature(bytes32 hash, bytes memory signatures) public view override returns (bytes4) {
        // NOTE: `hash` is assumed to be the Ethereum Signed Message hash already (no double-prefixing).
        uint256 sigLen = 65;
        if (signatures.length % sigLen != 0) return 0xffffffff;
        uint256 count = signatures.length / sigLen;
        uint256 valid;
        address[] memory seen = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 offset = i * sigLen;
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(add(signatures, 32), offset))
                s := mload(add(add(signatures, 64), offset))
                v := byte(0, mload(add(add(signatures, 96), offset)))
            }
            bytes memory single = new bytes(65);
            assembly {
                mstore(add(single, 32), r)
                mstore(add(single, 64), s)
                mstore8(add(single, 96), v)
            }
            address signer = hash.recover(single);
            if (isOwner[signer]) {
                bool dup;
                for (uint256 j = 0; j < valid; j++) {
                    if (seen[j] == signer) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    seen[valid] = signer;
                    valid++;
                }
            }
        }
        if (valid >= threshold) return 0x1626ba7e;
        return 0xffffffff;
    }

    // ----------------- ERC-4337 HOOK STUB -----------------
    function validateUserOpStub(bytes calldata userOp, bytes calldata signatures) external view returns (bool) {
        // FIX 3: Manually create the Ethereum Signed Message Hash to bypass the compiler linking issue
        bytes32 userOpHash = keccak256(userOp);
        bytes32 h = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        return isValidSignature(h, signatures) == 0x1626ba7e;
    }

    receive() external payable {}
}