// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ClaimModule} from "../src/ClaimModule.sol";

/**
 * @title  DeployClaimModule
 * @notice Foundry deployment script for ClaimModule.
 *
 * @dev    Usage
 * -----
 * Local anvil:
 * forge script script/DeployClaimModule.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Testnet (Sepolia):
 * forge script script/DeployClaimModule.s.sol \
 * --rpc-url $SEPOLIA_RPC_URL \
 * --broadcast \
 * --verify \
 * --etherscan-api-key $ETHERSCAN_KEY \
 * -vvvv
 *
 * Mainnet:
 * forge script script/DeployClaimModule.s.sol \
 * --rpc-url $MAINNET_RPC_URL \
 * --broadcast \
 * --verify \
 * --etherscan-api-key $ETHERSCAN_KEY \
 * -vvvv
 *
 * Required env vars (.env):
 * PRIVATE_KEY    - deployer key (hex, with 0x prefix)
 * ADMIN_ADDRESS  - address to receive all roles (defaults to deployer)
 */
contract DeployClaimModule is Script {

    // ── Post-deploy sanity checks ────────────────────────────────────────
    function _sanityCheck(ClaimModule cm, address admin) internal view {
        require(cm.hasRole(cm.DEFAULT_ADMIN_ROLE(), admin), "Missing DEFAULT_ADMIN_ROLE");
        require(cm.hasRole(cm.ADMIN_ROLE(),         admin), "Missing ADMIN_ROLE");
        require(cm.hasRole(cm.PAUSER_ROLE(),        admin), "Missing PAUSER_ROLE");
        require(cm.hasRole(cm.MONITOR_ROLE(),       admin), "Missing MONITOR_ROLE");
        require(!cm.globalPaused(),                         "Should not be paused");
        require(cm.MAX_BATCH_SIZE() == 50,                  "Unexpected MAX_BATCH_SIZE");
        console.log("  [ok] All sanity checks passed");
    }

    function run() external {
        // ── Read config ──────────────────────────────────────────────────
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address deployerAddr = vm.addr(deployerKey);

        // ADMIN_ADDRESS defaults to deployer if not set
        address adminAddr;
        try vm.envAddress("ADMIN_ADDRESS") returns (address a) {
            adminAddr = a;
        } catch {
            adminAddr = deployerAddr;
        }

        // ── Log pre-deploy info ──────────────────────────────────────────
        console.log("================================================");
        console.log("  ClaimModule - Foundry Deploy Script"); // تم تعديل الشرطة هنا
        console.log("================================================");
        console.log("  Deployer :", deployerAddr);
        console.log("  Admin    :", adminAddr);
        console.log("  Chain ID :", block.chainid);
        console.log("  Balance  :", deployerAddr.balance / 1e18, "ETH");

        // ── Deploy ───────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        ClaimModule cm = new ClaimModule(adminAddr);

        vm.stopBroadcast();

        // ── Sanity check (read-only, outside broadcast) ──────────────────
        console.log("------------------------------------------------");
        console.log("  Deployed ClaimModule :", address(cm));
        _sanityCheck(cm, adminAddr);

        // ── Role hashes (useful for multisig setup) ──────────────────────
        console.log("------------------------------------------------");
        console.log("  Role hashes:");
        console.logBytes32(cm.DEFAULT_ADMIN_ROLE());
        console.logBytes32(cm.ADMIN_ROLE());
        console.logBytes32(cm.PAUSER_ROLE());
        console.logBytes32(cm.MONITOR_ROLE());
        console.log("================================================");
    }
}