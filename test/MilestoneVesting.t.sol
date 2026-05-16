// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse – MilestoneVesting Foundry Tests
//
//  Run all:        forge test --match-contract MilestoneVestingTest -vv
//  Run one test:   forge test --match-test test_ClaimAfterOneMilestone -vv
//  Run fuzz:       forge test --match-test testFuzz -vv
// ============================================================

import "forge-std/Test.sol";
import "../src/MilestoneVesting.sol";
import "../src/mocks/MockERC20.sol";

contract MilestoneVestingTest is Test {

    MilestoneVesting public mv;
    MockERC20        public token;

    address owner    = address(this);
    address alice    = makeAddr("alice");    // team member 1
    address bob      = makeAddr("bob");      // team member 2
    address charlie  = makeAddr("charlie");  // team member 3
    address stranger = makeAddr("stranger"); // unauthorized user

    uint256 constant SUPPLY      = 100_000_000 ether;
    uint256 constant TOTAL       = 4_000_000 ether;   // per beneficiary
    uint256 constant PER_MILESTONE = TOTAL / 4;        // 25% = 1M per milestone

    // ─────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────
    function setUp() public {
        token = new MockERC20("Flash Token", "FLASH", SUPPLY);
        mv    = new MilestoneVesting(IERC20(address(token)));
        token.approve(address(mv), SUPPLY);
    }

    // ─────────────────────────────────────────
    //  1. Deployment
    // ─────────────────────────────────────────
    function test_OwnerIsDeployer() public view {
        assertEq(mv.owner(), owner);
    }

    function test_TokenAddressSet() public view {
        assertEq(address(mv.token()), address(token));
    }

    function test_CurrentMilestoneStartsAtZero() public view {
        assertEq(mv.currentMilestone(), 0);
    }

    function test_FourMilestonesInitialized() public view {
        (string memory name0,,,,) = mv.getMilestone(0);
        (string memory name1,,,,) = mv.getMilestone(1);
        (string memory name2,,,,) = mv.getMilestone(2);
        (string memory name3,,,,) = mv.getMilestone(3);

        assertEq(name0, "Testnet Launch");
        assertEq(name1, "Mainnet Launch");
        assertEq(name2, "Advanced Features");
        assertEq(name3, "Mass Adoption");
    }

    function test_MilestoneZeroHasDeadline() public view {
        (,,,,uint256 deadline) = mv.getMilestone(0);
        assertGt(deadline, block.timestamp);
    }

    // ─────────────────────────────────────────
    //  2. addBeneficiary
    // ─────────────────────────────────────────
    function test_AddBeneficiary() public {
        mv.addBeneficiary(alice, TOTAL);
        (uint256 total,,, bool exists, bool revoked) = mv.getBeneficiary(alice);
        assertEq(total, TOTAL);
        assertTrue(exists);
        assertFalse(revoked);
    }

    function test_AddBeneficiaryTransfersTokens() public {
        uint256 before = token.balanceOf(address(mv));
        mv.addBeneficiary(alice, TOTAL);
        assertEq(token.balanceOf(address(mv)), before + TOTAL);
    }

    function test_RevertAddBeneficiaryZeroAddress() public {
        vm.expectRevert("Invalid address");
        mv.addBeneficiary(address(0), TOTAL);
    }

    function test_RevertAddBeneficiaryZeroAmount() public {
        vm.expectRevert("Zero amount");
        mv.addBeneficiary(alice, 0);
    }

    function test_RevertAddBeneficiaryTwice() public {
        mv.addBeneficiary(alice, TOTAL);
        vm.expectRevert("Already exists");
        mv.addBeneficiary(alice, TOTAL);
    }

    function test_RevertAddBeneficiaryIfNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        mv.addBeneficiary(alice, TOTAL);
    }

    function test_AddBeneficiaryEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit MilestoneVesting.BeneficiaryAdded(alice, TOTAL);
        mv.addBeneficiary(alice, TOTAL);
    }

    // ─────────────────────────────────────────
    //  3. batchAddBeneficiaries
    // ─────────────────────────────────────────
    function test_BatchAddBeneficiaries() public {
        address[] memory addrs   = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        addrs[0] = alice;   amounts[0] = TOTAL;
        addrs[1] = bob;     amounts[1] = TOTAL;
        addrs[2] = charlie; amounts[2] = TOTAL;

        mv.batchAddBeneficiaries(addrs, amounts);
        assertEq(mv.totalBeneficiaries(), 3);
    }

    function test_BatchAddTransfersCorrectTotal() public {
        address[] memory addrs   = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        addrs[0] = alice; amounts[0] = TOTAL;
        addrs[1] = bob;   amounts[1] = TOTAL * 2;

        uint256 before = token.balanceOf(address(mv));
        mv.batchAddBeneficiaries(addrs, amounts);
        assertEq(token.balanceOf(address(mv)), before + TOTAL + TOTAL * 2);
    }

    function test_RevertBatchIfLengthMismatch() public {
        address[] memory addrs   = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        addrs[0] = alice; addrs[1] = bob;
        amounts[0] = TOTAL;

        vm.expectRevert("Length mismatch");
        mv.batchAddBeneficiaries(addrs, amounts);
    }

    function test_RevertBatchIfNonOwner() public {
        address[] memory addrs   = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        addrs[0] = alice; amounts[0] = TOTAL;

        vm.prank(stranger);
        vm.expectRevert();
        mv.batchAddBeneficiaries(addrs, amounts);
    }

    // ─────────────────────────────────────────
    //  4. approveMilestone
    // ─────────────────────────────────────────
    function test_ApproveMilestoneZero() public {
        mv.approveMilestone(0);
        (,, bool approved,,) = mv.getMilestone(0);
        assertTrue(approved);
        assertEq(mv.currentMilestone(), 1);
    }

    function test_ApproveSetsNextMilestoneDeadline() public {
        mv.approveMilestone(0);
        (,,,, uint256 deadline1) = mv.getMilestone(1);
        assertGt(deadline1, block.timestamp);
    }

    function test_ApproveAllFourMilestones() public {
        mv.approveMilestone(0);
        mv.approveMilestone(1);
        mv.approveMilestone(2);
        mv.approveMilestone(3);
        assertEq(mv.currentMilestone(), 4);
    }

    function test_RevertApproveMilestoneOutOfOrder() public {
        vm.expectRevert("Must approve in order");
        mv.approveMilestone(1);
    }

    function test_RevertApproveSameMilestoneTwice() public {
        mv.approveMilestone(0);
        vm.expectRevert("Already approved");
        mv.approveMilestone(0);
    }

    function test_RevertApproveInvalidIndex() public {
        vm.expectRevert("Invalid milestone");
        mv.approveMilestone(4);
    }

    function test_RevertApproveIfNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        mv.approveMilestone(0);
    }

    function test_ApproveEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit MilestoneVesting.MilestoneApproved(0, "Testnet Launch", block.timestamp);
        mv.approveMilestone(0);
    }

    // ─────────────────────────────────────────
    //  5. claim
    // ─────────────────────────────────────────
    function test_ClaimAfterOneMilestone() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);

        vm.prank(alice);
        mv.claim();

        assertEq(token.balanceOf(alice), PER_MILESTONE);
    }

    function test_ClaimAfterTwoMilestones() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);
        mv.approveMilestone(1);

        vm.prank(alice);
        mv.claim();

        assertEq(token.balanceOf(alice), PER_MILESTONE * 2);
    }

    function test_ClaimIncrementallyPerMilestone() public {
        mv.addBeneficiary(alice, TOTAL);

        mv.approveMilestone(0);
        vm.prank(alice); mv.claim();
        assertEq(token.balanceOf(alice), PER_MILESTONE);

        mv.approveMilestone(1);
        vm.prank(alice); mv.claim();
        assertEq(token.balanceOf(alice), PER_MILESTONE * 2);

        mv.approveMilestone(2);
        vm.prank(alice); mv.claim();
        assertEq(token.balanceOf(alice), PER_MILESTONE * 3);

        mv.approveMilestone(3);
        vm.prank(alice); mv.claim();
        assertEq(token.balanceOf(alice), TOTAL);
    }

    function test_ClaimAllAtOnceAfterAllMilestones() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);
        mv.approveMilestone(1);
        mv.approveMilestone(2);
        mv.approveMilestone(3);

        vm.prank(alice);
        mv.claim();

        assertEq(token.balanceOf(alice), TOTAL);
    }

    function test_MultipleBeneficiariesClaimCorrectly() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.addBeneficiary(bob,   TOTAL * 2);

        mv.approveMilestone(0);

        vm.prank(alice); mv.claim();
        vm.prank(bob);   mv.claim();

        assertEq(token.balanceOf(alice), PER_MILESTONE);
        assertEq(token.balanceOf(bob),   PER_MILESTONE * 2);
    }

    function test_RevertClaimIfNothingToClaim() public {
        mv.addBeneficiary(alice, TOTAL);
        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        mv.claim();
    }

    function test_RevertDoubleClaim() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);

        vm.prank(alice); mv.claim();

        vm.prank(alice);
        vm.expectRevert("Nothing to claim");
        mv.claim();
    }

    function test_RevertClaimIfNotBeneficiary() public {
        vm.prank(stranger);
        vm.expectRevert("Not a beneficiary");
        mv.claim();
    }

    function test_ClaimEmitsTokensReleasedEvent() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);

        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit MilestoneVesting.TokensReleased(alice, 1, PER_MILESTONE);
        mv.claim();
    }

    // ─────────────────────────────────────────
    //  6. revokeBeneficiary
    // ─────────────────────────────────────────
    function test_RevokeReturnsAllTokensToOwner() public {
        mv.addBeneficiary(alice, TOTAL);
        uint256 before = token.balanceOf(owner);
        mv.revokeBeneficiary(alice);
        assertEq(token.balanceOf(owner), before + TOTAL);
    }

    function test_RevokeAfterPartialClaimReturnsRemainder() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);

        vm.prank(alice); mv.claim(); // claimed 25%

        uint256 before = token.balanceOf(owner);
        mv.revokeBeneficiary(alice);
        // Owner gets back 75%
        assertEq(token.balanceOf(owner), before + (TOTAL - PER_MILESTONE));
    }

    function test_RevokedBeneficiaryCannotClaim() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);
        mv.revokeBeneficiary(alice);

        vm.prank(alice);
        vm.expectRevert("Revoked");
        mv.claim();
    }

    function test_RevertRevokeIfNotBeneficiary() public {
        vm.expectRevert("Not a beneficiary");
        mv.revokeBeneficiary(bob);
    }

    function test_RevertRevokeIfAlreadyRevoked() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.revokeBeneficiary(alice);
        vm.expectRevert("Already revoked");
        mv.revokeBeneficiary(alice);
    }

    function test_RevertRevokeIfNonOwner() public {
        mv.addBeneficiary(alice, TOTAL);
        vm.prank(stranger);
        vm.expectRevert();
        mv.revokeBeneficiary(alice);
    }

    function test_RevokeEmitsEvent() public {
        mv.addBeneficiary(alice, TOTAL);
        vm.expectEmit(true, false, false, true);
        emit MilestoneVesting.BeneficiaryRevoked(alice, TOTAL);
        mv.revokeBeneficiary(alice);
    }

    // ─────────────────────────────────────────
    //  7. claimableAmount
    // ─────────────────────────────────────────
    function test_ClaimableZeroIfNoMilestone() public {
        mv.addBeneficiary(alice, TOTAL);
        assertEq(mv.claimableAmount(alice), 0);
    }

    function test_ClaimableAfterOneMilestone() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);
        assertEq(mv.claimableAmount(alice), PER_MILESTONE);
    }

    function test_ClaimableZeroAfterClaim() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);
        vm.prank(alice); mv.claim();
        assertEq(mv.claimableAmount(alice), 0);
    }

    function test_ClaimableZeroForUnknownAddress() public view {
        assertEq(mv.claimableAmount(charlie), 0);
    }

    function test_ClaimableZeroIfRevoked() public {
        mv.addBeneficiary(alice, TOTAL);
        mv.approveMilestone(0);
        mv.revokeBeneficiary(alice);
        assertEq(mv.claimableAmount(alice), 0);
    }

    // ─────────────────────────────────────────
    //  8. cancelMilestone
    // ─────────────────────────────────────────
    function test_CancelExpiredMilestone() public {
        mv.addBeneficiary(alice, TOTAL);

        // Fast forward 366 days (past 12 month deadline)
        vm.warp(block.timestamp + 366 days);
        vm.expectEmit(true, false, false, false);
        emit MilestoneVesting.MilestoneCancelled(0, "Deadline passed, milestone not achieved");
        mv.cancelMilestone(0, "Deadline passed, milestone not achieved");

    }

    function test_RevertCancelIfDeadlineNotPassed() public {
        mv.addBeneficiary(alice, TOTAL);
        vm.expectRevert("Deadline not passed");
        mv.cancelMilestone(0, "Too early");
    }

    function test_RevertCancelIfAlreadyApproved() public {
        mv.approveMilestone(0);
        vm.warp(block.timestamp + 366 days);
        vm.expectRevert("Already approved");
        mv.cancelMilestone(0, "Already approved");
    }

    // ─────────────────────────────────────────
    //  9. Fuzz Tests
    // ─────────────────────────────────────────
    function testFuzz_ClaimableAmountMatchesExpected(uint256 amount) public {
        amount = bound(amount, 4, 10_000_000 ether);
        mv.addBeneficiary(alice, amount);
        mv.approveMilestone(0);
        uint256 expected = (amount * 2500) / 10_000;
        assertEq(mv.claimableAmount(alice), expected);
    }

    function testFuzz_TotalClaimedEqualsTotal(uint256 amount) public {
        amount = bound(amount, 4, 10_000_000 ether);
        mv.addBeneficiary(alice, amount);

        mv.approveMilestone(0);
        mv.approveMilestone(1);
        mv.approveMilestone(2);
        mv.approveMilestone(3);

        vm.prank(alice);
        mv.claim();

        // After all milestones, full amount should be claimed
        (,uint256 claimed,,,) = mv.getBeneficiary(alice);
        assertEq(claimed, amount - (amount % 4)); // account for rounding
    }
}