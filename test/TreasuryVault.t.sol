// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TreasuryVault.sol";
import "../src/mocks/MockERC20.sol"; 

// The custom errors are imported from TreasuryVault.sol, so they are available directly.

contract TreasuryVaultTest is Test {
    TreasuryVault vault;
    MockERC20 token; 
    MockERC20 usdc;  
    MockERC20 link;  
    address deployer;
    address alice;
    address bob;
    address charlie; 

    uint256 constant INITIAL_FEE_BPS = 10; 
    uint256 constant ONE_ETHER = 1 ether;

    function setUp() public {
        deployer = address(this);
        alice = address(0xA11CE);
        bob = address(0xB0B);
        charlie = address(0xC4A); 

        // Deploy mocks 
        token = new MockERC20("Mock", "MCK", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6); 
        link = new MockERC20("Chainlink", "LINK", 18);

        // Mint 
        token.mint(alice, 10000 ether);
        token.mint(bob, 10000 ether);
        usdc.mint(alice, 10000 * 1e6); 
        usdc.mint(bob, 10000 * 1e6);
        link.mint(alice, 10000 ether);
        link.mint(bob, 10000 ether);

        // Deploy vault
        vault = new TreasuryVault(INITIAL_FEE_BPS);
    }

    /* -------------------------
       ETH deposit & withdraw 
    ------------------------- */
    function testDepositAndWithdrawETH() public {
        vm.deal(address(this), 10 ether);
        (bool sent,) = address(vault).call{value: 5 ether}("");
        require(sent, "fund failed");
        assertEq(address(vault).balance, 5 ether);

        uint256 before = alice.balance;
        vault.withdrawEth(alice, 1 ether);
        uint256 fee = (1 ether * INITIAL_FEE_BPS) / 10000;
        assertEq(alice.balance - before, 1 ether - fee);
        assertEq(vault.getTotalFeesCollected(address(0)), fee);
    }

    /* -------------------------
       ERC20 deposit & withdraw 
    ------------------------- */
    function testDepositAndWithdrawERC20() public {
        vm.prank(alice);
        token.approve(address(vault), 1000 ether);
        vm.prank(alice);
        vault.depositERC20(address(token), 1000 ether);
        assertEq(token.balanceOf(address(vault)), 1000 ether);

        uint256 bobBefore = token.balanceOf(bob);
        vault.withdrawERC20(address(token), bob, 100 ether);
        uint256 fee = (100 ether * INITIAL_FEE_BPS) / 10000;
        uint256 expectedNet = 100 ether - fee;
        assertEq(token.balanceOf(bob) - bobBefore, expectedNet);
        assertEq(vault.getTotalFeesCollected(address(token)), fee);
    }

    function testDepositAndWithdrawUSDC() public {
        uint256 amount = 1000 * 1e6; 
        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        vault.depositERC20(address(usdc), amount);
        assertEq(usdc.balanceOf(address(vault)), amount);

        uint256 bobBefore = usdc.balanceOf(bob);
        vault.withdrawERC20(address(usdc), bob, amount / 10); 
        uint256 fee = ((amount / 10) * INITIAL_FEE_BPS) / 10000;
        uint256 expectedNet = (amount / 10) - fee;
        assertEq(usdc.balanceOf(bob) - bobBefore, expectedNet);
        assertEq(vault.getTotalFeesCollected(address(usdc)), fee);
    }

    /* -------------------------
       Batch withdraw ETH 
    ------------------------- */
    function testBatchWithdrawETH() public {
        vm.deal(address(this), 10 ether);
        (bool s,) = address(vault).call{value: 5 ether}("");
        require(s, "fund failed");

        address[] memory tos = new address[](2);
        tos[0] = alice;
        tos[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        vault.batchWithdrawEth(tos, amounts);
        uint256 expectedFees = (3 ether * INITIAL_FEE_BPS) / 10000;
        assertEq(vault.getTotalFeesCollected(address(0)), expectedFees);
    }

    function testBatchWithdrawERC20() public {
        vm.prank(alice);
        link.approve(address(vault), 1000 ether);
        vm.prank(alice);
        vault.depositERC20(address(link), 1000 ether);

        address[] memory tos = new address[](2);
        tos[0] = bob;
        tos[1] = charlie;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        uint256 bobBefore = link.balanceOf(bob);
        uint256 charlieBefore = link.balanceOf(charlie);

        vault.batchWithdrawERC20(address(link), tos, amounts);

        uint256 expectedFees = (300 ether * INITIAL_FEE_BPS) / 10000;
        assertEq(vault.getTotalFeesCollected(address(link)), expectedFees, "Total fees check failed");

        uint256 bobFee = (amounts[0] * INITIAL_FEE_BPS) / 10000;
        uint256 bobNet = amounts[0] - bobFee;
        assertEq(link.balanceOf(bob) - bobBefore, bobNet, "Bob's net amount check failed");

        uint256 charlieFee = (amounts[1] * INITIAL_FEE_BPS) / 10000;
        uint256 charlieNet = amounts[1] - charlieFee;
        assertEq(link.balanceOf(charlie) - charlieBefore, charlieNet, "Charlie's net amount check failed");
    }

    /* -------------------------
       Pause/unpause + access control 
    ------------------------- */
    function testPauseBlocksActions() public {
        vault.pause();
        vm.deal(address(this), 1 ether);
        // FIX: Removed TreasuryVault. prefix
        vm.expectRevert(Paused.selector); 
        address(vault).call{value: 0.1 ether}("");

        vault.unpause();
        (bool s,) = address(vault).call{value: 0.1 ether}("");
        require(s, "deposit failed");
    }

    /* -------------------------
       Ownership transfer 
    ------------------------- */
    function testOwnershipTransferTwoStep() public {
        vm.prank(deployer);
        vault.transferOwnership(alice);
        vm.prank(alice);
        vault.acceptOwnership();

        vm.prank(deployer);
        // FIX: Removed TreasuryVault. prefix
        vm.expectRevert(Unauthorized.selector);
        vault.setTimelock(100);
    }

    /* -------------------------
       Timelock prevents withdraw 
    ------------------------- */
    function testTimelockPreventsWithdraw() public {
        vm.deal(address(this), 2 ether);
        (bool s,) = address(vault).call{value: 2 ether}("");
        require(s, "fund");

        vault.setTimelock(3600);
        // FIX: Removed TreasuryVault. prefix
        vm.expectRevert(abi.encodeWithSelector(TimelockActive.selector, block.timestamp + 3600));
        vault.withdrawEth(alice, 1 ether);

        vm.warp(block.timestamp + 3600 + 1);
        vault.withdrawEth(alice, 1 ether);
    }

    /* -------------------------
       Fee management 
    ------------------------- */
    function testSetWithdrawalFee() public {
        vault.setWithdrawalFee(50); 
        assertEq(vault.withdrawalFeeBasisPoints(), 50);

        // FIX: Removed TreasuryVault. prefix
        vm.expectRevert(FeeTooHigh.selector);
        vault.setWithdrawalFee(1500); 
    }

    /* -------------------------
       Emergency withdraw 
    ------------------------- */
    function testEmergencyWithdrawETH() public {
        vm.deal(address(vault), 5 ether);
        uint256 before = alice.balance;
        vault.emergencyWithdraw(address(0), alice, 1 ether);
        assertEq(alice.balance - before, 1 ether);
    }

    // FIX: Ensures the vault has tokens and verifies no fees are charged.
    function testEmergencyWithdrawERC20() public {
        uint256 amount = 100e18; 

        // 1. Mint tokens directly to the vault to ensure balance is available
        token.mint(address(vault), amount);

        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(deployer); 
        vault.emergencyWithdraw(address(token), bob, amount);

        // 2. Assert that the full amount is transferred without fees
        assertEq(token.balanceOf(bob), bobBefore + amount, "Recipient must receive full amount (no fees)");

        // 3. Assert the vault balance is zero after withdrawal
        assertEq(token.balanceOf(address(vault)), 0, "Vault balance should be zero");
    }

    /* -------------------------
       Withdraw fees 
    ------------------------- */
    function testWithdrawFees() public {
        vm.deal(address(this), 10 ether);
        (bool s,) = address(vault).call{value: 5 ether}("");
        require(s);
        vault.withdrawEth(alice, 1 ether); 

        uint256 fees = vault.getTotalFeesCollected(address(0));
        vault.withdrawFees(address(0), bob);
        assertEq(bob.balance, fees);
        assertEq(vault.getTotalFeesCollected(address(0)), 0);
    }

    /* -------------------------
       View functions 
    ------------------------- */
    function testViewFunctions() public {
        vm.deal(address(vault), 5 ether);
        assertEq(vault.balanceEth(), 5 ether);
        assertEq(vault.balanceERC20(address(token)), 0);

        (uint256 net, uint256 fee) = vault.calculateNetAmount(100 ether);
        assertEq(fee, (100 ether * INITIAL_FEE_BPS) / 10000);
        assertEq(net, 100 ether - fee);
    }

    /* -------------------------
       Reverts and edge cases 
    ------------------------- */
    function testReverts() public {
        // FIX: Removed TreasuryVault. prefix from all error selectors
        vm.expectRevert(ZeroAddress.selector);
        vault.withdrawEth(address(0), 1 ether);

        vm.expectRevert(InvalidAmount.selector);
        vault.withdrawEth(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(
            InsufficientBalance.selector,
            0, // Balance in vault (0 at this point)
            100 ether // Amount requested
        ));
        vault.withdrawEth(alice, 100 ether); 

        vm.expectRevert(Unauthorized.selector);
        vm.prank(alice);
        vault.withdrawEth(bob, 1 ether);
    }

    /* -------------------------
       Unauthorized access reverts 
    ------------------------- */
    function testUnauthorizedAccessReverts() public {
        // FIX: Removed TreasuryVault. prefix from all error selectors
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        vault.setWithdrawalFee(50);
        
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.pause();
        
        vm.expectRevert(Unauthorized.selector);
        vm.prank(charlie);
        vault.withdrawFees(address(0), charlie);
    }

    /* -------------------------
       Batch withdraw failure on insufficient balance 
    ------------------------- */
    function testBatchWithdrawRevertsOnInsufficientBalance() public {
        // Deposit 10 ether only
        vm.deal(address(this), 10 ether);
        (bool s,) = address(vault).call{value: 10 ether}("");
        require(s);

        address[] memory tos = new address[](2);
        tos[0] = alice;
        tos[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 6 ether; 
        amounts[1] = 5 ether; // Total required: 11 ether

        // FIX: Removed TreasuryVault. prefix
        vm.expectRevert(abi.encodeWithSelector(
            InsufficientBalance.selector, 
            10 ether, // Balance in vault
            11 ether  // Total required
        ));
        vault.batchWithdrawEth(tos, amounts);
    }

    /* -------------------------
       Fuzzing test 
    ------------------------- */
    function testFuzzWithdrawETH(uint256 amount) public {
        vm.assume(amount > 0 && amount < 100 ether); 
        vm.deal(address(vault), amount * 2);
        vault.withdrawEth(alice, amount);
        assertGe(alice.balance, amount - (amount / 100)); 
    }

    /* -------------------------
       Invariant test 
    ------------------------- */
    function testInvariantBalances() public {
        vm.deal(address(this), 5 ether);
        (bool s,) = address(vault).call{value: 5 ether}("");
        require(s, "Deposit failed for invariant test");

        uint256 initialETH = address(vault).balance;
        vault.withdrawEth(alice, 1 ether);
        assertLe(address(vault).balance, initialETH); 
    }

    /* -------------------------
       Gas test 
    ------------------------- */
    function testGasBatchWithdraw() public {
        vm.deal(address(this), 100 ether);
        (bool s,) = address(vault).call{value: 50 ether}("");
        require(s);

        address[] memory tos = new address[](10);
        uint256[] memory amounts = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            tos[i] = alice;
            amounts[i] = 1 ether;
        }
        // Measure gas
        uint256 gasStart = gasleft();
        vault.batchWithdrawEth(tos, amounts);
        uint256 gasUsed = gasStart - gasleft();
        console.log("Gas used for batch withdraw:", gasUsed);
        assertLt(gasUsed, 500000); 
    }

    /* Fallback to receive coverage */
    receive() external payable {}
}