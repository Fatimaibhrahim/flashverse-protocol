// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/mocks/MockERC20.sol";
import "../src/GlobalRelayerRegistry.sol";

contract DeployMockAndRegistry is Script {
    // Constants for configuration
    uint256 public constant MIN_STAKE = 1 ether;
    uint256 public constant UNSTAKE_COOLDOWN = 1 days;
    uint8 public constant VOTE_THRESHOLD = 50; 

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        require(deployerPrivateKey != 0, "Invalid private key");

        vm.startBroadcast(deployerPrivateKey);

        MockERC20 token;
        try new MockERC20("Flash Stake Token", "FST", 18) returns (MockERC20 _token) {
            token = _token;
            console.log("MockERC20 deployed at:", vm.toString(address(token)));
        } catch {
            console.log("Failed to deploy MockERC20");
            revert("Deployment failed");
        }

        GlobalRelayerRegistry registry;
        try new GlobalRelayerRegistry(
            address(token),
            MIN_STAKE,
            UNSTAKE_COOLDOWN,
            VOTE_THRESHOLD
        ) returns (GlobalRelayerRegistry _registry) {
            registry = _registry;
            console.log("GlobalRelayerRegistry deployed at:", vm.toString(address(registry)));
        } catch {
            console.log("Failed to deploy GlobalRelayerRegistry");
            revert("Deployment failed");
        }

        console.log("All contracts deployed successfully.");
        vm.stopBroadcast();
    }
}