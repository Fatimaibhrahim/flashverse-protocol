// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse – Foundry Deploy Script
//  Deploys: FLASH Token + VestingSchedule + GenesisWallet + MilestoneVesting
//
//  Usage:
//    Testnet:  forge script script/Deploy.s.sol --rpc-url $AMOY_RPC --broadcast --verify -vvvv
//    Mainnet:  forge script script/Deploy.s.sol --rpc-url $POLYGON_RPC --broadcast --verify -vvvv
//
//  Required .env:
//    PRIVATE_KEY=0x...
//    AMOY_RPC=https://...
//    POLYGON_RPC=https://...
//    POLYGONSCAN_API_KEY=...
// ============================================================

import "forge-std/Script.sol";
import "../src/mocks/MockERC20.sol";
import "../src/VestingSchedule.sol";
import "../src/GenesisWallet.sol";
import "../src/MilestoneVesting.sol";

contract DeployFlashVerse is Script {

    // ─────────────────────────────────────────
    //  CONFIGURATION — Fill before mainnet deploy
    // ─────────────────────────────────────────

    // Fatima's personal vesting: 5M tokens, 6 months, no cliff
    address constant FATIMA_WALLET    = 0x0000000000000000000000000000000000000001;
    uint256 constant FATIMA_TOKENS    = 5_000_000 ether;
    uint64  constant FATIMA_CLIFF     = 0;
    uint64  constant FATIMA_DURATION  = 180 days;

    // Team & distribution wallets (replace with real addresses)
    address constant PUBLIC_SALE      = 0x0000000000000000000000000000000000000002;
    address constant FOUNDERS_WALLET  = 0x0000000000000000000000000000000000000003;
    address constant TREASURY_VAULT   = 0x0000000000000000000000000000000000000004;
    address constant ECOSYSTEM_VAULT  = 0x0000000000000000000000000000000000000005;
    address constant LIQUIDITY_WALLET = 0x0000000000000000000000000000000000000006;
    address constant INVESTORS_WALLET = 0x0000000000000000000000000000000000000007;

    // Total supply
    uint256 constant TOTAL_SUPPLY = 18_000_000_000 ether;

    // ─────────────────────────────────────────
    //  MAIN
    // ─────────────────────────────────────────
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("====================================================");
        console.log("  FlashVerse Deployment");
        console.log("====================================================");
        console.log("  Deployer:", deployer);
        console.log("  Balance: ", deployer.balance / 1e18, "MATIC");
        console.log("====================================================");

        vm.startBroadcast(deployerKey);

        // ─── Step 1: Deploy FLASH Token ───
        console.log("\n[1/7] Deploying FLASH Token...");
        MockERC20 token = new MockERC20("Flash Token", "FLASH", TOTAL_SUPPLY);
        console.log("  FLASH Token:", address(token));

        // ─── Step 2: Deploy VestingSchedule ───
        console.log("\n[2/7] Deploying VestingSchedule...");
        VestingSchedule vestingSchedule = new VestingSchedule(IERC20(address(token)));
        console.log("  VestingSchedule:", address(vestingSchedule));

        // ─── Step 3: Deploy GenesisWallet ───
        console.log("\n[3/7] Deploying GenesisWallet...");
        GenesisWallet genesisWallet = new GenesisWallet(IERC20(address(token)));
        console.log("  GenesisWallet:", address(genesisWallet));

        // ─── Step 4: Deploy MilestoneVesting ───
        console.log("\n[4/7] Deploying MilestoneVesting...");
        MilestoneVesting milestoneVesting = new MilestoneVesting(IERC20(address(token)));
        console.log("  MilestoneVesting:", address(milestoneVesting));

        // ─── Step 5: Configure GenesisWallet ───
        console.log("\n[5/7] Configuring GenesisWallet addresses...");
        genesisWallet.configureAddresses(
            deployer,                        // airdropDistributor (deployer holds for now)
            PUBLIC_SALE,
            FOUNDERS_WALLET,
            address(vestingSchedule),        // coreTeamVesting -> VestingSchedule
            TREASURY_VAULT,
            ECOSYSTEM_VAULT,
            LIQUIDITY_WALLET,
            INVESTORS_WALLET
        );
        console.log("  Configured.");

        // ─── Step 6: Execute TGE Distribution ───
        console.log("\n[6/7] Executing TGE Distribution...");
        token.approve(address(genesisWallet), TOTAL_SUPPLY);
        genesisWallet.distribute();
        console.log("  TGE distributed.");

        // ─── Step 7: Setup Fatima's vesting (6 months, no cliff) ───
        console.log("\n[7/7] Setting up Fatima's personal vesting (5M tokens, 6 months)...");
        token.approve(address(vestingSchedule), FATIMA_TOKENS);
        vestingSchedule.createVesting(
            FATIMA_WALLET,
            FATIMA_TOKENS,
            uint64(block.timestamp),
            FATIMA_CLIFF,
            FATIMA_DURATION
        );
        console.log("  Fatima vesting created.");

        vm.stopBroadcast();

        // ─── Summary ───
        console.log("\n====================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("====================================================");
        console.log("  FLASH Token:       ", address(token));
        console.log("  VestingSchedule:   ", address(vestingSchedule));
        console.log("  GenesisWallet:     ", address(genesisWallet));
        console.log("  MilestoneVesting:  ", address(milestoneVesting));
        console.log("====================================================");
        console.log("\n  Next steps:");
        console.log("  1. Add team to MilestoneVesting via addBeneficiary()");
        console.log("  2. Add rest of core team to VestingSchedule via createVesting()");
        console.log("  3. Verify contracts on Polygonscan");
        console.log("====================================================\n");
    }
}