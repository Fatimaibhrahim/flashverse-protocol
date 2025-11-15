// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/TreasuryVault.sol";

/// @title DeployTreasuryVault Script - FlashVerse Global Deployment
/// @notice Deploys TreasuryVault with env-based fee, secure key handling, and logging
contract DeployTreasuryVault is Script {

    /// @notice Executes the complete deployment process for the TreasuryVault contract.
    /// @dev Requires PRIVATE_KEY and TREASURY_INITIAL_FEE to be set as environment variables.
    function run() external {
        // Load deployer's private key from environment
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("PRIVATE_KEY environment variable not set or invalid");
        }
        require(deployerPrivateKey != 0, "Invalid private key");

        // Load initial fee from environment
        uint256 initialFee;
        try vm.envUint("TREASURY_INITIAL_FEE") returns (uint256 fee) {
            initialFee = fee;
        } catch {
            revert("TREASURY_INITIAL_FEE env variable not set or invalid");
        }

        // Validate initial fee (max 1000 basis points = 10%)
        require(initialFee <= 1000, "Initial fee too high (>10%)");
        
        console.log("Starting deployment...");
        console.log("Initial Fee (BPS):", initialFee);

        // Start broadcast for on-chain transaction
        vm.startBroadcast(deployerPrivateKey);

        TreasuryVault vault;
        
        // Attempt to deploy the contract
        try new TreasuryVault(initialFee) returns (TreasuryVault _vault) {
            vault = _vault;
            // Ensure deployment resulted in a non-zero address
            require(address(vault) != address(0), "Deployment failed: zero address");
            
            // Log successful deployment details
            console.log("TreasuryVault deployed successfully at:");
            console.logAddress(address(vault));
            console.log("Initial withdrawal fee (bps):", initialFee);
        } catch Error(string memory reason) {
            // Handle specific deployment revert reason
            console.log("Deployment failed with reason:");
            console.log(reason);
            revert("TreasuryVault deployment reverted");
        } catch {
            // Handle unknown deployment failure
            console.log("Unknown error during TreasuryVault deployment");
            revert("Unknown failure");
        }

        // Stop broadcast
        vm.stopBroadcast();
    }
}