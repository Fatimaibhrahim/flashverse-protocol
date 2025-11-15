// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/SmartAccountMultiSig.sol";

/// @title DeploySmartAccountMultiSig Script - FlashVerse Global Deployment
/// @notice Deploys SmartAccountMultiSig with secure private key handling and logging
contract DeploySmartAccountMultiSig is Script {
    function run() external {
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("PRIVATE_KEY environment variable not set or invalid");
        }
        require(deployerPrivateKey != 0, "Invalid private key");

        // Define owners array and threshold for deployment
        address[] memory owners = new address[](2);
        owners[0] = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9; // Initial owner
        owners[1] = vm.addr(deployerPrivateKey); // Deployer as second owner
        uint256 threshold = 2;

        vm.startBroadcast(deployerPrivateKey);

        SmartAccountMultiSig account;
        try new SmartAccountMultiSig(owners, threshold) returns (SmartAccountMultiSig _account) {
            account = _account;
            require(address(account) != address(0), "Deployment failed: zero address");
            console.log("SmartAccountMultiSig deployed successfully at:");
            console.logAddress(address(account));
        } catch Error(string memory reason) {
            console.log("Deployment failed with reason:");
            console.log(reason);
            revert("SmartAccountMultiSig deployment reverted");
        } catch {
            console.log("Unknown error during SmartAccountMultiSig deployment");
            revert("Unknown failure");
        }

        vm.stopBroadcast();
    }
}