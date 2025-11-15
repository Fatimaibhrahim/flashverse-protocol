// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FlashIDRegistry.sol";

contract FlashIDRegistryTest is Test {
    FlashIDRegistry registry;

    address admin = address(1);
    address user1 = address(2);
    address user2 = address(3);
    address attacker = address(99);

    string constant USERNAME1 = "fatima";
    string constant USERNAME2 = "queenfatima";
    string constant DISPLAY_NAME1 = "Fatima"; 
    string constant DISPLAY_NAME2 = "QueenFatima"; 

    event IDRegistered(address indexed user, string id, bytes32 indexed idHash);
    event IDUpdated(address indexed user, string oldId, string newId, bytes32 indexed oldHash, bytes32 indexed newHash);
    event IDRevoked(address indexed user, string id, bytes32 indexed idHash);

    function _computeIdHash(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes(id)));
    }

    function setUp() public {
        registry = new FlashIDRegistry(admin); 
    }

    /* ========================================================================================
                            REGISTER TESTS
    ======================================================================================== */

    function testRegisterSuccess() public {
        bytes32 expectedHash = _computeIdHash(USERNAME1); 
        
        vm.expectEmit(true, true, true, true);
        emit IDRegistered(user1, USERNAME1, expectedHash); 

        vm.prank(user1);
        registry.registerId(DISPLAY_NAME1);

        assertEq(registry.getId(user1), USERNAME1); 
        assertEq(registry.resolveAddress(DISPLAY_NAME1), user1);
        assertTrue(registry.isRegistered(user1));
    }

    function testRegisterRejectsEmptyUsername() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(InvalidLength.selector, uint256(0)));
        registry.registerId("");
    }

    function testRegisterFailsIfUserAlreadyRegistered() public {
        vm.startPrank(user1);
        registry.registerId(DISPLAY_NAME1);

        vm.expectRevert(abi.encodeWithSelector(AlreadyRegistered.selector, user1));
        registry.registerId("SomethingElse");

        vm.stopPrank();
    }

    function testRegisterRejectsLongUsername() public {
        string memory longUsername = new string(33); 
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(InvalidLength.selector, uint256(33)));
        registry.registerId(longUsername);
    }

    function testRegisterFailsIfUsernameTaken() public {
        vm.startPrank(user1);
        registry.registerId(DISPLAY_NAME1);
        vm.stopPrank();

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IDTaken.selector, USERNAME1)); 
        registry.registerId(DISPLAY_NAME1);
    }

    /* ========================================================================================
                                UPDATE ID
    ======================================================================================== */

    function testUpdateIdSuccess() public {
        vm.startPrank(user1);
        registry.registerId(DISPLAY_NAME1);
        
        bytes32 oldHash = registry.idHashOf(user1);
        bytes32 newHash = _computeIdHash(USERNAME2);

        vm.expectEmit(true, true, true, true);
        emit IDUpdated(user1, USERNAME1, USERNAME2, oldHash, newHash); 

        registry.updateId(DISPLAY_NAME2); 

        assertEq(registry.getId(user1), USERNAME2);
        assertEq(registry.resolveAddress(USERNAME1), address(0)); 
        assertEq(registry.resolveAddress(USERNAME2), user1); 

        vm.stopPrank();
    }

    function testUpdateIdFailsIfUserNotRegistered() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotRegistered.selector, user1));
        registry.updateId(DISPLAY_NAME2);
    }

    function testUpdateIdFailsIfNewUsernameTaken() public {
        vm.prank(user1);
        registry.registerId(DISPLAY_NAME1);

        vm.prank(user2);
        registry.registerId(DISPLAY_NAME2); 

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IDTaken.selector, USERNAME2));
        registry.updateId(DISPLAY_NAME2);
    }

    /* ========================================================================================
                                REVOKE ID
    ======================================================================================== */

    function testRevokeIdSuccess() public {
        vm.startPrank(user1);
        registry.registerId(DISPLAY_NAME1);
        
        bytes32 idHash = registry.idHashOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IDRevoked(user1, USERNAME1, idHash);

        registry.revokeId();

        assertEq(registry.getId(user1), "");
        assertEq(registry.resolveAddress(USERNAME1), address(0));

        vm.stopPrank();
    }

    function testRevokeIdFailsIfUserNotRegistered() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotRegistered.selector, user1));
        registry.revokeId();
    }

    /* ========================================================================================
                                 VIEW FUNCTIONS
    ======================================================================================== */

    function testGetIdSuccess() public {
        vm.prank(user1);
        registry.registerId(DISPLAY_NAME1);

        assertEq(registry.getId(user1), USERNAME1);
    }

    function testGetIdEmptyForUnregistered() public {
        assertEq(registry.getId(user1), "");
    }

    function testIsRegistered() public {
        // التصحيح: استبدال assertFalse() بـ assertTrue مع عامل النفي !
        assertTrue(!registry.isRegistered(user1)); 

        vm.prank(user1);
        registry.registerId(DISPLAY_NAME1);

        assertTrue(registry.isRegistered(user1)); 
    }

    function testResolveAddressSuccess() public {
        vm.prank(user1);
        registry.registerId(DISPLAY_NAME1);

        assertEq(registry.resolveAddress(DISPLAY_NAME1), user1);
        assertEq(registry.resolveAddress(USERNAME1), user1); 
    }
}