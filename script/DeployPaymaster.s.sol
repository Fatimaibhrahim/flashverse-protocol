// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/Paymaster.sol";

/// @title DeployPaymaster Script - FlashVerse Global Deployment
/// @notice Deploys Paymaster contract with secure key handling and error management.
contract DeployPaymaster is Script {
    function run() external {
        // Correction: Using try/catch for key loading instead of envUintOr
        // to ensure compatibility with older Forge versions.
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("Error: PRIVATE_KEY environment variable not set or invalid.");
        }
        
        // Ensure the private key is not zero
        require(deployerPrivateKey != 0, "Error: Invalid private key (key is zero).");

        vm.startBroadcast(deployerPrivateKey);

        Paymaster paymaster;

        try new Paymaster() returns (Paymaster _paymaster) {
            paymaster = _paymaster;
            
            require(address(paymaster) != address(0), "Deployment failed: zero address returned.");

            console.log("Paymaster deployed successfully at:");
            console.logAddress(address(paymaster));
        } catch Error(string memory reason) {
            console.log("Deployment failed with reason:");
            console.log(reason);
            revert("Deployment failed: Solidity error");
        } catch {
            revert("Deployment failed: Unknown error");
        }

        vm.stopBroadcast();
    }
}