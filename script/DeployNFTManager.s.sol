// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/NFTManager.sol";

/// @title DeployNFTManager Script - FlashVerse Global Deployment with Mock Collections
/// @notice Deploys NFTManager and optional mock ERC721/ERC1155 collections for testing.
contract DeployNFTManager is Script {
    function run() external {
        // Load deployer's private key from environment variables
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("PRIVATE_KEY environment variable not set or invalid");
        }
        require(deployerPrivateKey != 0, "Invalid private key");

        // Start broadcast to execute transactions on the network
        vm.startBroadcast(deployerPrivateKey);

        // Deploy NFTManager contract
        NFTManager manager;
        try new NFTManager() returns (NFTManager _manager) {
            manager = _manager;
            require(address(manager) != address(0), "Deployment failed: zero address");
            console.log("NFTManager deployed successfully at:");
            console.logAddress(address(manager));
        } catch Error(string memory reason) {
            console.log("Deployment failed with reason:");
            console.log(reason);
            revert("NFTManager deployment reverted");
        } catch {
            console.log("Unknown error during NFTManager deployment");
            revert("Unknown failure");
        }

        // === Create mock ERC721 collection if env var not set ===
        try vm.envAddress("MOCK_ERC721") returns (address mock721) {
            if (mock721 == address(0)) revert();
            console.log("Using existing MOCK_ERC721:", mock721);
        } catch {
            string memory name = "MockERC721";
            string memory symbol = "M721";
            string memory baseURI = "";
            address royaltyReceiver = msg.sender;
            uint96 royaltyFee = 500; // 5%
            address collection = manager.createCollection(name, symbol, baseURI, false, royaltyReceiver, royaltyFee);
            console.log("Mock ERC721 collection deployed at:", collection);
        }

        // === Create mock ERC1155 collection if env var not set ===
        try vm.envAddress("MOCK_ERC1155") returns (address mock1155) {
            if (mock1155 == address(0)) revert();
            console.log("Using existing MOCK_ERC1155:", mock1155);
        } catch {
            string memory name = "MockERC1155";
            string memory symbol = ""; // ERC1155 has no symbol
            string memory baseURI = "https://example.com/metadata/";
            address royaltyReceiver = msg.sender;
            uint96 royaltyFee = 500; // 5%
            address collection = manager.createCollection(name, symbol, baseURI, true, royaltyReceiver, royaltyFee);
            console.log("Mock ERC1155 collection deployed at:", collection);
        }

        // Stop broadcast
        vm.stopBroadcast();
    }
}