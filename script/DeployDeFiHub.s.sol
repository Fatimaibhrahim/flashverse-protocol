// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/DeFiHub.sol";
import "../src/mocks/MockERC20.sol";

/// @title DeployDeFiHub Script - FlashVerse Global Deployment (Flexible)
/// @notice Deploys DeFiHub with either existing tokens or mocks for local testing.
contract DeployDeFiHub is Script {
    function run() external {
        // Load deployer's private key securely
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("PRIVATE_KEY environment variable not set or invalid");
        }
        require(deployerPrivateKey != 0, "Invalid PRIVATE_KEY (must be non-zero)");

        vm.startBroadcast(deployerPrivateKey);

        address stakingToken;
        address rewardToken;

        // Try to load STAKING_TOKEN from environment, fallback to MockERC20
        try vm.envAddress("STAKING_TOKEN") returns (address addr) {
            stakingToken = addr;
        } catch {
            console.log("STAKING_TOKEN not set or invalid, deploying MockERC20...");
            MockERC20 mockStaking = new MockERC20("Mock Staking Token", "MST", 18);
            stakingToken = address(mockStaking);
            console.log("Mock StakingToken deployed at:");
            console.logAddress(stakingToken);
        }
        require(stakingToken != address(0), "Staking Token address is zero");

        // Try to load REWARD_TOKEN from environment, fallback to MockERC20
        try vm.envAddress("REWARD_TOKEN") returns (address addr) {
            rewardToken = addr;
        } catch {
            console.log("REWARD_TOKEN not set or invalid, deploying MockERC20...");
            MockERC20 mockReward = new MockERC20("Mock Reward Token", "MRT", 18);
            rewardToken = address(mockReward);
            console.log("Mock RewardToken deployed at:");
            console.logAddress(rewardToken);
        }
        require(rewardToken != address(0), "Reward Token address is zero");

        // Load reward rate, fallback to default 1e18
        uint256 rewardRate;
        try vm.envUint("REWARD_RATE") returns (uint256 rate) {
            rewardRate = rate;
        } catch {
            rewardRate = 1e18;
            console.log("REWARD_RATE not set or invalid, using default 1e18");
        }
        require(rewardRate > 0, "Reward rate must be greater than zero.");

        console.log("--- Deployment Parameters ---");
        console.log("Staking Token:", stakingToken);
        console.log("Reward Token:", rewardToken);
        console.log("Reward Rate:", rewardRate);
        console.log("-----------------------------");

        // Deploy DeFiHub with robust error handling
        DeFiHub hub;
        try new DeFiHub(stakingToken, rewardToken, rewardRate) returns (DeFiHub _hub) {
            hub = _hub;
            console.log("DeFiHub deployed successfully at:");
            console.logAddress(address(hub));
        } catch Error(string memory reason) {
            console.log("Deployment failed with reason:");
            console.log(reason);
            revert("DeFiHub deployment reverted");
        } catch {
            console.log("Unknown error during DeFiHub deployment");
            revert("Unknown failure");
        }

        vm.stopBroadcast();
    }
}