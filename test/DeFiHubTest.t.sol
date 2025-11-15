// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/DeFiHub.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

// --- MOCK CONTRACTS ---

contract MockERC20Test {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _supply) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = _supply;
        balanceOf[msg.sender] = _supply;
        emit Transfer(address(0), msg.sender, _supply);
    }
    
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Allowance exceeded");
            unchecked {
                allowance[from][msg.sender] -= amount;
            }
        }
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockDEXAdapter {
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256)
    {
        require(amountIn > 0, "Invalid amount");
        MockERC20Test(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        uint256 amountOut = (amountIn * 90) / 100; 
        
        require(amountOut >= minAmountOut, "Slippage too high");
        MockERC20Test(tokenOut).transfer(to, amountOut);
        
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
        return amountOut;
    }
}

contract MockLendingAdapter {
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => mapping(address => uint256)) public borrows;

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    event Repaid(address indexed user, address indexed token, uint256 amount);

    function deposit(address token, uint256 amount) external {
        require(amount > 0, "Invalid amount");
        MockERC20Test(token).transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount, address to) external {
        require(deposits[msg.sender][token] >= amount, "Insufficient deposit");
        deposits[msg.sender][token] -= amount;
        MockERC20Test(token).transfer(to, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    function borrow(address token, uint256 amount, address to) external {
        require(amount > 0, "Invalid amount");
        borrows[msg.sender][token] += amount;
        MockERC20Test(token).transfer(to, amount);
        emit Borrowed(msg.sender, token, amount);
    }

    function repay(address token, uint256 amount) external {
        require(borrows[msg.sender][token] >= amount, "Nothing to repay");
        require(amount > 0, "Invalid amount");
        MockERC20Test(token).transferFrom(msg.sender, address(this), amount);
        borrows[msg.sender][token] -= amount;
        emit Repaid(msg.sender, token, amount);
    }
}

// --- TEST SUITE ---

contract DeFiHubTest is Test {
    DeFiHub hub;
    MockERC20Test stakingToken;
    MockERC20Test rewardToken;
    MockERC20Test otherToken;
    MockDEXAdapter dex;
    MockLendingAdapter lending;

    address admin;
    address user1;
    address user2;
    uint256 public constant INITIAL_SUPPLY = 1e24;

    function setUp() public {
        admin = vm.addr(1);
        user1 = vm.addr(2);
        user2 = vm.addr(3);

        vm.prank(admin);
        stakingToken = new MockERC20Test("Staking Token", "STK", 18, INITIAL_SUPPLY);
        rewardToken = new MockERC20Test("Reward Token", "RWD", 18, INITIAL_SUPPLY);
        otherToken = new MockERC20Test("Other Token", "OTH", 18, INITIAL_SUPPLY);
        
        dex = new MockDEXAdapter();
        lending = new MockLendingAdapter();

        vm.prank(admin);
        hub = new DeFiHub(address(stakingToken), address(rewardToken), 1e18);

        vm.startPrank(admin);
        hub.setAdapters(address(dex), address(lending));
        vm.stopPrank();

        vm.startPrank(address(hub));
        stakingToken.approve(address(dex), type(uint256).max);
        rewardToken.approve(address(dex), type(uint256).max);
        otherToken.approve(address(dex), type(uint256).max);
        
        stakingToken.approve(address(lending), type(uint256).max);
        rewardToken.approve(address(lending), type(uint256).max);
        otherToken.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        stakingToken.mint(user1, 1e20);
        stakingToken.mint(user2, 1e20);
        otherToken.mint(user1, 1e20);
        
        rewardToken.transfer(address(hub), type(uint256).max);

        rewardToken.transfer(address(dex), 1e20);
        otherToken.transfer(address(lending), 1e20);
    }

    /*-----------------------------------------------------
        Staking tests
    ------------------------------------------------------*/
    function testStakeAndUnstake() public {
        uint256 stakeAmount = 1000 * 1e18;
        vm.startPrank(user1);
        stakingToken.approve(address(hub), stakeAmount);
        
        vm.expectEmit(true, true, true, true, address(stakingToken));
        emit MockERC20Test.Transfer(user1, address(hub), stakeAmount);
        
        hub.stake(stakeAmount);
        
        vm.warp(block.timestamp + 3600);
        
        uint256 expectedRewards = hub.calculateRewards(user1);
        
        vm.expectEmit(true, true, true, true, address(rewardToken));
        emit MockERC20Test.Transfer(address(hub), user1, expectedRewards);
        
        vm.expectEmit(true, true, true, true, address(stakingToken));
        emit MockERC20Test.Transfer(address(hub), user1, stakeAmount);
        
        hub.unstake(); 
        
        DeFiHub.StakeInfo memory info = hub.getStake(user1); 
        assertEq(info.amount, 0);
        assertEq(info.rewardsClaimed, expectedRewards, "Rewards claimed must match expected");
        vm.stopPrank();
    }

    function testClaimRewards() public {
        uint256 stakeAmount = 1000 * 1e18;
        vm.startPrank(user1);
        stakingToken.approve(address(hub), stakeAmount);
        hub.stake(stakeAmount);
        
        vm.warp(block.timestamp + 3600);
        
        uint256 expectedRewards = hub.calculateRewards(user1);
        
        vm.expectEmit(true, true, true, true, address(rewardToken));
        emit MockERC20Test.Transfer(address(hub), user1, expectedRewards);
        
        hub.claimRewards();
        
        DeFiHub.StakeInfo memory info = hub.getStake(user1);
        assertEq(info.rewardsClaimed, expectedRewards, "Rewards claimed must be updated after claim");
        vm.stopPrank();
    }
    
    function testUnstakeWithLargeRewards() public {
        uint256 stakeAmount = 1000 * 1e18;
        vm.startPrank(user1);
        stakingToken.approve(address(hub), stakeAmount);
        hub.stake(stakeAmount);
        
        uint256 longTime = 1000 * 24 * 3600; 
        vm.warp(block.timestamp + longTime);
        
        uint256 expectedRewards = hub.calculateRewards(user1);
        
        vm.expectEmit(true, true, true, true, address(rewardToken));
        emit MockERC20Test.Transfer(address(hub), user1, expectedRewards);
        
        vm.expectEmit(true, true, true, true, address(stakingToken));
        emit MockERC20Test.Transfer(address(hub), user1, stakeAmount);
        
        hub.unstake(); 
        
        DeFiHub.StakeInfo memory info = hub.getStake(user1);
        assertEq(info.amount, 0);
        assertGt(info.rewardsClaimed, 0, "Rewards must be greater than zero");
        vm.stopPrank();
    }

    /*-----------------------------------------------------
        Swap tests
    ------------------------------------------------------*/
    function testSwap() public {
        uint256 amountIn = 1000 * 1e18;
        uint256 expectedAmountOut = (amountIn * 90) / 100;

        vm.startPrank(user1);
        otherToken.approve(address(hub), amountIn);
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(user1, address(hub), amountIn);
        
        vm.expectEmit(true, true, true, true, address(otherToken)); 
        emit MockERC20Test.Transfer(address(hub), address(dex), amountIn);

        vm.expectEmit(true, true, false, true, address(dex));
        emit MockDEXAdapter.SwapExecuted(address(otherToken), address(rewardToken), amountIn, expectedAmountOut);
        
        vm.expectEmit(true, true, true, true, address(rewardToken)); 
        emit MockERC20Test.Transfer(address(dex), user1, expectedAmountOut);
        
        uint256 outAmount = hub.swapTokens(address(otherToken), address(rewardToken), amountIn, expectedAmountOut);
        
        assertEq(outAmount, expectedAmountOut);
        vm.stopPrank();
    }

    function testSwapWithSlippageReverts() public {
        uint256 amountIn = 1000 * 1e18;
        uint256 minAmountOut = (amountIn * 95) / 100; 
        
        vm.startPrank(user1);
        otherToken.approve(address(hub), amountIn); 
        
        vm.expectRevert("Slippage too high"); 
        hub.swapTokens(address(otherToken), address(rewardToken), amountIn, minAmountOut);
        vm.stopPrank();
    }

    /*-----------------------------------------------------
        Lending tests
    ------------------------------------------------------*/
    function testDepositToLending() public {
        uint256 depositAmount = 500 * 1e18;
        vm.startPrank(user1);
        otherToken.approve(address(hub), depositAmount);
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(user1, address(hub), depositAmount);
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(address(hub), address(lending), depositAmount);
        
        vm.expectEmit(true, true, false, true, address(lending));
        emit MockLendingAdapter.Deposited(address(hub), address(otherToken), depositAmount); 
        
        hub.depositToLending(address(otherToken), depositAmount);
        vm.stopPrank();
    }

    function testWithdrawFromLending() public {
        uint256 amount = 500 * 1e18;
        vm.startPrank(user1);
        otherToken.approve(address(hub), amount);
        hub.depositToLending(address(otherToken), amount);
        
        vm.expectEmit(true, true, false, true, address(lending));
        emit MockLendingAdapter.Withdrawn(address(hub), address(otherToken), amount); 
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(address(lending), user1, amount);

        hub.withdrawFromLending(address(otherToken), amount); 
        vm.stopPrank();
    }

    function testBorrowAndRepay() public {
        uint256 amount = 200 * 1e18;
        vm.startPrank(user1);
        
        vm.expectEmit(true, true, false, true, address(lending));
        emit MockLendingAdapter.Borrowed(address(hub), address(otherToken), amount);
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(address(lending), user1, amount);
        
        hub.borrowFromLending(address(otherToken), amount); 
        
        otherToken.approve(address(hub), amount);
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(user1, address(hub), amount);
        
        vm.expectEmit(true, true, true, true, address(otherToken));
        emit MockERC20Test.Transfer(address(hub), address(lending), amount);
        
        vm.expectEmit(true, true, false, true, address(lending));
        emit MockLendingAdapter.Repaid(address(hub), address(otherToken), amount);
        
        hub.repayToLending(address(otherToken), amount);
        vm.stopPrank();
    }
    
    /*-----------------------------------------------------
        Admin revert tests 
    ------------------------------------------------------*/
    function testSetAdaptersUnauthorized() public {
        vm.prank(user1);
        
        vm.expectRevert(abi.encodeWithSelector(
            AccessControlUnauthorizedAccount.selector, 
            user1,  
            hub.ADMIN_ROLE()
        ));
        
        hub.setAdapters(address(dex), address(lending));
    }
}