// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  DeployUniversalAirdropDistributor
 * @notice Production deploy script — Foundry broadcast pattern.
 *
 * @dev    Prerequisites:
 * 1. Copy .env.example → .env and fill in your values
 * 2. Run:
 *
 * # Dry-run (no broadcast, no gas spent)
 * forge script script/Deploy.s.sol \
 * --rpc-url $RPC_URL \
 * --sender  $DEPLOYER_ADDRESS \
 * -vvvv
 *
 * # Live deploy + Etherscan verification
 * forge script script/Deploy.s.sol \
 * --rpc-url $RPC_URL \
 * --broadcast \
 * --verify \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * -vvvv
 *
 * # Ledger hardware wallet
 * forge script script/Deploy.s.sol \
 * --rpc-url  $RPC_URL \
 * --broadcast \
 * --ledger \
 * --verify \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * -vvvv
 */

import {Script, console2}            from "forge-std/Script.sol";
import {UniversalAirdropDistributor} from "../src/UniversalAirdropDistributor.sol";

contract DeployUniversalAirdropDistributor is Script {

    /*//////////////////////////////////////////////////////////////
                        DEPLOY CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Override via DEPLOYER_ADDRESS env var.
    ///      Falls back to the default Foundry test address in dry-runs.
    function _deployer() internal view returns (address) {
        try vm.envAddress("DEPLOYER_ADDRESS") returns (address d) {
            return d;
        } catch {
            return 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Foundry default
        }
    }

    /*//////////////////////////////////////////////////////////////
                            RUN
    //////////////////////////////////////////////////////////////*/

    function run() external returns (UniversalAirdropDistributor distributor) {
        address deployer = _deployer();

        // ── Pre-flight log ─────────────────────────────────────
        console2.log("");
        console2.log("=================================================");
        console2.log("   UniversalAirdropDistributor  v2.1  Deploy");
        console2.log("=================================================");
        console2.log("  Chain ID   :", block.chainid);
        console2.log("  Block      :", block.number);
        console2.log("  Deployer   :", deployer);
        console2.log("  Balance    :", deployer.balance / 1e18, "ETH");
        console2.log("-------------------------------------------------");

        // ── Deploy ─────────────────────────────────────────────
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        distributor = new UniversalAirdropDistributor(deployer);

        vm.stopBroadcast();

        // ── Post-deploy log ────────────────────────────────────
        console2.log("  Contract   :", address(distributor));
        console2.log("  Owner      :", distributor.owner());
        console2.log("  Max Batch  :", distributor.maxBatchSize());
        console2.log("=================================================");
        console2.log("");

        // ── Sanity checks (revert in CI if something is wrong) ─
        require(address(distributor) != address(0), "Deploy: zero address");
        require(distributor.owner()  == deployer,   "Deploy: wrong owner");
        require(distributor.maxBatchSize() == 200,  "Deploy: wrong batch size");
    }
}