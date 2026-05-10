// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/DeFiHub.sol";
import "../src/mocks/MockERC20.sol"; 

/**
 * @title DeployDeFiHub
 * @dev Fixed deployment script. Passes the required arguments (Name, Symbol, Supply) 
 * to the MockERC20 constructor to resolve the 'Wrong argument count' error.
 */
contract DeployDeFiHub is Script {

    function run() external {
        // 1. Setup Deployer Environment
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 2. Deploy MockERC20 Instances
        // Constructor arguments: (string memory name, string memory symbol, uint256 initialSupply)
        // Adjust these if your MockERC20.sol uses a different order or different types.
        
        console.log("Step 1: Deploying MockERC20 instances with constructor arguments...");

        MockERC20 stakingToken = new MockERC20(
            "Staking Token", 
            "STK", 
            1_000_000 * 10**18
        );

        MockERC20 rewardToken = new MockERC20(
            "Reward Token", 
            "REW", 
            1_000_000 * 10**18
        );
        
        console.log("Staking Token (Asset A) deployed at:", address(stakingToken));
        console.log("Reward Token (Asset B) deployed at:", address(rewardToken));

        // 3. Deploy DeFiHub Core
        console.log("Step 2: Deploying DeFiHub v3...");
        
        address treasury = address(0x3333333333333333333333333333333333333333);
        uint256 rewardRate = 1e18; 

        DeFiHub hub = new DeFiHub(
            address(stakingToken),
            address(rewardToken),
            rewardRate,
            treasury
        );

        console.log("DeFiHub successfully deployed at:", address(hub));

        vm.stopBroadcast();

        _printSummary(address(hub), address(stakingToken), address(rewardToken));
    }

    // --- LOGGING HELPERS ---

    function _printHeader(address deployer) internal view {
        console.log("------------------------------------------------");
        console.log("FlashVerse: Sequential Deployment Fix");
        console.log("Deployer Address:", deployer);
        console.log("------------------------------------------------");
    }

    function _printSummary(address hub, address staking, address reward) internal pure {
        console.log("------------------------------------------------");
        console.log("DEPLOYMENT SUMMARY");
        console.log("------------------------------------------------");
        console.log("DeFiHub Contract: ", hub);
        console.log("Staking Asset:    ", staking);
        console.log("Reward Asset:     ", reward);
        console.log("------------------------------------------------");
    }
}