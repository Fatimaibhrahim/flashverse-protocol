// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse – FlashVerseToken Foundry Tests
//
//  Run all:    forge test --match-contract FlashVerseTokenTest -vv
//  Run fuzz:   forge test --match-test testFuzz -vv
// ============================================================

import "forge-std/Test.sol";
import "../src/FlashVerseToken.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

// ── Mock Flash Borrower ───────────────────────────────────────────────────────
contract MockFlashBorrower is IERC3156FlashBorrower {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bool public shouldFail;

    constructor(bool _shouldFail) { shouldFail = _shouldFail; }

    function onFlashLoan(
        address,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        if (shouldFail) return bytes32(0);
        // Approve repayment
        IERC20(token).approve(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN TEST CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

contract FlashVerseTokenTest is Test {

    FlashVerseToken public token;

    address owner    = address(this);
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address stranger = makeAddr("stranger");

    uint256 constant TOTAL_SUPPLY  = 18_000_000_000 ether;
    uint256 constant MAX_TX_BPS    = 100; // 1% of supply
    uint256 constant MAX_TX_AMOUNT = (TOTAL_SUPPLY * MAX_TX_BPS) / 10_000;

    function setUp() public {
        token = new FlashVerseToken(
            "Flash Token",
            "FLASH",
            TOTAL_SUPPLY,
            MAX_TX_BPS
        );
    }

    // ─────────────────────────────────────────
    //  1. Deployment
    // ─────────────────────────────────────────
    function test_InitialSupply() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(owner), TOTAL_SUPPLY);
    }

    function test_TokenMetadata() public view {
        assertEq(token.name(),     "Flash Token");
        assertEq(token.symbol(),   "FLASH");
        assertEq(token.decimals(), 18);
    }

    function test_MaxTxAmount() public view {
        assertEq(token.maxTxAmount(), MAX_TX_AMOUNT);
    }

    function test_OwnerIsExemptByDefault() public view {
        assertTrue(token.isExempt(owner));
        assertTrue(token.isExempt(address(token)));
    }

    function test_OwnerIsDeployer() public view {
        assertEq(token.owner(), owner);
    }

    // ─────────────────────────────────────────
    //  2. Anti-Whale
    // ─────────────────────────────────────────
    function test_TransferWithinLimit() public {
        token.transfer(alice, MAX_TX_AMOUNT);
        assertEq(token.balanceOf(alice), MAX_TX_AMOUNT);
    }

    function test_RevertTransferAboveLimit() public {
        uint256 overLimit = MAX_TX_AMOUNT + 1;
        // First give alice enough tokens via exempt owner
        token.transfer(alice, overLimit);

        // Now alice tries to send above limit (alice not exempt)
        vm.prank(alice);
        token.approve(owner, overLimit);

        vm.expectRevert(abi.encodeWithSelector(ExceedsMaxTx.selector, overLimit, MAX_TX_AMOUNT));
        vm.prank(alice);
        token.transfer(bob, overLimit);
    }

    function test_ExemptAddressCanTransferAboveLimit() public {
        uint256 bigAmount = MAX_TX_AMOUNT * 10;
        // Owner is exempt — should work
        token.transfer(alice, bigAmount);
        assertEq(token.balanceOf(alice), bigAmount);
    }

    function test_SetExempt() public {
        token.setExempt(alice, true);
        assertTrue(token.isExempt(alice));

        // Give alice big amount first via exempt owner
        uint256 bigAmount = MAX_TX_AMOUNT * 5;
        token.transfer(alice, bigAmount);

        // Alice (now exempt) can send above limit
        vm.prank(alice);
        token.transfer(bob, bigAmount);
        assertEq(token.balanceOf(bob), bigAmount);
    }

    function test_RemoveExemption() public {
        token.setExempt(alice, true);
        token.setExempt(alice, false);
        assertFalse(token.isExempt(alice));
    }

    function test_BatchSetExempt() public {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = stranger;

        token.batchSetExempt(accounts, true);

        assertTrue(token.isExempt(alice));
        assertTrue(token.isExempt(bob));
        assertTrue(token.isExempt(stranger));
    }

    function test_RevertSetExemptIfNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.setExempt(alice, true);
    }

    function test_SetMaxTxAmount() public {
        uint256 newMax = MAX_TX_AMOUNT * 2;
        token.setMaxTxAmount(newMax);
        assertEq(token.maxTxAmount(), newMax);
    }

    function test_RevertSetMaxTxBelowFloor() public {
        vm.expectRevert();
        token.setMaxTxAmount(0);
    }

    function test_RevertSetExemptZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        token.setExempt(address(0), true);
    }

    // ─────────────────────────────────────────
    //  3. Vesting
    // ─────────────────────────────────────────
    function test_SetVesting() public {
        uint256 amount   = 1_000_000 ether;
        uint256 start    = block.timestamp;
        uint256 cliff    = 30 days;
        uint256 duration = 180 days;

        token.setVesting(alice, amount, start, cliff, duration);

        (uint256 total, uint256 claimed, uint256 s, uint256 c, uint256 d) = token.vestings(alice);
        assertEq(total,   amount);
        assertEq(claimed, 0);
        assertEq(s,       start);
        assertEq(c,       cliff);
        assertEq(d,       duration);
        assertEq(token.balanceOf(address(token)), amount);
    }

    function test_ClaimVestedAfterFullDuration() public {
        uint256 amount   = 1_000_000 ether;
        uint256 start    = block.timestamp;
        uint256 cliff    = 0;
        uint256 duration = 180 days;

        token.setVesting(alice, amount, start, cliff, duration);

        // Advance past duration
        vm.warp(block.timestamp + 180 days + 1);

        vm.prank(alice);
        token.claimVested();

        assertEq(token.balanceOf(alice), amount);
    }

    function test_ClaimVestedLinearlyAfterCliff() public {
        uint256 amount   = 1_000_000 ether;
        uint256 start    = block.timestamp;
        uint256 cliff    = 30 days;
        uint256 duration = 180 days;

        token.setVesting(alice, amount, start, cliff, duration);

        // Advance to halfway through vesting period after cliff
        vm.warp(block.timestamp + 30 days + 75 days); // cliff + half of remaining

        uint256 vested = token.vestedAmount(alice);
        assertGt(vested, 0);
        assertLt(vested, amount);

        vm.prank(alice);
        token.claimVested();
        assertGt(token.balanceOf(alice), 0);
    }

    function test_RevertClaimBeforeCliff() public {
        uint256 amount = 1_000_000 ether;
        token.setVesting(alice, amount, block.timestamp, 30 days, 180 days);

        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        token.claimVested();
    }

    function test_RevertClaimIfNoVesting() public {
        vm.prank(alice);
        vm.expectRevert(NoVesting.selector);
        token.claimVested();
    }

    function test_RemoveVesting() public {
        uint256 amount = 1_000_000 ether;
        token.setVesting(alice, amount, block.timestamp, 0, 180 days);

        uint256 ownerBefore = token.balanceOf(owner);
        token.removeVesting(alice);

        assertEq(token.balanceOf(owner), ownerBefore + amount);
        (uint256 total,,,,) = token.vestings(alice);
        assertEq(total, 0);
    }

    function test_RevertRemoveVestingIfNone() public {
        vm.expectRevert(NoVesting.selector);
        token.removeVesting(alice);
    }

    function test_ClaimableAmountView() public {
        uint256 amount = 1_000_000 ether;
        token.setVesting(alice, amount, block.timestamp, 0, 180 days);

        assertEq(token.claimableAmount(alice), 0); // nothing yet

        vm.warp(block.timestamp + 180 days + 1);
        assertEq(token.claimableAmount(alice), amount);
    }

    function test_RevertVestingCliffExceedsDuration() public {
        vm.expectRevert(CliffExceedsDuration.selector);
        token.setVesting(alice, 1_000 ether, block.timestamp, 200 days, 100 days);
    }

    function test_RevertVestingZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        token.setVesting(address(0), 1_000 ether, block.timestamp, 0, 180 days);
    }

    // ─────────────────────────────────────────
    //  4. Flash Loans
    // ─────────────────────────────────────────
    function _fundTokenContract(uint256 amount) internal {
        // Transfer tokens to contract for flash loan pool
        token.transfer(address(token), amount);
    }

    function test_FlashLoan() public {
        uint256 loanAmount = 1_000_000 ether;
        _fundTokenContract(loanAmount * 2);

        MockFlashBorrower borrower = new MockFlashBorrower(false);
        // Fund borrower with fee
        uint256 fee = (loanAmount * token.flashLoanFeeBP()) / 10_000;
        token.transfer(address(borrower), fee);

        token.flashLoan(borrower, address(token), loanAmount, "");
    }

    function test_RevertFlashLoanCallbackFailed() public {
        uint256 loanAmount = 1_000_000 ether;
        _fundTokenContract(loanAmount * 2);

        MockFlashBorrower badBorrower = new MockFlashBorrower(true);

        vm.expectRevert(CallbackFailed.selector);
        token.flashLoan(badBorrower, address(token), loanAmount, "");
    }

    function test_RevertFlashLoanUnsupportedToken() public {
        MockFlashBorrower borrower = new MockFlashBorrower(false);
        vm.expectRevert(abi.encodeWithSelector(UnsupportedToken.selector, alice));
        token.flashLoan(borrower, alice, 1_000 ether, "");
    }

    function test_RevertFlashLoanInsufficientPool() public {
        MockFlashBorrower borrower = new MockFlashBorrower(false);
        vm.expectRevert();
        token.flashLoan(borrower, address(token), 1_000_000 ether, "");
    }

    function test_MaxFlashLoan() public {
        uint256 amount = 1_000_000 ether;
        _fundTokenContract(amount);
        assertEq(token.maxFlashLoan(address(token)), amount);
        assertEq(token.maxFlashLoan(alice), 0);
    }

    function test_FlashFee() public view {
        uint256 amount = 1_000_000 ether;
        uint256 fee    = token.flashFee(address(token), amount);
        assertEq(fee, (amount * 5) / 10_000);
    }

    function test_RevertFlashFeeUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(UnsupportedToken.selector, alice));
        token.flashFee(alice, 1_000 ether);
    }

    function test_SetFlashLoanFee() public {
        token.setFlashLoanFee(50); // 0.5%
        assertEq(token.flashLoanFeeBP(), 50);
    }

    function test_RevertFlashLoanFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FlashLoanFeeTooHigh.selector, 101, 100));
        token.setFlashLoanFee(101);
    }

    // ─────────────────────────────────────────
    //  5. Burn
    // ─────────────────────────────────────────
    function test_Burn() public {
        uint256 burnAmount = 1_000_000 ether;
        token.burn(burnAmount);
        assertEq(token.totalSupply(), TOTAL_SUPPLY - burnAmount);
    }

    function test_BurnFrom() public {
        uint256 burnAmount = 1_000_000 ether;
        token.transfer(alice, burnAmount);
        vm.prank(alice);
        token.approve(owner, burnAmount);
        token.burnFrom(alice, burnAmount);
        assertEq(token.balanceOf(alice), 0);
    }

    // ─────────────────────────────────────────
    //  6. Recover
    // ─────────────────────────────────────────
    function test_RecoverERC20() public {
        // Deploy a random token and send to FLASH contract
        FlashVerseToken random = new FlashVerseToken("R", "R", 1_000 ether, 10_000);
        random.transfer(address(token), 500 ether);
        token.recoverERC20(address(random), 500 ether, alice);
        assertEq(random.balanceOf(alice), 500 ether);
    }

    function test_RevertRecoverSelf() public {
        vm.expectRevert(CannotRecoverSelf.selector);
        token.recoverERC20(address(token), 100, alice);
    }

    function test_RecoverETH() public {
        vm.deal(address(token), 1 ether);
        uint256 before = alice.balance;
        token.recoverETH(1 ether, alice);
        assertEq(alice.balance, before + 1 ether);
    }

    function test_RevertRecoverETHZeroAddress() public {
        vm.deal(address(token), 1 ether);
        vm.expectRevert(ZeroAddress.selector);
        token.recoverETH(1 ether, address(0));
    }

    // ─────────────────────────────────────────
    //  7. Ownable2Step
    // ─────────────────────────────────────────
    function test_TransferOwnership2Step() public {
        token.transferOwnership(alice);
        // Ownership not transferred yet
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), alice);

        // Alice accepts
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(), alice);
    }

    function test_RevertAcceptOwnershipIfNotPending() public {
        token.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert();
        token.acceptOwnership();
    }

    // ─────────────────────────────────────────
    //  8. ERC20Votes
    // ─────────────────────────────────────────
    function test_Delegate() public {
        token.transfer(alice, 1_000 ether);
        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 1_000 ether);
    }

    // ─────────────────────────────────────────
    //  9. Fuzz Tests
    // ─────────────────────────────────────────
    function testFuzz_TransferWithinLimit(uint256 amount) public {
        amount = bound(amount, 1, MAX_TX_AMOUNT);
        token.transfer(alice, amount * 2); // owner is exempt
        vm.prank(alice);
        // alice not exempt, so transfer must be within limit
        token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_VestingLinear(uint256 elapsed) public {
        uint256 amount   = 1_000_000 ether;
        uint256 duration = 180 days;
        elapsed = bound(elapsed, duration, duration * 2);

        token.setVesting(alice, amount, block.timestamp, 0, duration);
        vm.warp(block.timestamp + elapsed);

        uint256 vested = token.vestedAmount(alice);
        assertEq(vested, amount); // fully vested after duration
    }

    function testFuzz_FlashLoanFee(uint256 amount) public {
        amount = bound(amount, 1 ether, 1_000_000 ether);
        uint256 fee = token.flashFee(address(token), amount);
        assertEq(fee, (amount * token.flashLoanFeeBP()) / 10_000);
    }
}