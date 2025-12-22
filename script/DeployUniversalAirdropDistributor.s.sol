// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/UniversalAirdropDistributor.sol";

contract DeployUniversalAirdropDistributor is Script {
    function run() external returns (UniversalAirdropDistributor distributor) {
        // 1. Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        require(deployerPrivateKey != 0, "Invalid PRIVATE_KEY");

        // 2. Load RPC URL with explicit string casting to fix the "Not Unique" error
        string memory rpcUrl = vm.envOr("RPC_URL", string("http://localhost:8545"));
        vm.createSelectFork(rpcUrl);

        // 3. Derive deployer address
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying from address:", deployer);
        console.log("Using RPC URL:", rpcUrl);

        // 4. Load initial token address (The FlashVerseToken address you deployed)
        address initialToken = vm.envOr("TOKEN_ADDRESS", address(0));
        require(initialToken != address(0), "TOKEN_ADDRESS must be set");

        // 5. Load token type (0 for ERC20)
        uint256 tokenTypeUint = vm.envOr("TOKEN_TYPE", uint256(0)); 
        UniversalAirdropDistributor.TokenType tokenType = UniversalAirdropDistributor.TokenType(uint8(tokenTypeUint));

        // 6. Start the actual deployment on the blockchain
        vm.startBroadcast(deployerPrivateKey);

        distributor = new UniversalAirdropDistributor(
            deployer,
            initialToken,
            tokenType
        );

        vm.stopBroadcast();

        // 7. Success logs
        console.log("Distributor deployed at:", address(distributor));
        console.log("Token address linked:", initialToken);
    }
}