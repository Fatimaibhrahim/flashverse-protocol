# FlashVerse Protocol
A comprehensive Ethereum protocol integrating multi-sig smart accounts, a relayer network, gas sponsorship via Paymaster, NFT collection management, and treasury vaults. Designed for secure, scalable, and gas-efficient decentralized applications, enabling DAOs, enterprise wallets, and advanced account abstraction use cases.

## Overview
This project implements a professional Gas Sponsorship system and related smart contracts for Ethereum and ERC20 tokens. It includes multi-sponsor functionality, fee management, cooldowns, batch operations, and advanced account management with multisig support. The project is structured for the Foundry environment and includes deployment scripts, tests, and gas snapshots.

---

## Contracts

### Core Modules
* **1. Paymaster.sol:** Advanced ETH and ERC20 gas sponsorship contract. Features include **SPONSOR_ROLE** and **ADMIN_ROLE**, support for single and batch sponsorships, fee tracking, and cooldown periods. Implements OpenZeppelin security standards.
* **2. SmartAccountMultiSig.sol:** Multi-owner smart account wallet (n-of-m) supporting **threshold signatures**, **ERC-1271 verification**, batch execution, and **ERC-4337 compatibility** for Account Abstraction use cases.
* **3. TreasuryVault.sol:** Vault for managing ETH and ERC20 assets. Features include owner-based access control, configurable withdrawal fees (basis points), pausable functions, and emergency withdraws.

### Supporting Modules
* **4. GlobalRelayerRegistry.sol:** Manages a decentralized list of approved relayers for secure transaction submission.
* **5. FlashIDRegistry.sol:** Handles the registration and management of unique decentralized identifiers (IDs) for smart accounts.
* **6. NFTManager.sol:** Contract responsible for deploying, managing, and validating ERC-721 and ERC-1155 NFT collections integrated with the protocol.
* **7. DeFiHub.sol:** An adapter or hub contract designed to enable complex DeFi interactions (like swapping or lending) through the Smart Account.
* **8. ClaimModule.sol:** Handles the distribution and claiming of tokens/rewards, typically used for token claims or reward distribution mechanisms.
* **9. MockERC20.sol:** Used primarily for **testing purposes** (located under `src/mocks/`). Represents a standard ERC-20 token for test deployment and interactions.

---

## Deployment Scripts
-   Foundry-compatible deployment scripts (`.s.sol`).
-   Example: `script/MockAndRegistry.s.sol` for mock deployment and initial registry setup.
-   Scripts are written to deploy each contract or batch deploy optimized versions.

---

## Environment Variables
The project uses a `.env` file. **Do not commit sensitive keys**. Example file `.env.example`:

```env
# RPC URL of target network
RPC_URL=
# Private key for deployment
PRIVATE_KEY=
# Optional: other network configuration
````

Place your real values in `.env`. This file is ignored in Git (`.gitignore`) for security.

-----

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

-----

## Testing

Tests are written in Foundry (`*.t.sol`).

```bash
# Run all tests
forge test
```

Supports gas snapshots and replays. Ensures all contracts function as expected.

-----

## Usage

Deploy contracts using Foundry scripts:

```bash
forge script script/DeployMockAndRegistry.s.sol --broadcast --rpc-url $RPC_URL -vvvv
```

Interact with deployed contracts using Foundry `cast` or via any front-end. Use `.env` for private key and network RPC URL.

-----

## Project Structure

```
.
├── src/ # Solidity contracts
│   ├── Paymaster.sol
│   ├── SmartAccountMultiSig.sol
│   ├── TreasuryVault.sol
│   └── (Other core and supporting contracts)
├── script/ # Deployment scripts
│   └── MockAndRegistry.s.sol
├── test/ # Foundry tests
├── .env # Sensitive keys (ignored)
├── .env.example # Example env
├── lib/ # Dependencies
├── out/ # Compilation output
├── cache/ # Forge cache
├── README.md
└── .gitignore
```

-----

## Notes

  * Ensure `.env` is configured before deploying.
  * Follow Foundry best practices for testing and gas reporting.
  * All fee calculations are in basis points.
  * MultiSig contract (`SmartAccountMultiSig.sol`) requires threshold signatures for execution.
  * Paymaster contract supports both single and batch sponsorship for ETH/ERC20.
