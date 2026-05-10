// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  FlashVerse - FlashVerseToken Deploy Script (Foundry)
//
//  Usage:
//    Anvil:    forge script script/DeployFlashToken.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast -vvvv
//    Testnet:  forge script script/DeployFlashToken.s.sol --rpc-url $AMOY_RPC --broadcast --verify -vvvv
//    Mainnet:  forge script script/DeployFlashToken.s.sol --rpc-url $POLYGON_RPC --broadcast --verify -vvvv
//
//  Required .env (testnet/mainnet):
//    PRIVATE_KEY=0x...
//    AMOY_RPC=https://rpc-amoy.polygon.technology
//    POLYGON_RPC=https://polygon-rpc.com
//    POLYGONSCAN_API_KEY=...
// ============================================================

import "forge-std/Script.sol";
import "../src/FlashVerseToken.sol";

contract DeployFlashToken is Script {

    // ─────────────────────────────────────────
    //  CONFIGURATION
    //  ⚠️  Review before each deployment
    // ─────────────────────────────────────────

    string  constant TOKEN_NAME   = "Flash Token";
    string  constant TOKEN_SYMBOL = "FLASH";

    // 18,000,000,000 FLASH
    uint256 constant TOTAL_SUPPLY = 18_000_000_000 ether;

    // Anti-whale: 1% of supply per transaction
    uint256 constant MAX_TX_BPS   = 100; // 1%

    address constant GENESIS_WALLET     = address(0);
    address constant VESTING_SCHEDULE   = address(0);
    address constant MILESTONE_VESTING  = address(0);
    address constant TREASURY_VAULT     = address(0);

    // ─────────────────────────────────────────
    //  MAIN
    // ─────────────────────────────────────────
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        _printHeader(deployer);

        vm.startBroadcast(deployerKey);

        console.log("\n[1/3] Deploying FlashVerseToken...");
        FlashVerseToken token = new FlashVerseToken(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOTAL_SUPPLY,
            MAX_TX_BPS
        );
        console.log("  => FlashVerseToken:", address(token));
        console.log("  => Total Supply:   ", TOTAL_SUPPLY / 1e18, "FLASH");
        console.log("  => Max Tx Amount:  ", token.maxTxAmount() / 1e18, "FLASH (1%)");

        console.log("\n[2/3] Setting exemptions...");

        console.log("  => Deployer exempt: ", token.isExempt(deployer));
        console.log("  => Contract exempt: ", token.isExempt(address(token)));

        if (GENESIS_WALLET != address(0)) {
            token.setExempt(GENESIS_WALLET, true);
            console.log("  => GenesisWallet exempted");
        } else {
            console.log("  => GenesisWallet: set address and call setExempt() after deploy");
        }

        if (VESTING_SCHEDULE != address(0)) {
            token.setExempt(VESTING_SCHEDULE, true);
            console.log("  => VestingSchedule exempted");
        }

        if (MILESTONE_VESTING != address(0)) {
            token.setExempt(MILESTONE_VESTING, true);
            console.log("  => MilestoneVesting exempted");
        }

        if (TREASURY_VAULT != address(0)) {
            token.setExempt(TREASURY_VAULT, true);
            console.log("  => TreasuryVault exempted");
        }

        console.log("\n[3/3] Verifying state...");
        console.log("  => Owner:         ", token.owner());
        console.log("  => Total Supply:  ", token.totalSupply() / 1e18, "FLASH");
        console.log("  => Owner Balance: ", token.balanceOf(deployer) / 1e18, "FLASH");

        vm.stopBroadcast();

        _printSummary(address(token), deployer);
    }

    // ─────────────────────────────────────────
    //  HELPERS
    // ─────────────────────────────────────────
    function _printHeader(address deployer) internal view {
        console.log("\n================================================");
        console.log("  FlashVerse - FLASH Token Deployment");
        console.log("================================================");
        console.log("  Deployer:", deployer);
        console.log("  Balance: ", deployer.balance / 1e18, "MATIC");
        console.log("================================================");
    }

    function _printSummary(address token, address deployer) internal pure {
        console.log("\n================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("================================================");
        console.log("  FLASH Token:", token);
        console.log("================================================");
        console.log("\n  Checklist after deploy:");
        console.log("  [ ] Deploy GenesisWallet with this token address");
        console.log("  [ ] Call setExempt(genesisWallet, true)");
        console.log("  [ ] Call setExempt(vestingSchedule, true)");
        console.log("  [ ] Call setExempt(milestoneVesting, true)");
        console.log("  [ ] Call setExempt(treasuryVault, true)");
        console.log("  [ ] Call setExempt(dexPool, true) after liquidity add");
        console.log("  [ ] Transfer ownership to multisig before mainnet");
        console.log("  [ ] Verify on Polygonscan:");
        console.log("      forge verify-contract", token);
        console.log("      src/FlashVerseToken.sol:FlashVerseToken");
        console.log("      --chain polygon");
        console.log("      --constructor-args $(cast abi-encode");
        console.log("        'constructor(string,string,uint256,uint256)'");
        console.log("        'Flash Token' 'FLASH'", deployer, deployer);
        console.log("      --etherscan-api-key $POLYGONSCAN_API_KEY");
        console.log("================================================\n");
    }
}