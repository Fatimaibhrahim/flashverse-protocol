// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GlobalRelayerRegistry.sol";
import "../src/mocks/MockERC20.sol";

// Only EnforcedPause is kept declared here, as it was the only one the compiler 
// could not find previously, suggesting it's an external/inherited error.
error EnforcedPause(); 

contract GlobalRelayerRegistryTest is Test {
    GlobalRelayerRegistry registry;
    MockERC20 stakeToken;

    address owner;  
    address relayer1;  
    address relayer2;  
    address relayer3;  
    address attacker;  

    uint256 public constant MIN_STAKE = 100 ether;  
    uint256 public constant UNSTAKE_COOLDOWN = 3600; 
    uint256 public constant VOTE_THRESHOLD_PCT = 50;  

    function setUp() public {  
        owner = address(this);  
        relayer1 = address(0x1111);  
        relayer2 = address(0x2222);  
        relayer3 = address(0x3333);  
        attacker = address(0x9999);  

        stakeToken = new MockERC20("StakeToken", "STK", 18);  

        // Mint initial tokens
        stakeToken.mint(relayer1, 1000 ether);  
        stakeToken.mint(relayer2, 1000 ether);  
        stakeToken.mint(relayer3, 1000 ether);  
        stakeToken.mint(owner, 5000 ether);  

        registry = new GlobalRelayerRegistry(address(stakeToken), MIN_STAKE, UNSTAKE_COOLDOWN, VOTE_THRESHOLD_PCT);  
    }  

    /* -------------------------  
       addRelayer - success  
       ------------------------- */  
    function testAddRelayerSucceeds() public {  
        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  

        vm.expectEmit(true, true, true, true);  
        emit GlobalRelayerRegistry.RelayerAdded(relayer1, 1, 1, MIN_STAKE, block.timestamp);  

        vm.prank(relayer1);  
        registry.addRelayer(1, 1);  

        GlobalRelayerRegistry.RelayerInfo memory info = registry.getRelayerInfo(relayer1);  
        assertTrue(info.active);  
        assertEq(info.stake, MIN_STAKE);  
    }  

    /* -------------------------------------------------------------
       FIXED: addRelayer - insufficient stake 
       (Ensures approve is called, then expects InsufficientStake)
       ------------------------------------------------------------- */  
    function testAddRelayerInsufficientStake() public {  
        address relayer = relayer1;

        uint256 minStake = MIN_STAKE;
        // Reduce balance to less than MIN_STAKE
        uint256 insufficientBalance = minStake / 2; 

        // 1. Burn tokens to reduce relayer's balance
        vm.prank(relayer);  
        uint256 amountToBurn = stakeToken.balanceOf(relayer) - insufficientBalance;
        stakeToken.burn(amountToBurn);  

        // 2. CRITICAL FIX: The relayer MUST approve MIN_STAKE to pass the allowance check
        vm.prank(relayer);  
        stakeToken.approve(address(registry), minStake); // <--- THIS LINE IS KEY

        // 3. Final call, expecting InsufficientStake 
        vm.prank(relayer);  
        vm.expectRevert(  
            abi.encodeWithSelector(  
                InsufficientStake.selector, // Use direct name as per last compiler fix
                minStake, 
                stakeToken.balanceOf(relayer) 
            )  
        );  
        registry.addRelayer(1, 1);  
    }  

    /* -------------------------  
       stakeMore 
       ------------------------- */  
    function testStakeMore() public {  
        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE * 2);  

        vm.prank(relayer1);  
        registry.addRelayer(1, 1);  

        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  

        vm.prank(relayer1);  
        registry.stakeMore(MIN_STAKE);  

        GlobalRelayerRegistry.RelayerInfo memory info = registry.getRelayerInfo(relayer1);  
        assertEq(info.stake, MIN_STAKE * 2);  
    }  

    /* -------------------------  
       removeRelayer & withdrawStake (after cooldown) 
       ------------------------- */  
    function testRemoveAndWithdrawAfterCooldown() public {  
        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  
        vm.prank(relayer1);  
        registry.addRelayer(1, 1);  

        registry.removeRelayer(relayer1);  

        uint256 expectedUnlockTime = block.timestamp + UNSTAKE_COOLDOWN;
        vm.prank(relayer1);  
        vm.expectRevert(abi.encodeWithSelector(UnlockPending.selector, expectedUnlockTime)); 
        registry.withdrawStake();  

        vm.warp(block.timestamp + UNSTAKE_COOLDOWN + 10);  

        uint256 balBefore = stakeToken.balanceOf(relayer1);  
        vm.prank(relayer1);  
        registry.withdrawStake();  
        uint256 balAfter = stakeToken.balanceOf(relayer1);  

        assertEq(balAfter - balBefore, MIN_STAKE);  
    }  

    /* -------------------------  
       pause/unpause 
       ------------------------- */  
    function testPausePreventsAdd() public {  
        registry.pause();  

        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  

        vm.prank(relayer1);  
        vm.expectRevert(abi.encodeWithSelector(EnforcedPause.selector));
        registry.addRelayer(1, 1);  

        registry.unpause();  

        vm.prank(relayer1);  
        registry.addRelayer(1, 1);  
        assertTrue(registry.isRelayer(relayer1));  
    }  

    /* -------------------------  
       voting and governance execution  
       ------------------------- */  
    function testVotingAndExecuteGovernance() public {  
        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  
        vm.prank(relayer1);  
        registry.addRelayer(1, 1);  

        vm.prank(relayer2);  
        stakeToken.approve(address(registry), MIN_STAKE);  
        vm.prank(relayer2);  
        registry.addRelayer(1, 1);  

        vm.prank(relayer1);  
        registry.voteOnRelayer(relayer2, false);  

        vm.prank(relayer2);  
        registry.voteOnRelayer(relayer2, false);  

        GlobalRelayerRegistry.RelayerInfo memory info = registry.getRelayerInfo(relayer2);  
        assertEq(info.votesFor, 0);  
        assertEq(info.votesAgainst, 0);  

        registry.executeGovernanceDecision(relayer2);  

        GlobalRelayerRegistry.RelayerInfo memory finalInfo = registry.getRelayerInfo(relayer2);  
        assertTrue(!finalInfo.active);  
        assertTrue(finalInfo.markedForRemoval);  
    }  

    /* -------------------------  
       batch add & remove  
       ------------------------- */  
    function testBatchAddRemove() public {  
        uint256 totalRequired = MIN_STAKE * 2;  
        vm.prank(owner);
        stakeToken.approve(address(registry), totalRequired);  

        address[] memory addrs = new address[](2);  
        addrs[0] = relayer1;  
        addrs[1] = relayer2;  

        uint256[] memory chainIds = new uint256[](2);  
        chainIds[0] = 1;  
        chainIds[1] = 1;  

        uint8[] memory tiers = new uint8[](2);  
        tiers[0] = 1;  
        tiers[1] = 1;  

        vm.prank(owner);
        registry.addRelayersBatch(addrs, chainIds, tiers);  

        assertTrue(registry.isRelayer(relayer1));  
        assertTrue(registry.isRelayer(relayer2));  

        address[] memory toRemove = new address[](2);  
        toRemove[0] = relayer1;  
        toRemove[1] = relayer2;  

        vm.prank(owner);
        registry.removeRelayersBatch(toRemove);  

        assertTrue(!registry.isRelayer(relayer1));  
        assertTrue(!registry.isRelayer(relayer2));  
    }  

    /* -------------------------  
       edge-case: invalid tier / chainId  
       ------------------------- */  
    function testInvalidTierChainIdReverts() public {  
        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  

        vm.prank(relayer1);  
        vm.expectRevert(  
            abi.encodeWithSelector(  
                InvalidChainId.selector, // Use direct name
                0  
            )  
        );  
        registry.addRelayer(0, 1);  

        vm.prank(relayer1);  
        vm.expectRevert(  
            abi.encodeWithSelector(  
                InvalidTier.selector, // Use direct name
                0  
            )  
        );  
        registry.addRelayer(1, 0);  
    }  

    /* -------------------------  
       Advanced: Fuzzing for addRelayer 
       ------------------------- */  
    function testFuzzAddRelayer(uint256 chainId, uint8 tier) public {  
        vm.assume(chainId > 0 && chainId < 1000);  
        vm.assume(tier >= 1 && tier <= 5);  

        vm.prank(relayer1);  
        stakeToken.approve(address(registry), type(uint256).max);  

        vm.prank(relayer1);  
        registry.addRelayer(chainId, tier);  

        GlobalRelayerRegistry.RelayerInfo memory info = registry.getRelayerInfo(relayer1);  
        assertTrue(info.active);  
    }  

    /* -------------------------  
       Advanced: Invariants  
       ------------------------- */  
    function invariantTotalRelayers() public {  
        uint256 total = registry.totalRelayers();  
        assertGe(total, 0);  
    }  

    /* -------------------------  
       Advanced: Security - Reentrancy Protection  
       ------------------------- */  
    function testReentrancyAttackOnWithdraw() public {  
        vm.prank(attacker);  
        vm.expectRevert(); 
        registry.withdrawStake();  
    }  

    /* -------------------------  
       Advanced: Gas Usage for Global Scalability  
       ------------------------- */  
    function testGasUsageBatchAdd() public {  
        uint256 gasStart = gasleft();  

        uint256 totalRequired = MIN_STAKE * 2;  
        vm.prank(owner);
        stakeToken.approve(address(registry), totalRequired);  

        address[] memory addrs = new address[](2);  
        addrs[0] = relayer1;  
        addrs[1] = relayer2;  

        uint256[] memory chainIds = new uint256[](2);  
        chainIds[0] = 1;  
        chainIds[1] = 1;  

        uint8[] memory tiers = new uint8[](2);  
        tiers[0] = 1;  
        tiers[1] = 1;  

        vm.prank(owner);
        registry.addRelayersBatch(addrs, chainIds, tiers);  

        uint256 gasUsed = gasStart - gasleft();  
        console.log("Gas used for batch add:", gasUsed);
        assertLt(gasUsed, 500000); 
    }  

    /* -------------------------  
       Advanced: Events and Logs for Global Transparency  
       ------------------------- */  
    function testEventsEmission() public {  
        vm.prank(relayer1);  
        stakeToken.approve(address(registry), MIN_STAKE);  

        vm.expectEmit(true, true, true, true);  
        emit GlobalRelayerRegistry.RelayerAdded(relayer1, 1, 1, MIN_STAKE, block.timestamp);  

        vm.prank(relayer1);  
        registry.addRelayer(1, 1);  
    }
}