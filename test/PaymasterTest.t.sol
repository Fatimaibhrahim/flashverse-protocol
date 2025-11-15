// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Paymaster.sol";
import "../src/mocks/MockERC20.sol";

contract PaymasterTest is Test {
    Paymaster paymaster;
    MockERC20 token;

    address deployer;  
    address alice;  
    address bob;  
    address sponsor; 
    address attacker;  

    uint256 constant ONE_ETH = 1 ether;  
    uint256 constant TEN_ETH = 10 ether;  
    uint256 constant FEE_RATE = 1; // 1% fee

    // FIX: Allows the test contract (deployer) to receive ETH, solving TransferFailed()
    receive() external payable {}

    function setUp() public {  
        deployer = address(this);  
        
        alice = makeAddr("alice");  
        bob = makeAddr("bob");  
        sponsor = makeAddr("sponsor");  
        attacker = makeAddr("attacker");  

        token = new MockERC20("StakeToken", "STK", 18);  
        token.mint(sponsor, 1000 ether);  
        token.mint(alice, 1000 ether);  

        paymaster = new Paymaster();  
        bytes32 SPONSOR_ROLE = keccak256("SPONSOR_ROLE");  
        vm.prank(deployer);  
        paymaster.grantRole(SPONSOR_ROLE, sponsor);  

        // FIX: Advance time to bypass potential cooldown
        vm.warp(block.timestamp + 10 hours); 
    }  

    /* -------------------------  
       deposit ETH & sponsor ETH  
    ------------------------- */  
    function testDepositAndSponsorEth() public {  
        vm.deal(address(this), TEN_ETH);  
        (bool ok,) = address(paymaster).call{value: 5 ether}("");  
        require(ok, "fund failed");  

        uint256 aliceBefore = alice.balance;  
        uint256 paymasterBalanceBefore = address(paymaster).balance; 

        vm.prank(sponsor);  
        paymaster.sponsorEth(alice, 1 ether);  

        uint256 expectedFee = (1 ether * FEE_RATE) / 100; // 0.01 ether
        uint256 expectedNet = 1 ether - expectedFee;      // 0.99 ether

        assertEq(paymaster.totalSponsoredEth(), expectedNet);  
        assertEq(paymaster.totalFeesEth(), expectedFee);  
        
        // FIX: Assert against the net amount (0.99 ether) instead of the gross (1 ether)
        assertEq(paymasterBalanceBefore - address(paymaster).balance, expectedNet, "Paymaster balance decreased by the Net amount (0.99 ether)");  
        
        assertEq(alice.balance - aliceBefore, expectedNet);  
    }  

    function testSponsorEthRevertsWhenInsufficientBalance() public {  
        uint256 bal = address(paymaster).balance;  
        assertEq(bal, 0);  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.sponsorEth(alice, 1 ether);  
    }  

    function testSponsorEthRevertsWithZeroAddress() public {  
        vm.deal(address(this), 2 ether);  
        (bool ok,) = address(paymaster).call{value: 2 ether}("");  
        require(ok);  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.sponsorEth(address(0), 1 ether);  
    }  

    function testSponsorEthRevertsWithZeroAmount() public {  
        vm.deal(address(this), 2 ether);  
        (bool ok,) = address(paymaster).call{value: 2 ether}("");  
        require(ok);  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.sponsorEth(alice, 0);  
    }  

    /* -------------------------  
       cooldown enforcement  
    ------------------------- */  
    function testCooldownEnforced() public {  
        vm.deal(address(this), 3 ether);  
        (bool ok,) = address(paymaster).call{value: 3 ether}("");  
        require(ok);  

        vm.prank(sponsor);  
        paymaster.sponsorEth(alice, 1 ether);  

        vm.prank(sponsor);  
        vm.expectRevert(); // CooldownActive expected here
        paymaster.sponsorEth(bob, 1 ether);  

        vm.warp(block.timestamp + 1 hours + 1);  
        vm.prank(sponsor);  
        paymaster.sponsorEth(bob, 1 ether);  
    }  

    /* -------------------------  
       batch sponsor ETH (happy + failures)  
    ------------------------- */  
    function testBatchSponsorEthSucceeds() public {  
        vm.deal(address(this), 5 ether);  
        (bool ok,) = address(paymaster).call{value: 3 ether}("");  
        require(ok);  

        address[] memory users = new address[](2);  
        users[0] = alice;  
        users[1] = bob;  
        uint256[] memory amounts = new uint256[](2);  
        amounts[0] = 1 ether;  
        amounts[1] = 1 ether;  

        vm.prank(sponsor);  
        paymaster.batchSponsorEth(users, amounts);  

        assertEq(paymaster.totalFeesEth(), (1 ether * FEE_RATE / 100) * 2);  
    }  

    function testBatchSponsorEthEmptyRevertsWithBatchTooLarge() public {  
        address[] memory users = new address[](0);  
        uint256[] memory amounts = new uint256[](0);  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.batchSponsorEth(users, amounts);  
    }  

    function testBatchSponsorEthRevertsWithZeroValues() public {  
        vm.deal(address(this), 3 ether);  
        (bool ok,) = address(paymaster).call{value: 3 ether}("");  
        require(ok);  

        address[] memory users = new address[](1);  
        users[0] = address(0);  
        uint256[] memory amounts = new uint256[](1);  
        amounts[0] = 0;  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.batchSponsorEth(users, amounts);  
    }  

    /* -------------------------  
       ERC20 sponsor flows  
    ------------------------- */  
    function testDepositAndSponsorERC20() public {  
        vm.prank(sponsor);  
        token.approve(address(paymaster), 100 ether);  
        vm.prank(sponsor);  
        paymaster.depositERC20(address(token), 100 ether);  

        vm.prank(sponsor);  
        paymaster.sponsorERC20(address(token), alice, 10 ether);  

        uint256 fee = (10 ether * FEE_RATE) / 100;  
        uint256 net = 10 ether - fee;  
        assertEq(paymaster.totalSponsoredERC20(address(token)), net);  
        assertEq(paymaster.totalFeesERC20(address(token)), fee);  
    }  

    function testSponsorERC20InsufficientBalance() public {  
        assertEq(token.balanceOf(address(paymaster)), 0);  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.sponsorERC20(address(token), alice, 5 ether);  
    }  

    function testBatchSponsorERC20EmptyReverts() public {  
        address[] memory users = new address[](0);  
        uint256[] memory amounts = new uint256[](0);  

        vm.prank(sponsor);  
        vm.expectRevert(); 
        paymaster.batchSponsorERC20(address(token), users, amounts);  
    }  

    /* -------------------------  
       role checks / Unauthorized  
    ------------------------- */  
    function testOnlySponsorRoleRevertsForUnauthorized() public {  
        vm.prank(attacker);  
        vm.expectRevert();
        paymaster.sponsorEth(alice, 1 ether);  
    }  

    /* -------------------------  
       withdraw fees (admin) & emergency withdraw  
    ------------------------- */  
    function testWithdrawFeesEthByAdmin() public {  
        vm.deal(address(this), 5 ether);  
        (bool ok,) = address(paymaster).call{value: 1 ether}("");  
        require(ok);  

        vm.prank(sponsor);  
        paymaster.sponsorEth(alice, 1 ether);  

        uint256 fees = paymaster.totalFeesEth();  
        assertTrue(fees > 0);  

        uint256 before = deployer.balance;  
        paymaster.withdrawFeesEth(payable(deployer), fees);  
        
        assertEq(paymaster.totalFeesEth(), 0);  
        assertEq(deployer.balance - before, fees);  
    }  

    function testWithdrawFeesERC20ByAdmin() public {
        vm.prank(sponsor);
        token.approve(address(paymaster), 100 ether);
        vm.prank(sponsor);
        paymaster.depositERC20(address(token), 100 ether);
        
        vm.prank(sponsor);
        paymaster.sponsorERC20(address(token), alice, 10 ether); 

        uint256 fees = paymaster.totalFeesERC20(address(token));
        assertTrue(fees > 0, "Fees should be > 0");
        
        uint256 before = token.balanceOf(deployer);
        paymaster.withdrawFeesERC20(address(token), deployer, fees);
        
        assertEq(paymaster.totalFeesERC20(address(token)), 0, "Fees balance must be zero after withdrawal");
        assertEq(token.balanceOf(deployer) - before, fees, "Deployer should receive the exact fee amount");
    }

    function testWithdrawFeesEthRevertsForNonAdmin() public {  
        vm.deal(address(this), 1 ether);  
        (bool ok,) = address(paymaster).call{value: 1 ether}("");  
        require(ok);  

        vm.prank(sponsor);  
        paymaster.sponsorEth(alice, 1 ether);  

        vm.prank(attacker);  
        vm.expectRevert(); 
        paymaster.withdrawFeesEth(payable(attacker), 1);  
    }  

    function testEmergencyWithdrawERC20ByAdmin() public {  
        vm.prank(sponsor);  
        token.approve(address(paymaster), 200 ether);  
        vm.prank(sponsor);  
        paymaster.depositERC20(address(token), 200 ether);  

        paymaster.emergencyWithdraw(address(token), bob, 100 ether);  
        assertEq(token.balanceOf(bob), 100 ether);  
    }  

    function testEmergencyWithdrawEthByAdmin() public {  
        vm.deal(address(this), 5 ether);  
        (bool ok,) = address(paymaster).call{value: 5 ether}("");  
        require(ok);  

        uint256 before = bob.balance;  
        paymaster.emergencyWithdraw(address(0), bob, 1 ether);  
        assertEq(bob.balance - before, 1 ether);  
    }  

    function testEmergencyWithdrawRevertsForNonAdmin() public {  
        vm.deal(address(this), 5 ether);  
        (bool ok,) = address(paymaster).call{value: 5 ether}("");  
        require(ok);  

        vm.prank(attacker);  
        vm.expectRevert(); 
        paymaster.emergencyWithdraw(address(0), attacker, 1 ether);  
    }  

    /* -------------------------  
       events coverage (simple)  
    ------------------------- */  
    function testEthSponsoredEventEmitted() public {  
        vm.deal(address(this), 2 ether);  
        (bool ok,) = address(paymaster).call{value: 2 ether}("");  
        require(ok);  

        uint256 amount = 1 ether;
        uint256 fee = (amount * FEE_RATE) / 100;
        uint256 net = amount - fee;

        vm.prank(sponsor);  
        vm.expectEmit(true, true, true, true);  
        emit Paymaster.EthSponsored(sponsor, alice, net, fee);  
        paymaster.sponsorEth(alice, amount);  
    }  

    /* -------------------------  
       fuzz tests (optional for extra strength)  
    ------------------------- */  
    function testFuzzSponsorEth(uint256 amount) public {  
        vm.assume(amount > 1 ether && amount < 100 ether);  

        vm.deal(address(this), amount);  
        (bool ok,) = address(paymaster).call{value: amount}("");  
        require(ok);  

        vm.prank(sponsor);  
        paymaster.sponsorEth(alice, amount / 2);  

        assertGt(paymaster.totalSponsoredEth(), 0);  
    }
}