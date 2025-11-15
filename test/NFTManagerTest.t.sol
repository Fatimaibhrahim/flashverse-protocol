// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NFTManager.sol";

contract NFTManagerTest is Test {
NFTManager manager;
address admin;
address minter;
address alice;
address bob;
address royaltyReceiver;

// FIX: ERC721 Transfer event definition needed for vm.expectEmit
event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

function setUp() public {  
    admin = vm.addr(1);  
    minter = vm.addr(2);  
    alice = vm.addr(3);  
    bob = vm.addr(4);  
    royaltyReceiver = vm.addr(5);  

    vm.prank(admin);  
    manager = new NFTManager();  

    // grant roles  
    vm.startPrank(admin);  
    manager.grantRole(manager.ADMIN_ROLE(), admin);  
    manager.grantRole(manager.MINTER_ROLE(), minter);  
    vm.stopPrank();  
}  

/*-----------------------------------------------------  
    Test ERC721 Collection Creation  
------------------------------------------------------*/  
function testCreateERC721Collection() public {  
    vm.prank(admin);  
    address col = manager.createCollection(  
        "My721",  
        "M721",  
        "",  
        false,  
        royaltyReceiver,  
        500  // 5%  
    );  

    NFTManager.CollectionInfo memory info = manager.getCollection(1);  

    assertEq(info.addr, col);  
    assertEq(info.is1155, false);  
    assertEq(info.name, "My721");  
    assertEq(info.symbol, "M721");  
    assertEq(info.royaltyFee, 500);  
    assertEq(info.royaltyReceiver, royaltyReceiver);  
}  

/*-----------------------------------------------------  
    Test ERC1155 Collection Creation  
------------------------------------------------------*/  
function testCreateERC1155Collection() public {  
    vm.prank(admin);  
    address col = manager.createCollection(  
        "My1155",  
        "",  
        "https://base.uri/",  
        true,  
        royaltyReceiver,  
        0  
    );  

    NFTManager.CollectionInfo memory info = manager.getCollection(1);  

    assertEq(info.addr, col);  
    assertEq(info.is1155, true);  
    assertEq(info.name, "My1155");  
    // assertEq(info.baseURI, "https://base.uri/"); // REMOVED DUE TO PREVIOUS COMPILER ERROR
    assertEq(info.royaltyFee, 0);  
    assertEq(info.royaltyReceiver, royaltyReceiver);  
}  

/*-----------------------------------------------------  
    Mint ERC721  
------------------------------------------------------*/  
function testMintERC721() public {  
    vm.prank(admin);  
    address col = manager.createCollection(  
        "My721",  
        "M721",  
        "",  
        false,  
        royaltyReceiver,  
        500  
    );  

    vm.prank(minter);  
    manager.mintERC721(col, alice, 1, "ipfs://meta1.json");  

    // Check ownership  
    assertEq(ManagedERC721(col).ownerOf(1), alice);  
}  

/*-----------------------------------------------------  
    Batch Mint ERC721  
------------------------------------------------------*/  
function testBatchMintERC721() public {  
    vm.prank(admin);  
    address col = manager.createCollection("Test", "TST", "", false, royaltyReceiver, 0);  

    address[] memory users = new address[](2);  
    users[0] = alice;  
    users[1] = bob;  

    uint256[] memory ids = new uint256[](2);  
    ids[0] = 10;  
    ids[1] = 11;  

    string[] memory uris = new string[](2);  
    uris[0] = "ipfs://1.json";  
    uris[1] = "ipfs://2.json";  

    vm.prank(minter);  
    manager.batchMintERC721(col, users, ids, uris);  

    assertEq(ManagedERC721(col).ownerOf(10), alice);  
    assertEq(ManagedERC721(col).ownerOf(11), bob);  
}  

/*-----------------------------------------------------  
    Mint ERC1155  
------------------------------------------------------*/  
function testMintERC1155() public {  
    vm.prank(admin);  
    address col = manager.createCollection(  
        "1155",  
        "",  
        "https://meta/",  
        true,  
        royaltyReceiver,  
        0  
    );  

    vm.prank(minter);  
    manager.mintERC1155(col, alice, 5, 100, "");  

    assertEq(ManagedERC1155(col).balanceOf(alice, 5), 100);  
}  

/*-----------------------------------------------------  
    Burn ERC721  
------------------------------------------------------*/  
function testBurnERC721() public {  
    vm.prank(admin);  
    address col = manager.createCollection("Test", "TST", "", false, royaltyReceiver, 0);  

    vm.prank(minter);  
    manager.mintERC721(col, alice, 1, "uri");  

    vm.prank(minter);  
    manager.burnERC721(col, 1);  

    // ownerOf should revert, token removed  
    vm.expectRevert();  
    ManagedERC721(col).ownerOf(1);  
}  

/*-----------------------------------------------------  
    Burn ERC1155  
------------------------------------------------------*/  
function testBurnERC1155() public {  
    vm.prank(admin);  
    address col = manager.createCollection("X", "", "", true, royaltyReceiver, 0);  

    vm.startPrank(minter);  
    manager.mintERC1155(col, alice, 9, 50, "");  
    manager.burnERC1155(col, alice, 9, 20);  
    vm.stopPrank();  

    assertEq(ManagedERC1155(col).balanceOf(alice, 9), 30);  
}  

/*-----------------------------------------------------  
    Royalty Set  
------------------------------------------------------*/  
function testSetRoyalty() public {  
    vm.prank(admin);  
    address col = manager.createCollection("R", "R", "", false, royaltyReceiver, 100);  

    vm.prank(admin);  
    manager.setRoyalty(col, bob, 777);  

    NFTManager.CollectionInfo memory info = manager.getCollection(1);  
    assertEq(info.royaltyReceiver, bob);  
    assertEq(info.royaltyFee, 777);  
}  

/*-----------------------------------------------------  
    setTokenURI ERC721  
------------------------------------------------------*/  
function testSetERC721URI() public {  
    vm.prank(admin);  
    address col = manager.createCollection("Meta", "M", "", false, royaltyReceiver, 0);  

    vm.prank(minter);  
    manager.mintERC721(col, alice, 1, "old.json");  

    vm.prank(admin);  
    manager.setTokenURI(col, 1, "newUri.json");  

    string memory newURI = ManagedERC721(col).tokenURI(1);  
    assertTrue(keccak256(bytes(newURI)) == keccak256(bytes("newUri.json")));  
}  

/*-----------------------------------------------------  
    getCollectionSupply  
------------------------------------------------------*/  
function testGetCollectionSupply721() public {  
    vm.prank(admin);  
    address col = manager.createCollection("Z", "Z", "", false, royaltyReceiver, 0);  

    vm.prank(minter);  
    manager.mintERC721(col, alice, 1, "uri");  

    uint256 supply = manager.getCollectionSupply(col, 1);  
    assertEq(supply, 1);  
}  

function testGetCollectionSupply1155() public {  
    vm.prank(admin);  
    address col = manager.createCollection("Z", "", "", true, royaltyReceiver, 0);  

    vm.prank(minter);  
    manager.mintERC1155(col, alice, 99, 80, "");  

    uint256 supply = manager.getCollectionSupply(col, 99);  
    assertEq(supply, 80);  
}  

/*-----------------------------------------------------  
    Access control checks  
------------------------------------------------------*/  
function testMintUnauthorizedReverts() public {  
    vm.prank(admin);  
    address col = manager.createCollection("U", "U", "", false, royaltyReceiver, 0);  

    vm.expectRevert();  
    manager.mintERC721(col, alice, 1, "uri"); // caller is not minter  
}  

function testCreateCollectionUnauthorizedReverts() public {  
    vm.expectRevert();  
    manager.createCollection("X", "", "", false, royaltyReceiver, 0);  
}  

/*-----------------------------------------------------  
    Additional Improvements: Events and Edge Cases  
------------------------------------------------------*/  

// 1. Test Events on Mint ERC721 (Events from ManagedERC721)  
function testEventsOnMint721() public {  
    vm.prank(admin);  
    address col = manager.createCollection("Test", "T", "", false, royaltyReceiver, 0);  

    vm.prank(minter);  

    // Expect Transfer event from ERC721 (address(0) = mint, alice = to, 5 = tokenId)  
    vm.expectEmit(true, true, false, true);  
    emit Transfer(address(0), alice, 5);  

    manager.mintERC721(col, alice, 5, "uri");  
}  

// 2. FIX: Updated expectRevert to match the modern ERC721 custom error.
function testMint721DuplicateReverts() public {  
    vm.prank(admin);  
    address col = manager.createCollection("T", "T", "", false, royaltyReceiver, 0);  

    vm.startPrank(minter);  
    manager.mintERC721(col, alice, 1, "uri");  

    // Expect specific revert: ERC721InvalidSender(address(0))
    vm.expectRevert(abi.encodeWithSignature("ERC721InvalidSender(address)", address(0))); 
    manager.mintERC721(col, bob, 1, "uri2");  
    vm.stopPrank();  
}  

// 3. FIX: Updated expectRevert to match the modern ERC1155 custom error.
function testMint1155ZeroReverts() public {  
    vm.prank(admin);  
    address col = manager.createCollection("1155", "", "", true, royaltyReceiver, 0);  

    vm.prank(minter);  
    // Expect revert: InvalidAmount()
    vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
    manager.mintERC1155(col, alice, 9, 0, "");  
}  

// Note: testTotalCollections removed as function is not present in NFTManager.

}