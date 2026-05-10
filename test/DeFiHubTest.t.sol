// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse – DeFiHub v3 Foundry Tests
//
//  Run all:    forge test --match-contract DeFiHubTest -vv
//  Run fuzz:   forge test --match-test testFuzz -vv
// ============================================================

import "forge-std/Test.sol";
import "../src/DeFiHub.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

// ── Mock DEX Adapter ──────────────────────────────────────────────────────────
contract MockDEXAdapter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 98 / 100; // simulate 2% slippage
        require(out >= minOut, "slippage");
        IERC20(tokenOut).transfer(to, out);
        return out;
    }
}

// ── Mock Lending Adapter ──────────────────────────────────────────────────────
contract MockLendingAdapter {
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => mapping(address => uint256)) public borrows;

    function deposit(address token, uint256 amount) external {
        deposits[msg.sender][token] += amount;
    }
    function withdraw(address token, uint256 amount, address to) external {
        deposits[msg.sender][token] -= amount;
        IERC20(token).transfer(to, amount);
    }
    function borrow(address token, uint256 amount, address to) external {
        borrows[msg.sender][token] += amount;
        IERC20(token).transfer(to, amount);
    }
    function repay(address token, uint256 amount) external {
        borrows[msg.sender][token] -= amount;
    }
    function getAccountSnapshot(address account, address token)
        external view returns (uint256, uint256)
    {
        return (deposits[account][token], borrows[account][token]);
    }
}

// ── Mock Oracle ───────────────────────────────────────────────────────────────
contract MockOracle {
    uint256 public price;
    uint8   public decimals;

    constructor(uint256 _price, uint8 _decimals) {
        price    = _price;
        decimals = _decimals;
    }

    function getPrice(address) external view returns (uint256, uint8) {
        return (price, decimals);
    }

    function setPrice(uint256 _price) external { price = _price; }
}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN TEST CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

