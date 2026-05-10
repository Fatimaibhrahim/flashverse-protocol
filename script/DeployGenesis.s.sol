// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse - GenesisWallet Deploy Script (Foundry)
// ============================================================

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/GenesisWallet.sol";
import "../src/VestingSchedule.sol";
import "../src/mocks/MockERC20.sol"; // Using your custom Mock

contract DeployGenesis is Script {

    // CONFIGURATION
    address constant EXISTING_FLASH_TOKEN = address(0);

    // Fatima - Lead Architect: 5M tokens, 6 months, no cliff
    address constant FATIMA_WALLET   = 0x0000000000000000000000000000000000000001;
    uint256 constant FATIMA_TOKENS   = 5_000_000 ether;
    uint64  constant FATIMA_CLIFF    = 0;
    uint64  constant FATIMA_DURATION = 180 days;

    // Distribution wallets
    address constant PUBLIC_SALE_WALLET  = 0x0000000000000000000000000000000000000002;
    address constant FOUNDERS_WALLET     = 0x0000000000000000000000000000000000000003;
    address constant TREASURY_VAULT      = 0x0000000000000000000000000000000000000004;
    address constant ECOSYSTEM_VAULT     = 0x0000000000000000000000000000000000000005;
    address constant LIQUIDITY_WALLET    = 0x0000000000000000000000000000000000000006;
    address constant INVESTORS_WALLET    = 0x0000000000000000000000000000000000000007;

    uint256 constant TOTAL_SUPPLY = 18_000_000_000 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        _printHeader(deployer);

        vm.startBroadcast(deployerKey);

        // Step 1: Token Deployment (Using your MockERC20)
        address tokenAddr;
        if (EXISTING_FLASH_TOKEN == address(0)) {
            console.log("\n[1/7] Deploying MockERC20 as FLASH Token...");
            // Passing 3 parameters as defined in your MockERC20 constructor
            MockERC20 t = new MockERC20("Flash Token", "FLASH", TOTAL_SUPPLY);
            tokenAddr = address(t);
        } else {
            console.log("\n[1/7] Using existing FLASH Token...");
            tokenAddr = EXISTING_FLASH_TOKEN;
        }
        console.log("  => FLASH Token:", tokenAddr);

        // Step 2: VestingSchedule Deployment
        console.log("\n[2/7] Deploying VestingSchedule...");
        VestingSchedule vesting = new VestingSchedule(IERC20(tokenAddr));
        console.log("  => VestingSchedule:", address(vesting));

        // Step 3: GenesisWallet Deployment
        console.log("\n[3/7] Deploying GenesisWallet...");
        GenesisWallet genesis = new GenesisWallet(IERC20(tokenAddr));
        console.log("  => GenesisWallet:", address(genesis));

        // Step 4: Configuration
        console.log("\n[4/7] Configuring addresses...");
        genesis.configureAddresses(
            deployer,
            PUBLIC_SALE_WALLET,
            FOUNDERS_WALLET,
            address(vesting),
            TREASURY_VAULT,
            ECOSYSTEM_VAULT,
            LIQUIDITY_WALLET,
            INVESTORS_WALLET
        );
        console.log("  => Configured.");

        // Step 5: Approval
        console.log("\n[5/7] Approving GenesisWallet...");
        IERC20(tokenAddr).approve(address(genesis), TOTAL_SUPPLY);
        console.log("  => Approved.");

        // Step 6: Distribution
        console.log("\n[6/7] Executing TGE Distribution...");
        genesis.distribute();
        console.log("  => Distributed.");

        // Step 7: Fatima's Personal Vesting Setup
        console.log("\n[7/7] Creating Fatima's vesting...");
        IERC20(tokenAddr).approve(address(vesting), FATIMA_TOKENS);
        vesting.createVesting(
            FATIMA_WALLET,
            FATIMA_TOKENS,
            uint64(block.timestamp),
            FATIMA_CLIFF,
            FATIMA_DURATION
        );
        console.log("  => Fatima vesting created.");

        vm.stopBroadcast();

        _printSummary(tokenAddr, address(vesting), address(genesis));
    }

    function _printHeader(address deployer) internal view {
        console.log("\n================================================");
        console.log("  FlashVerse - GenesisWallet Deployment");
        console.log("================================================");
        console.log("  Deployer:", deployer);
        console.log("  Balance: ", deployer.balance / 1e18, "MATIC");
        console.log("================================================");
    }

    function _printSummary(address token, address vesting, address genesis) internal pure {
        console.log("\n================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("================================================");
        console.log("  FLASH Token:      ", token);
        console.log("  VestingSchedule:  ", vesting);
        console.log("  GenesisWallet:    ", genesis);
        console.log("================================================");
    }
}