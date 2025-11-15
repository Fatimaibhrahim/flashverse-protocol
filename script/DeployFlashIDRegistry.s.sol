// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/FlashIDRegistry.sol";

contract DeployFlashIDRegistry is Script {
    function run() external {
        uint256 deployerKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerKey = key;
            console.log("Using PRIVATE_KEY from env.");
        } catch {
            deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default key
            console.log("WARNING: PRIVATE_KEY not set. Using Anvil default key for local testing.");
        }

        require(deployerKey != 0, "Invalid deployer key: must be non-zero.");

        address ownerAddr;
        try vm.envAddress("OWNER_ADDRESS") returns (address addr) {
            ownerAddr = addr;
            console.log("Using OWNER_ADDRESS from env:", ownerAddr);
        } catch {
            ownerAddr = address(0);
            console.log("No OWNER_ADDRESS provided, will use deployer as owner.");
        }

        vm.startBroadcast(deployerKey);

        address finalOwner = ownerAddr == address(0) ? msg.sender : ownerAddr;
        console.log("Final owner set to:", finalOwner);
        
        FlashIDRegistry registry = new FlashIDRegistry(finalOwner);

        console.log("FlashIDRegistry deployed at:", address(registry));

        vm.stopBroadcast();

        console.log("DEPLOY COMPLETE.");
    }
}