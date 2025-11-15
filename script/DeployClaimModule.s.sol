// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ClaimModule.sol";

contract DeployClaimModule is Script {
    function run() external {
        // --- Load private key securely ---
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("PRIVATE_KEY environment variable not set or invalid");
        }
        require(deployerPrivateKey != 0, "Invalid private key");

        // --- Deployment Context ---
        console.log("============================================");
        console.log("Deploying ClaimModule (FlashVerse DeFiHub)");
        console.log("RPC_URL:", vm.envString("RPC_URL"));
        console.log("Deployer Address:");
        console.logAddress(vm.addr(deployerPrivateKey));
        console.log("============================================");

        vm.startBroadcast(deployerPrivateKey);

        // --- Deploy ClaimModule ---
        ClaimModule claimModule;
        try new ClaimModule() returns (ClaimModule _module) {
            claimModule = _module;
            require(address(claimModule) != address(0), "Deployment returned zero address");

            console.log("ClaimModule successfully deployed at:");
            console.logAddress(address(claimModule));
        } catch Error(string memory reason) {
            console.log("Failed to deploy ClaimModule:");
            console.log(reason);
            revert("Deployment failed");
        } catch {
            console.log("Unknown error during deployment");
            revert("Deployment failed");
        }

        vm.stopBroadcast();

        console.log("============================================");
        console.log("Deployment Completed Successfully");
        console.log("============================================");
    }
}