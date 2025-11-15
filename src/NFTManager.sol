// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

error ZeroAddress();
error Unauthorized();
error InvalidOperation();
error TokenNotFound();
error InvalidAmount();
error CollectionNotFound();

interface INFTCollection {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function totalSupply(uint256 id) external view returns (uint256);
}

library NFTValidations {
    function isValidAddress(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddress();
    }

    function isValidAmount(uint256 amount) internal pure {
        if (amount == 0) revert InvalidAmount();
    }
}

// ----------------------------------------------------------
// CONTRACT FACTORIES 
// ----------------------------------------------------------

contract ManagedERC721 is ERC721URIStorage, ERC721Royalty {
    address public manager;

    constructor(string memory name_, string memory symbol_, address _manager) ERC721(name_, symbol_) {
        manager = _manager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Only manager");
        _;
    }

    function safeMint(address to, uint256 tokenId, string memory uri) external onlyManager {
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function burn(uint256 tokenId) external onlyManager {
        _burn(tokenId);
    }

    function updateTokenURI(uint256 tokenId, string memory uri) external onlyManager {
        _setTokenURI(tokenId, uri);
    }

    function setRoyalty(address receiver, uint96 feeNumerator) external onlyManager {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function tokenURI(uint256 tokenId) public view virtual override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorage, ERC721Royalty) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

contract ManagedERC1155 is ERC1155Supply, ERC1155URIStorage {
    address public manager;

    constructor(string memory baseURI, address _manager) ERC1155(baseURI) {
        manager = _manager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Only manager");
        _;
    }

    function mint(address to, uint256 id, uint256 amount, bytes memory data) external onlyManager {
        _mint(to, id, amount, data);
    }

    function burn(address from, uint256 id, uint256 amount) external onlyManager {
        _burn(from, id, amount);
    }

    function setURI(uint256 tokenId, string memory tokenURI) external onlyManager {
        _setURI(tokenId, tokenURI);
    }

    function uri(uint256 tokenId) public view override(ERC1155, ERC1155URIStorage) returns (string memory) {
        return ERC1155URIStorage.uri(tokenId);
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal virtual override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }

    // supportsInterface removed to resolve compiler error 2353.
}

// ----------------------------------------------------------
// MAIN MANAGER CONTRACT
// ----------------------------------------------------------

contract NFTManager is AccessControl, ReentrancyGuard {
    using Strings for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using NFTValidations for *; 

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    struct CollectionInfo {
        address addr;
        bool is1155;
        string name;
        string symbol; 
        address creator;
        uint256 createdAt;
        uint96 royaltyFee; 
        address royaltyReceiver;
    }

    uint256 public collectionCount;
    mapping(uint256 => CollectionInfo) public collections;
    mapping(address => uint256) public collectionIdByAddr;
    EnumerableSet.AddressSet private _allCollections; 

    event CollectionCreated(uint256 indexed id, address addr, bool is1155, address indexed creator);
    event NFTMinted(address indexed collection, address indexed to, uint256 tokenId, uint256 amount, bool is1155);
    event NFTBurned(address indexed collection, uint256 tokenId, uint256 amount, bool is1155);
    event URISet(address indexed collection, uint256 tokenId, string uri);
    event RoyaltySet(address indexed collection, address receiver, uint96 fee);
    event BatchMinted(address indexed collection, address[] to, uint256[] ids, uint256[] amounts, bool is1155);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    /* ========== MODIFIERS & HELPERS ========== */

    modifier validCollection(address collection, bool expectedIs1155) {
        uint256 id = collectionIdByAddr[collection];
        require(id > 0 && collections[id].is1155 == expectedIs1155, "Invalid collection");
        _;
    }

    /* ========== COLLECTION CREATION ========== */

    function createCollection(
        string memory name,
        string memory symbol,
        string memory baseURI,
        bool is1155,
        address royaltyReceiver,
        uint96 royaltyFee
    ) external onlyRole(ADMIN_ROLE) returns (address collectionAddr) {
        NFTValidations.isValidAddress(royaltyReceiver);
        require(royaltyFee <= 10000, "Royalty fee too high");

        if (is1155) {
            ManagedERC1155 c = new ManagedERC1155(baseURI, address(this));
            collectionAddr = address(c);
            symbol = "";
        } else {
            ManagedERC721 c = new ManagedERC721(name, symbol, address(this));
            collectionAddr = address(c);
        }

        collectionCount++;
        collections[collectionCount] = CollectionInfo({
            addr: collectionAddr,
            is1155: is1155,
            name: name,
            symbol: symbol,
            creator: msg.sender,
            createdAt: block.timestamp,
            royaltyFee: royaltyFee,
            royaltyReceiver: royaltyReceiver
        });
        collectionIdByAddr[collectionAddr] = collectionCount;
        _allCollections.add(collectionAddr);

        emit CollectionCreated(collectionCount, collectionAddr, is1155, msg.sender);
    }

    /* ========== NFT OPERATIONS ========== */

    function batchMintERC721(
        address collection,
        address[] memory to,
        uint256[] memory tokenIds,
        string[] memory uris
    ) external onlyRole(MINTER_ROLE) nonReentrant validCollection(collection, false) {
        require(to.length == tokenIds.length && tokenIds.length == uris.length, "Array length mismatch");
        uint256[] memory amounts = new uint256[](to.length); 
        for (uint256 i = 0; i < to.length; i++) {
            amounts[i] = 1;
            NFTValidations.isValidAddress(to[i]);
            ManagedERC721(collection).safeMint(to[i], tokenIds[i], uris[i]);
            emit NFTMinted(collection, to[i], tokenIds[i], 1, false);
        }
        emit BatchMinted(collection, to, tokenIds, amounts, false);
    }

    function batchMintERC1155(
        address collection,
        address[] memory to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external onlyRole(MINTER_ROLE) nonReentrant validCollection(collection, true) {
        require(to.length == ids.length && ids.length == amounts.length, "Array length mismatch");
        for (uint256 i = 0; i < to.length; i++) {
            NFTValidations.isValidAddress(to[i]);
            NFTValidations.isValidAmount(amounts[i]);
            ManagedERC1155(collection).mint(to[i], ids[i], amounts[i], data);
            emit NFTMinted(collection, to[i], ids[i], amounts[i], true);
        }
        emit BatchMinted(collection, to, ids, amounts, true);
    }

    function mintERC721(address collection, address to, uint256 tokenId, string memory uri)
        external onlyRole(MINTER_ROLE) nonReentrant validCollection(collection, false) {
        NFTValidations.isValidAddress(to);
        ManagedERC721(collection).safeMint(to, tokenId, uri);
        emit NFTMinted(collection, to, tokenId, 1, false);
    }

    function mintERC1155(address collection, address to, uint256 id, uint256 amount, bytes memory data)
        external onlyRole(MINTER_ROLE) nonReentrant validCollection(collection, true) {
        NFTValidations.isValidAddress(to);
        NFTValidations.isValidAmount(amount);
        ManagedERC1155(collection).mint(to, id, amount, data);
        emit NFTMinted(collection, to, id, amount, true);
    }

    function burnERC721(address collection, uint256 tokenId)
        external onlyRole(MINTER_ROLE) nonReentrant validCollection(collection, false) {
        ManagedERC721(collection).burn(tokenId);
        emit NFTBurned(collection, tokenId, 1, false);
    }

    function burnERC1155(address collection, address from, uint256 id, uint256 amount)
        external onlyRole(MINTER_ROLE) nonReentrant validCollection(collection, true) {
        NFTValidations.isValidAddress(from);
        NFTValidations.isValidAmount(amount);
        ManagedERC1155(collection).burn(from, id, amount);
        emit NFTBurned(collection, id, amount, true);
    }

    function setTokenURI(address collection, uint256 tokenId, string memory uri)
        external onlyRole(ADMIN_ROLE) validCollection(collection, false) {
        ManagedERC721(collection).updateTokenURI(tokenId, uri);
        emit URISet(collection, tokenId, uri);
    }

    function setTokenURI1155(address collection, uint256 tokenId, string memory uri)
        external onlyRole(ADMIN_ROLE) validCollection(collection, true) {
        ManagedERC1155(collection).setURI(tokenId, uri);
        emit URISet(collection, tokenId, uri);
    }

    function setRoyalty(address collection, address receiver, uint96 feeNumerator)
        external onlyRole(ADMIN_ROLE) validCollection(collection, false) {
        NFTValidations.isValidAddress(receiver);
        ManagedERC721(collection).setRoyalty(receiver, feeNumerator);
        collections[collectionIdByAddr[collection]].royaltyFee = feeNumerator;
        collections[collectionIdByAddr[collection]].royaltyReceiver = receiver;
        emit RoyaltySet(collection, receiver, feeNumerator);
    }

    /* ========== VIEWS & UTILITIES ========== */

    function getCollection(uint256 id) external view returns (CollectionInfo memory) {
        return collections[id];
    }

    function getAllCollections() external view returns (address[] memory) {
        return _allCollections.values();
    }

    function totalCollections() external view returns (uint256) {
        return _allCollections.length();
    }

    function getCollectionSupply(address collection, uint256 tokenId) external view returns (uint256) {
        if (_is1155(collection)) {
            return ManagedERC1155(collection).totalSupply(tokenId);
        } else {
            try ManagedERC721(collection).ownerOf(tokenId) returns (address owner) {
                return owner != address(0) ? 1 : 0;
            } catch {
                return 0; 
            }
        }
    }

    function _is1155(address collection) internal view returns (bool) {
        uint256 id = collectionIdByAddr[collection];
        return id > 0 && collections[id].is1155;
    }

    receive() external payable {}
}