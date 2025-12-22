// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FlashVerseToken.sol";
import "./helpers/FlashBorrower.sol";
import "./helpers/ReentrantBorrower.sol";
import "./helpers/MaliciousBorrower.sol"; // Added MaliciousBorrower import

/**
 * @title FlashVerseToken Test Suite
 * @notice Comprehensive test suite for FlashVerseToken contract, covering basic functionality,
 * anti-whale mechanisms, vesting, and flash loans. Designed to be clean, organized,
 * and professional, following Solidity best practices.
 * @dev Uses Foundry's Test framework for unit testing. Assumes FlashVerseToken and helper
 * contracts are correctly implemented. Helpers are used for complex interactions like
 * flash loans to ensure test isolation and reusability.
 */
contract FlashVerseTokenTest is Test {
    // Constants for better readability and maintainability
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant MAX_TX_PERCENT = 1000; // 10% in basis points (1000 = 10%)
    uint256 constant MAX_TX_AMOUNT = (INITIAL_SUPPLY * MAX_TX_PERCENT) / 10_000; // Calculated as 100_000 ether

    // Test addresses
    // CORRECTED: Changed from constant to public variable and assigned in setUp
    address public OWNER; 
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    // Contract instance
    FlashVerseToken token;

    /**
     * @notice Setup function to initialize the token and perform initial transfers.
     * @dev Deploys FlashVerseToken with initial supply and max tx limit, then transfers to alice.
     */
    function setUp() public {
        // CORRECTED: Set OWNER address here
        OWNER = address(this);
        
        token = new FlashVerseToken(
            "FlashVerse",
            "FLASH",
            INITIAL_SUPPLY,
            MAX_TX_PERCENT
        );

        // Transfer initial amount to alice for testing
        token.transfer(ALICE, 100_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            BASIC FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that the initial supply is correctly minted to the owner.
     */
    function testInitialSupplyMintedToOwner() public {
        uint256 expectedBalance = INITIAL_SUPPLY - 100_000 ether; // After transfer to alice
        assertEq(token.balanceOf(OWNER), expectedBalance);
    }

    /**
     * @notice Test anti-whale mechanism: transfers exceeding maxTxAmount should revert.
     * @dev Uses prank to simulate transfer from a regular user (alice), not owner.
     */
    function testAntiWhaleLimit() public {
        vm.prank(ALICE);
        vm.expectRevert("Anti-whale: exceeds maxTxAmount");
        token.transfer(BOB, 200_000 ether); // Exceeds 100_000 ether limit
    }

    /**
     * @notice Test that the owner can update the maxTxAmount and perform larger transfers.
     */
    function testOwnerCanUpdateMaxTx() public {
        token.setMaxTxAmount(500_000 ether);
        token.transfer(BOB, 200_000 ether);
        assertEq(token.balanceOf(BOB), 200_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            VESTING TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test the full vesting flow: setup, time passage, and claiming.
     */
    function testVestingFlow() public {
        uint256 start = block.timestamp + 1 days;
        uint256 cliff = 30 days;
        uint256 duration = 180 days;
        uint256 vestedAmount = 10_000 ether;

        // Setup vesting for alice
        token.setVesting(ALICE, vestedAmount, start, cliff, duration);

        // Warp time to after cliff + some days
        vm.warp(start + cliff + 10 days);

        // Claim vested tokens
        vm.prank(ALICE);
        token.claimVested();

        // Verify alice's balance increased due to vesting (beyond initial 100_000 ether)
        uint256 claimed = token.balanceOf(ALICE);
        assertGt(claimed, 100_000 ether);
    }

    /**
     * @notice Test claiming before cliff: should not allow claiming.
     * @dev Assumes the contract reverts with "Nothing to claim" if claimable is 0.
     */
    function testVestingClaimBeforeCliff() public {
        uint256 start = block.timestamp + 1 days;
        uint256 cliff = 30 days;
        uint256 duration = 180 days;

        token.setVesting(ALICE, 10_000 ether, start, cliff, duration);

        // Warp to just before cliff
        vm.warp(start + cliff - 1 days);

        vm.prank(ALICE);
        vm.expectRevert("Nothing to claim");
        token.claimVested();
    }

    /**
     * @notice Test removing vesting: should reset vesting data.
     */
    function testRemoveVesting() public {
        token.setVesting(ALICE, 10_000 ether, block.timestamp, 0, 100 days);
        token.removeVesting(ALICE);

        (uint256 total, , , , ) = token.vestings(ALICE);
        assertEq(total, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            FLASH LOAN TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test successful flash loan execution.
     * @dev Assumes FlashBorrower repays the loan amount + fee correctly.
     */
    function testFlashLoanSuccess() public {
        // Note: The FlashBorrower contract uses 'address payable' in its constructor
        FlashBorrower borrower = new FlashBorrower(payable(address(token)));
        uint256 initialBorrowerBalance = 1_000 ether;
        uint256 loanAmount = 10_000 ether;

        // Fund borrower
        token.transfer(address(borrower), initialBorrowerBalance);

        // Execute flash loan
        vm.prank(address(borrower));
        borrower.executeFlashLoan(loanAmount);

        // Verify borrower balance is at least the initial amount (assuming repayment covers loan + fee)
        assertGe(token.balanceOf(address(borrower)), initialBorrowerBalance);
    }

    /**
     * @notice Test that reentrancy attacks on flash loans are blocked.
     * @dev Uses OpenZeppelin's ReentrancyGuard revert message.
     */
    function testFlashLoanReentrancyBlocked() public {
        ReentrantBorrower attacker = new ReentrantBorrower(payable(address(token)));
        uint256 loanAmount = 10_000 ether;

        // Fund attacker
        token.transfer(address(attacker), 1_000 ether);

        // Expect revert due to reentrancy guard
        vm.expectRevert("ReentrancyGuard: reentrant call");
        attacker.attack(loanAmount);
    }

    /**
     * @notice Test flash loan failure due to insufficient repayment.
     * @dev Uses FlashBorrower to simulate failure.
     */
    function testFlashLoanFailure() public {
        FlashBorrower borrower = new FlashBorrower(payable(address(token)));
        token.transfer(address(borrower), 1_000 ether);

        vm.prank(address(borrower));
        // Expect revert because the borrower is designed to fail repayment
        vm.expectRevert(); 
        borrower.executeFlashLoanWithFailure(10_000 ether);
    }

    /**
     * @notice Test flash loan failure due to malicious non-repayment.
     * @dev Uses MaliciousBorrower to simulate malicious failure (incorrect return value/no repayment).
     */
    function testFlashLoanMaliciousFailure() public {
        MaliciousBorrower malicious = new MaliciousBorrower(payable(address(token)));
        token.transfer(address(malicious), 1_000 ether);

        vm.prank(address(malicious));
        // Expect revert because the borrower is designed to fail repayment (using "malicious" flag)
        vm.expectRevert(); 
        malicious.executeMalicious(10_000 ether);
    }
}