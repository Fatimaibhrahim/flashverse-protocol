// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/VestingSchedule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MOCK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract VestingScheduleTest is Test {
    MockERC20 token;
    VestingSchedule vesting;

    address owner;
    address alice;
    address bob;

    function setUp() public {
        owner = address(this);
        alice = address(0x1);
        bob   = address(0x2);

        token = new MockERC20();
        vesting = new VestingSchedule(IERC20(token));

        token.approve(address(vesting), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE VESTING
    //////////////////////////////////////////////////////////////*/

    function testCreateVesting() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(
            alice,
            10_000 ether,
            start,
            30 days,
            180 days
        );

        (
            uint256 total,
            uint256 claimed,
            uint64 vStart,
            uint64 cliff,
            uint64 duration,
            bool exists
        ) = vesting.getVestingDetails(alice);

        assertTrue(exists);
        assertEq(total, 10_000 ether);
        assertEq(claimed, 0);
        assertEq(vStart, start);
        assertEq(cliff, 30 days);
        assertEq(duration, 180 days);
    }

    function testCreateVestingFailsIfExists() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(alice, 1_000 ether, start, 0, 100 days);

        vm.expectRevert("Already exists");
        vesting.createVesting(alice, 1_000 ether, start, 0, 100 days);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM LOGIC
    //////////////////////////////////////////////////////////////*/

    function testClaimAfterCliff() public {
        uint64 start = uint64(block.timestamp + 1 days);
        uint256 total = 10_000 ether; // Local variable to force runtime calculation
        uint64 duration = 180 days;
        uint64 timePassed = 60 days;

        vesting.createVesting(
            alice,
            total,
            start,
            30 days,
            duration
        );

        vm.warp(start + timePassed);

        vm.prank(alice);
        vesting.claim();

        uint256 balance = token.balanceOf(alice);
        
        // FIX: Using local variables to perform division at runtime, 
        // avoiding the 'rational_const' compile error.
        uint256 expected = (total * timePassed) / duration; 
        assertEq(balance, expected);
    }

    function testClaimBeforeCliffReverts() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(
            alice,
            10_000 ether,
            start,
            30 days,
            180 days
        );

        vm.warp(start + 10 days);

        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        vesting.claim();
    }

    function testClaimFullyVested() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(
            alice,
            10_000 ether,
            start,
            0,
            90 days
        );

        vm.warp(start + 100 days);

        vm.prank(alice);
        vesting.claim();

        assertEq(token.balanceOf(alice), 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE & REVOKE
    //////////////////////////////////////////////////////////////*/

    function testUpdateTotalIncrease() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(alice, 5_000 ether, start, 0, 100 days);
        vm.prank(owner);
        vesting.updateTotal(alice, 8_000 ether);

        (uint256 total,,,,,) = vesting.getVestingDetails(alice);
        assertEq(total, 8_000 ether);
    }

    function testUpdateTotalDecrease() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(alice, 5_000 ether, start, 0, 100 days);
        vm.prank(owner);
        vesting.updateTotal(alice, 3_000 ether);

        (uint256 total,,,,,) = vesting.getVestingDetails(alice);
        assertEq(total, 3_000 ether);
    }

    function testRevokeVesting() public {
        uint64 start = uint64(block.timestamp + 1 days);

        vesting.createVesting(alice, 10_000 ether, start, 0, 100 days);
        vm.warp(start + 50 days);

        vm.prank(owner);
        vesting.revoke(alice);

        (, , , , , bool exists) = vesting.getVestingDetails(alice);
        assertFalse(exists);
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH CREATE
    //////////////////////////////////////////////////////////////*/

    function testBatchCreateVesting() public {
        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = alice;
        beneficiaries[1] = bob;

        uint256[] memory totals = new uint256[](2);
        totals[0] = 1_000 ether;
        totals[1] = 2_000 ether;

        uint64[] memory starts = new uint64[](2);
        starts[0] = uint64(block.timestamp + 1 days);
        starts[1] = uint64(block.timestamp + 1 days);

        uint64[] memory cliffs = new uint64[](2);
        cliffs[0] = 0;
        cliffs[1] = 0;

        uint64[] memory durations = new uint64[](2);
        durations[0] = 90 days;
        durations[1] = 180 days;

        vesting.batchCreateVesting(
            beneficiaries,
            totals,
            starts,
            cliffs,
            durations
        );

        (, , , , , bool aliceExists) = vesting.getVestingDetails(alice);
        (, , , , , bool bobExists)   = vesting.getVestingDetails(bob);

        assertTrue(aliceExists);
        assertTrue(bobExists);
    }

    /*//////////////////////////////////////////////////////////////
                            SECURITY
    //////////////////////////////////////////////////////////////*/

    function testOnlyOwnerCanCreate() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        vesting.createVesting(alice, 1_000 ether, uint64(block.timestamp + 1), 0, 100 days);
    }

    function testEmergencyWithdraw() public {
        token.transfer(address(vesting), 1_000 ether);
        uint256 contractBalanceBefore = token.balanceOf(address(vesting));
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vesting.emergencyWithdraw(1_000 ether);

        uint256 ownerBalanceAfter = token.balanceOf(owner);
        uint256 contractBalanceAfter = token.balanceOf(address(vesting));

        assertEq(ownerBalanceAfter, ownerBalanceBefore + 1_000 ether);
        assertEq(contractBalanceAfter, contractBalanceBefore - 1_000 ether);
    }
}