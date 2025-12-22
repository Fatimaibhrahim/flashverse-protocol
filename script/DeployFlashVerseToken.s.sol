// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol"; // For logging
import "../src/FlashVerseToken.sol";

contract DeployFlashVerseToken is Script {
    // Constants for readability and safety
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant MAX_TX_BP = 1000; // 10% in basis points (1000 = 10%)

    function run() external returns (FlashVerseToken token) {  
        // Load deployer private key from env  
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");  
        require(deployerPrivateKey != 0, "Invalid private key");  
          
        address deployer = vm.addr(deployerPrivateKey);  
        console.log("Deploying from address:", deployer);  

        vm.startBroadcast(deployerPrivateKey);  

        // Deploy the token with corrected basis points  
        token = new FlashVerseToken(  
            "FlashVerse",  
            "FLASH",  
            INITIAL_SUPPLY,  
            MAX_TX_BP  
        );  

        vm.stopBroadcast();  

        // Verify deployment  
        require(address(token) != address(0), "Deployment failed");  
        console.log("Token deployed at:", address(token));  
        console.log("Network chain ID:", block.chainid);  
    }
}