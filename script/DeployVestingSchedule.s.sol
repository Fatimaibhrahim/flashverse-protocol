// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/VestingSchedule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployVestingSchedule is Script {
    function run() external returns (VestingSchedule vesting) {
        // Load deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        require(deployerPrivateKey != 0, "Invalid PRIVATE_KEY");

        // Explicitly define string type to resolve envOr ambiguity
        string memory defaultRpc = "http://localhost:8545";
        string memory rpcUrl = vm.envOr("RPC_URL", defaultRpc);
        
        // Select the fork based on RPC URL
        vm.createSelectFork(rpcUrl);

        // Derive deployer address
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying from address:", deployer);
        console.log("Using RPC URL:", rpcUrl);

        // Load ERC20 token address from environment
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        require(tokenAddress != address(0), "TOKEN_ADDRESS must be set");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the VestingSchedule contract
        vesting = new VestingSchedule(IERC20(tokenAddress));

        vm.stopBroadcast();

        console.log("VestingSchedule deployed at:", address(vesting));
        console.log("Network chain ID:", block.chainid);
    }
}