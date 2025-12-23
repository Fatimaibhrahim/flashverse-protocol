
# FlashVerse Protocol
A comprehensive Ethereum protocol integrating multi-sig smart accounts, a relayer network, gas sponsorship via Paymaster, NFT collection management, and treasury vaults. Designed for secure, scalable, and gas-efficient decentralized applications, enabling DAOs, enterprise wallets, and advanced account abstraction use cases.

## Overview
This project implements a professional Gas Sponsorship system and related smart contracts for Ethereum and ERC20 tokens. It includes multi-sponsor functionality, fee management, cooldowns, batch operations, and advanced account management with multisig support. **Latest updates include the core tokenomics layer with dedicated vesting and airdrop modules.**

---

## Contracts

### Core Modules
* **1. FlashVerseToken.sol (New):** The native utility token with integrated flash loan protection and capped supply.
* **2. VestingSchedule.sol (New):** Secure linear vesting mechanism for team and stakeholders with emergency safety features.
* **3. UniversalAirdropDistributor.sol (New):** High-performance contract for multi-token and ETH airdrops.
* **4. Paymaster.sol:** Advanced ETH and ERC20 gas sponsorship contract. Features include **SPONSOR_ROLE** and **ADMIN_ROLE**, support for single and batch sponsorships, fee tracking, and cooldown periods.
* **5. SmartAccountMultiSig.sol:** Multi-owner smart account wallet (n-of-m) supporting **threshold signatures**, **ERC-1271 verification**, batch execution, and **ERC-4337 compatibility**.
* **6. TreasuryVault.sol:** Vault for managing ETH and ERC20 assets. Features include owner-based access control, configurable withdrawal fees (basis points), pausable functions, and emergency withdraws.

### Supporting Modules
* **7. GlobalRelayerRegistry.sol:** Manages a decentralized list of approved relayers.
* **8. FlashIDRegistry.sol:** Handles the registration and management of unique decentralized identifiers (IDs).
* **9. NFTManager.sol:** Deployment, management, and validation of ERC-721 and ERC-1155 NFT collections.
* **10. DeFiHub.sol:** Adapter designed to enable complex DeFi interactions (swapping/lending).
* **11. ClaimModule.sol:** Handles the distribution and claiming of tokens/rewards.
* **12. MockERC20.sol:** Used primarily for **testing purposes**.

---

## Deployment Scripts
-   Foundry-compatible deployment scripts (`.s.sol`).
-   **Phase 1 Scripts:** `DeployFlashVerseToken.s.sol`, `DeployVestingSchedule.s.sol`, and `DeployUniversalAirdropDistributor.s.sol`.
-   Example: `script/MockAndRegistry.s.sol` for mock deployment and initial registry setup.

---

## Environment Variables
The project uses a `.env` file. **Do not commit sensitive keys**. Example file `.env.example`:

```env
# RPC URL of target network
RPC_URL=
# Private key for deployment
PRIVATE_KEY=
# Optional: other network configuration

```

Place your real values in `.env`. This file is ignored in Git (`.gitignore`) for security.

---

## Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd <repo-directory>

# Install dependencies
forge install

# Compile all contracts
forge build

```

---

## Testing

Tests are written in Foundry (`*.t.sol`). **New security test suite included for Phase 1.**

```bash
# Run all tests
forge test

```

Supports gas snapshots and replays. Ensures all contracts function as expected.

---

## Usage

Deploy contracts using Foundry scripts:

```bash
# Example for Token deployment
forge script script/DeployFlashVerseToken.s.sol --broadcast --rpc-url $RPC_URL -vvvv

```

---

## Project Structure

```
.
├── src/ # Solidity contracts
│   ├── FlashVerseToken.sol
│   ├── VestingSchedule.sol
│   ├── UniversalAirdropDistributor.sol
│   ├── Paymaster.sol
│   ├── SmartAccountMultiSig.sol
│   └── TreasuryVault.sol
├── script/ # Deployment scripts
│   ├── DeployFlashVerseToken.s.sol
│   └── DeployVestingSchedule.s.sol
├── test/ # Foundry tests & Security Helpers
├── .env # Sensitive keys (ignored)
├── lib/ # Dependencies
├── README.md
└── .gitignore

```

---

## Notes

* Ensure `.env` is configured before deploying.
* Follow Foundry best practices for testing and gas reporting.
* All fee calculations are in basis points.
* MultiSig contract (`SmartAccountMultiSig.sol`) requires threshold signatures for execution.
* Phase 1 contracts include anti-flash loan logic and secure vesting release.

```