contract DeFiHubTest is Test {

    DeFiHub          public hub;
    MockERC20        public stakingToken;
    MockERC20        public rewardToken;
    MockERC20        public lendToken;
    MockDEXAdapter   public dexAdapter;
    MockLendingAdapter public lendingAdapter;
    MockOracle       public oracle;

    address owner    = address(this);
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    uint256 constant SUPPLY      = 100_000_000 ether;
    uint256 constant REWARD_RATE = 1e18;
    uint256 constant STAKE_AMT   = 1_000 ether;
    uint256 constant LEND_AMT    = 5_000 ether;

    function setUp() public {
        stakingToken   = new MockERC20("Staking",  "STK",  SUPPLY);
        rewardToken    = new MockERC20("Reward",   "RWD",  SUPPLY);
        lendToken      = new MockERC20("LendToken","LTK",  SUPPLY);
        dexAdapter     = new MockDEXAdapter();
        lendingAdapter = new MockLendingAdapter();
        oracle         = new MockOracle(1e8, 8); // $1 price

        hub = new DeFiHub(
            address(stakingToken),
            address(rewardToken),
            REWARD_RATE,
            treasury
        );

        // Fund hub with rewards
        rewardToken.transfer(address(hub), 10_000_000 ether);

        // Fund alice and bob
        stakingToken.transfer(alice, 100_000 ether);
        stakingToken.transfer(bob,   100_000 ether);
        lendToken.transfer(alice,    100_000 ether);
        lendToken.transfer(bob,      100_000 ether);

        // Fund mock adapters with tokens for swaps/lending
        rewardToken.transfer(address(dexAdapter), 100_000 ether);
        lendToken.transfer(address(lendingAdapter), 100_000 ether);
    }

    // ─────────────────────────────────────────
    //  1. Deployment
    // ─────────────────────────────────────────
    function test_DeploymentState() public view {
        assertEq(address(hub.STAKING_TOKEN()), address(stakingToken));
        assertEq(address(hub.REWARD_TOKEN()),  address(rewardToken));
        assertEq(hub.rewardRate(),   REWARD_RATE);
        assertEq(hub.treasury(),     treasury);
        assertEq(hub.swapFeeBps(),   30);
        assertEq(hub.depositFeeBps(),10);
        assertFalse(hub.phase2Enabled());
        assertFalse(hub.emergencyMode());
    }

    function test_RolesGrantedToDeployer() public view {
        assertTrue(hub.hasRole(hub.ADMIN_ROLE(),     owner));
        assertTrue(hub.hasRole(hub.EMERGENCY_ROLE(), owner));
        assertTrue(hub.hasRole(hub.GUARDIAN_ROLE(),  owner));
        assertTrue(hub.hasRole(hub.LIQUIDATOR_ROLE(),owner));
    }

    function test_RevertETH() public {
        vm.expectRevert(ETHNotAccepted.selector);
        payable(address(hub)).transfer(1 ether);
    }

    // ─────────────────────────────────────────
    //  2. Staking
    // ─────────────────────────────────────────
    function test_Stake() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();

        (uint256 staked,,,) = hub.getUserStakeInfo(alice);
        assertEq(staked,          STAKE_AMT);
        assertEq(hub.totalStaked(), STAKE_AMT);
        assertEq(hub.totalStakersCount(), 1);
    }

    function test_StakeEmitsEvent() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        vm.expectEmit(true, false, false, true);
        emit DeFiHub.Staked(alice, STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();
    }

    function test_RevertStakeBelowMin() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), 100);
        vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector, hub.minStakeAmount(), type(uint256).max));
        hub.stake(100);
        vm.stopPrank();
    }

    function test_RevertStakeZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        hub.stake(0);
    }

    function test_Unstake() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        hub.unstake(STAKE_AMT);
        vm.stopPrank();

        (uint256 staked,,,) = hub.getUserStakeInfo(alice);
        assertEq(staked, 0);
        assertEq(hub.totalStaked(), 0);
        assertEq(hub.totalStakersCount(), 0);
    }

    function test_RevertUnstakeMoreThanStaked() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.expectRevert(abi.encodeWithSelector(InsufficientBalance.selector, STAKE_AMT, STAKE_AMT + 1));
        hub.unstake(STAKE_AMT + 1);
        vm.stopPrank();
    }

    function test_ClaimRewards() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();

        // Advance time 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 pending = hub.pendingRewards(alice);
        assertGt(pending, 0);

        vm.prank(alice);
        hub.claimRewards();

        assertGt(rewardToken.balanceOf(alice), 0);
    }

    function test_RevertClaimIfNoStake() public {
        vm.prank(alice);
        vm.expectRevert(NoStakeFound.selector);
        hub.claimRewards();
    }

    function test_MultipleStakers() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();

        vm.startPrank(bob);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();

        assertEq(hub.totalStakersCount(), 2);
        assertEq(hub.totalStaked(), STAKE_AMT * 2);
    }

    function test_RewardCapRespected() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();

        // Advance 1000 years — should not exceed reward cap
        vm.warp(block.timestamp + 1000 * 365 days);

        uint256 pending = hub.pendingRewards(alice);
        assertLe(pending, hub.TOTAL_REWARD_CAP());
    }

    // ─────────────────────────────────────────
    //  3. Emergency Unstake
    // ─────────────────────────────────────────
    function test_EmergencyUnstake() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.stopPrank();

        hub.toggleEmergencyMode();

        vm.prank(alice);
        hub.emergencyUnstake();

        assertEq(stakingToken.balanceOf(alice), 100_000 ether);
    }

    function test_RevertEmergencyUnstakeIfNotEmergency() public {
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        hub.stake(STAKE_AMT);
        vm.expectRevert(EmergencyModeOff.selector);
        hub.emergencyUnstake();
        vm.stopPrank();
    }

    // ─────────────────────────────────────────
    //  4. Swapping (Phase 1)
    // ─────────────────────────────────────────
    function _setupDex() internal {
        hub.queueAdaptersUpdate(address(dexAdapter), address(0));
        vm.warp(block.timestamp + 2 days + 1);
        hub.executeAdaptersUpdate(address(dexAdapter), address(0));
    }

    function test_SwapTokens() public {
        _setupDex();

        uint256 swapAmt = 1_000 ether;
        uint256 minOut  = 900 ether;

        vm.startPrank(alice);
        stakingToken.approve(address(hub), swapAmt);
        rewardToken.approve(address(hub), swapAmt); // for fee
        hub.swapTokens(address(stakingToken), address(rewardToken), swapAmt, minOut);
        vm.stopPrank();

        assertGt(rewardToken.balanceOf(alice), 0);
    }

    function test_RevertSwapSameToken() public {
        _setupDex();
        vm.prank(alice);
        vm.expectRevert(SameAddress.selector);
        hub.swapTokens(address(stakingToken), address(stakingToken), 100 ether, 0);
    }

    function test_RevertSwapNoAdapter() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AdapterNotWhitelisted.selector, address(0)));
        hub.swapTokens(address(stakingToken), address(rewardToken), 100 ether, 0);
    }

    function test_SwapFeeGoesToTreasury() public {
        _setupDex();
        uint256 swapAmt = 1_000 ether;
        uint256 fee     = (swapAmt * hub.swapFeeBps()) / 10_000;

        vm.startPrank(alice);
        stakingToken.approve(address(hub), swapAmt);
        hub.swapTokens(address(stakingToken), address(rewardToken), swapAmt, 0);
        vm.stopPrank();

        assertEq(stakingToken.balanceOf(treasury), fee);
    }

    // ─────────────────────────────────────────
    //  5. Phase 2 Gate
    // ─────────────────────────────────────────
    function test_RevertLendingIfPhase2Disabled() public {
        vm.prank(alice);
        vm.expectRevert(Phase2NotEnabled.selector);
        hub.depositToLending(address(lendToken), LEND_AMT);
    }

    function test_EnablePhase2() public {
        hub.enablePhase2();
        assertTrue(hub.phase2Enabled());
    }

    function test_RevertEnablePhase2Twice() public {
        hub.enablePhase2();
        vm.expectRevert("DeFiHub: already enabled");
        hub.enablePhase2();
    }

    function test_RevertEnablePhase2IfNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        hub.enablePhase2();
    }

    // ─────────────────────────────────────────
    //  6. Lending (Phase 2)
    // ─────────────────────────────────────────
    function _setupLending() internal {
        hub.enablePhase2();
        hub.queueAdaptersUpdate(address(0), address(lendingAdapter));
        vm.warp(block.timestamp + 2 days + 1);
        hub.executeAdaptersUpdate(address(0), address(lendingAdapter));
        hub.setTokenOracle(address(lendToken), address(oracle), 1 hours);
    }

    function test_DepositToLending() public {
        _setupLending();

        vm.startPrank(alice);
        lendToken.approve(address(hub), LEND_AMT);
        hub.depositToLending(address(lendToken), LEND_AMT);
        vm.stopPrank();

        (uint256 deposited,,bool active) = hub.getLendingPosition(alice, address(lendToken));
        assertGt(deposited, 0);
        assertTrue(active);
    }

    function test_DepositFeeGoesToTreasury() public {
        _setupLending();
        uint256 fee = (LEND_AMT * hub.depositFeeBps()) / 10_000;

        vm.startPrank(alice);
        lendToken.approve(address(hub), LEND_AMT);
        hub.depositToLending(address(lendToken), LEND_AMT);
        vm.stopPrank();

        assertEq(lendToken.balanceOf(treasury), fee);
    }

    function test_WithdrawFromLending() public {
        _setupLending();

        vm.startPrank(alice);
        lendToken.approve(address(hub), LEND_AMT);
        hub.depositToLending(address(lendToken), LEND_AMT);
        (uint256 deposited,,) = hub.getLendingPosition(alice, address(lendToken));
        hub.withdrawFromLending(address(lendToken), deposited);
        vm.stopPrank();

        (uint256 dep,, bool active) = hub.getLendingPosition(alice, address(lendToken));
        assertEq(dep, 0);
        assertFalse(active);
    }

    function test_RevertWithdrawMoreThanDeposited() public {
        _setupLending();

        vm.startPrank(alice);
        lendToken.approve(address(hub), LEND_AMT);
        hub.depositToLending(address(lendToken), LEND_AMT);
        (uint256 deposited,,) = hub.getLendingPosition(alice, address(lendToken));
        vm.expectRevert(abi.encodeWithSelector(InsufficientBalance.selector, deposited, deposited + 1));
        hub.withdrawFromLending(address(lendToken), deposited + 1);
        vm.stopPrank();
    }

    function test_MaxPositionsReached() public {
        _setupLending();

        // Create 10 different tokens and deposit each
        for (uint256 i = 0; i < 10; i++) {
            MockERC20 t = new MockERC20("T", "T", 100_000 ether);
            t.transfer(alice, 10_000 ether);
            MockOracle o = new MockOracle(1e8, 8);
            hub.setTokenOracle(address(t), address(o), 1 hours);

            vm.startPrank(alice);
            t.approve(address(hub), 1_000 ether);
            hub.depositToLending(address(t), 1_000 ether);
            vm.stopPrank();
        }

        // 11th should revert
        MockERC20 extra = new MockERC20("E", "E", 100_000 ether);
        extra.transfer(alice, 10_000 ether);
        hub.setTokenOracle(address(extra), address(oracle), 1 hours);

        vm.startPrank(alice);
        extra.approve(address(hub), 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(MaxPositionsReached.selector, 10));
        hub.depositToLending(address(extra), 1_000 ether);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────
    //  7. Timelock
    // ─────────────────────────────────────────
    function test_TimelockTreasuryUpdate() public {
        address newTreasury = makeAddr("newTreasury");
        hub.queueTreasuryUpdate(newTreasury);

        // Should fail before delay
        vm.expectRevert(NoPendingChange.selector);
        hub.executeTreasuryUpdate(newTreasury);

        // Advance past delay
        vm.warp(block.timestamp + 2 days + 1);
        hub.executeTreasuryUpdate(newTreasury);
        assertEq(hub.treasury(), newTreasury);
    }

    function test_RevertTimelockQueuedTwice() public {
        address newTreasury = makeAddr("newTreasury");
        hub.queueTreasuryUpdate(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(TimelockAlreadyQueued.selector, hub.executeTreasuryUpdate.selector));
        hub.queueTreasuryUpdate(newTreasury);
    }

    function test_CancelTimelock() public {
        address newTreasury = makeAddr("newTreasury");
        hub.queueTreasuryUpdate(newTreasury);
        hub.cancelTimelock(hub.executeTreasuryUpdate.selector);

        // After cancel, should be able to queue again
        hub.queueTreasuryUpdate(newTreasury);
    }

    function test_RevertCancelNonExistentTimelock() public {
        vm.expectRevert(NoPendingChange.selector);
        hub.cancelTimelock(bytes4(0xdeadbeef));
    }

    function test_TimelockAdaptersUpdate() public {
        hub.queueAdaptersUpdate(address(dexAdapter), address(lendingAdapter));
        vm.warp(block.timestamp + 2 days + 1);
        hub.executeAdaptersUpdate(address(dexAdapter), address(lendingAdapter));
        assertEq(hub.dexAdapter(),     address(dexAdapter));
        assertEq(hub.lendingAdapter(), address(lendingAdapter));
        assertTrue(hub.isAdapterWhitelisted(address(dexAdapter)));
        assertTrue(hub.isAdapterWhitelisted(address(lendingAdapter)));
    }

    function test_TimelockRewardRateUpdate() public {
        uint256 newRate = 2e18;
        hub.queueRewardRateUpdate(newRate);
        vm.warp(block.timestamp + 2 days + 1);
        hub.executeRewardRateUpdate(newRate);
        assertEq(hub.rewardRate(), newRate);
    }

    function test_RevertRewardRateAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector, 0, hub.MAX_REWARD_RATE()));
        hub.queueRewardRateUpdate(hub.MAX_REWARD_RATE() + 1);
    }

    // ─────────────────────────────────────────
    //  8. Admin operations
    // ─────────────────────────────────────────
    function test_UpdateFees() public {
        hub.updateFees(50, 20);
        assertEq(hub.swapFeeBps(),    50);
        assertEq(hub.depositFeeBps(), 20);
    }

    function test_RevertFeesAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidFee.selector, 101, 100));
        hub.updateFees(101, 0);
    }

    function test_UpdateMinStakeAmount() public {
        hub.updateMinStakeAmount(1e10);
        assertEq(hub.minStakeAmount(), 1e10);
    }

    function test_RescueTokens() public {
        MockERC20 random = new MockERC20("R", "R", 1_000 ether);
        random.transfer(address(hub), 500 ether);
        hub.rescueTokens(address(random), 500 ether);
        assertEq(random.balanceOf(owner), 500 ether);
    }

    function test_RevertRescueProtectedToken() public {
        vm.expectRevert(abi.encodeWithSelector(ProtectedToken.selector, address(stakingToken)));
        hub.rescueTokens(address(stakingToken), 100);
    }

    // ─────────────────────────────────────────
    //  9. Guardian / Emergency
    // ─────────────────────────────────────────
    function test_GuardianPause() public {
        hub.guardianPause();
        assertTrue(hub.paused());
    }

    function test_GuardianUnpause() public {
        hub.guardianPause();
        hub.guardianUnpause();
        assertFalse(hub.paused());
    }

    function test_RevertUnpauseInEmergency() public {
        hub.toggleEmergencyMode(); // pauses + sets emergency
        vm.expectRevert("DeFiHub: emergency mode active");
        hub.guardianUnpause();
    }

    function test_RevertStakeWhenPaused() public {
        hub.guardianPause();
        vm.startPrank(alice);
        stakingToken.approve(address(hub), STAKE_AMT);
        vm.expectRevert();
        hub.stake(STAKE_AMT);
        vm.stopPrank();
    }

    function test_RevertIfNonGuardianPauses() public {
        vm.prank(stranger);
        vm.expectRevert();
        hub.guardianPause();
    }

    // ─────────────────────────────────────────
    //  10. Fuzz Tests
    // ─────────────────────────────────────────
    function testFuzz_StakeAndUnstake(uint256 amount) public {
        amount = bound(amount, hub.minStakeAmount(), 50_000 ether);
        stakingToken.transfer(alice, amount);

        vm.startPrank(alice);
        stakingToken.approve(address(hub), amount);
        hub.stake(amount);
        (uint256 staked,,,) = hub.getUserStakeInfo(alice);
        assertEq(staked, amount);
        hub.unstake(amount);
        vm.stopPrank();

        (uint256 finalStake,,,) = hub.getUserStakeInfo(alice);
        assertEq(finalStake, 0);
    }

    function testFuzz_SwapFeeCalculation(uint256 amount) public {
        _setupDex();
        amount = bound(amount, 1 ether, 10_000 ether);
        stakingToken.transfer(alice, amount);

        uint256 expectedFee = (amount * hub.swapFeeBps()) / 10_000;

        vm.startPrank(alice);
        stakingToken.approve(address(hub), amount);
        hub.swapTokens(address(stakingToken), address(rewardToken), amount, 0);
        vm.stopPrank();

        assertEq(stakingToken.balanceOf(treasury), expectedFee);
    }
}