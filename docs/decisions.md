# AgentPass Architecture & Tech Stack Decisions

This document records the empirical findings, architectural spike results, and finalized technical stack for **AgentPass** on Monad Testnet (Chain ID `10143`).

---

## Chain and tooling

- **Target Network:** Monad Testnet (Chain ID `10143` / `0x279f`).
- **Tooling Suite:**
  - **Foundry:** Version `1.8.4` (`forge`, `cast`).
  - **Solidity:** Version `0.8.28`.
- **Compiler Configuration:**
  - In `contracts/foundry.toml`, `network = "monad"` is set.
  - Foundry 1.8.4 natively recognizes `network = "monad"` and automatically targets the `"prague"` EVM profile with all appropriate compiler defaults.
  - Clean build confirmed: `cd contracts && forge build` compiles cleanly without warnings or manual EVM overrides.
- **RPC Infrastructure:**
  - Configured via environment variable `${QUICKNODE_RPC_URL}` aliased to `monad_testnet` in `contracts/foundry.toml`.
  - Silent loading pattern implemented across scripts (`scripts/check-rpc.sh`, `scripts/deploy-hello.sh`, `scripts/test-fork.sh`) to strip carriage returns (`\r`) and execute read-only RPC calls without leaking or printing URLs or credentials.

---

## P256 result (evidence and gas)

### Verification of EIP-7951 / RIP-7212 Precompile at `0x0000000000000000000000000000000000000100`

The secp256r1 (P-256) signature verification precompile at address `0x0000000000000000000000000000000000000100` was empirically tested on Monad Testnet.

- **Input Specification:** 160 bytes formatted as:
  `hash[32] || r[32] || s[32] || x[32] || y[32]`
- **Key Generation & Test Vector:**
  Generated via standard Node.js crypto (`node:crypto` using `prime256v1` curve and IEEE P1363 raw signature encoding in `scripts/p256-spike.js`):
  - `hash`: `d972c2ac02cc918c29fc1819476a6eed6671118fb0359a9b7a0c4f5fc4b25dd1`
  - `r`: `73299ebdbbcdae49e05f8e0ce305ac0b24988c6fc284ee6569a21dd17beb72f6`
  - `s`: `08202481988e78f2d1047867912416ac2c9ae3a554ee3eca59f02ea0c5f17f90`
  - `x`: `ba3f24fb7b03f2e0720d70984fe1dbeafdc0133b371f6490fe02138b96a4250d`
  - `y`: `e99f23cb34ae6bdb48d2cd43aa8ae67d4271fa16b98fb6501bf41d2ebd0f7116`

### On-Chain Evidence via `cast call`
1. **Valid Signature:**
   ```bash
   cast call 0x0000000000000000000000000000000000000100 0xd972c2ac... --rpc-url monad_testnet
   ```
   **Output:** 32-byte integer with value `1` (Valid signature).

2. **Tampered Hash (First byte altered):**
   ```bash
   cast call 0x0000000000000000000000000000000000000100 0x0072c2ac... --rpc-url monad_testnet
   ```
   **Output:** `0x` (Empty output, Invalid signature).

### Fork Test Gas Measurements
A dedicated fork test was written and executed in `contracts/test/fork/P256Precompile.t.sol`:
- **Valid Signature Staticcall:** `7,293` gas
- **Tampered Signature Staticcall:** `7,224` gas
- **Total Test Execution Gas:** `18,855` gas

*Comparison:* Pure Solidity software implementations of P-256 (such as FCL or Daimo P256) require ~300,000–450,000 gas. Monad's native `0x100` precompile provides a **~98% gas reduction**, enabling sub-cent passkey verification for agent authorization.

---

## Account model (direct vault with passkey owner plus relayer, bundler skipped, why)

### ERC-4337 EntryPoint Evaluation
- Address inspected: `0x4337084d9e255ff0702461cf8895ce9e3b5ff108` on Monad Testnet.
- Result: **Present**. Contract bytecode length is `21,739` bytes (Solc `0.8.28` EntryPoint v0.8 implementation).

### Final Decision: Direct Vault + Passkey Owner + Meta-Transaction Relayer (Bundler Skipped)

Although the EntryPoint v0.8 contract exists on Monad testnet, AgentPass will **skip external ERC-4337 bundler infrastructure** in favor of a **Direct Vault with Passkey/EOA Owner and a lightweight Relayer**.

### Why the Bundler Is Skipped:
1. **Infrastructure Availability & Reliability:** There are no officially managed, highly available ERC-4337 bundlers (Alto, Rundler, Skandha) operating on Monad testnet for hackathon participants. Relying on an unhosted bundler network creates an unnecessary single point of failure.
2. **Unnecessary Complexity & Overhead:** Full ERC-4337 introduces complex `UserOperation` packing, simulation gas constraints, and mempool rule validation. For spending-limit management and autonomous agent execution, this adds latency and developer overhead without user-facing benefits.
3. **Native Direct Vault Execution:**
   - **Direct Execution:** When the AI agent or owner has MON for gas, it calls the `AgentWallet` directly.
   - **Gasless / Sponsored Execution:** When gas sponsorship or passkey signature forwarding is needed, a lightweight Node/TypeScript relayer receives an EIP-712 signed intent and forwards it to `AgentWallet.executeWithSig(...)`.
4. **P-256 Passkey Support:** The vault directly invokes the `0x100` precompile, allowing biometric passkey owners (FaceID, TouchID, YubiKey) to authorize high-value transactions or configure spending limits without maintaining an EOA private key.

---

## ERC-8004 plan

### Identity Registry Investigation
- Address inspected: `0x8004A818BFB912233c491871b3d84c89A494BD9e` on Monad Testnet (Chain ID `10143`).
- Result: **Present and active**.
  - Contract bytecode length: `131` bytes (ERC-1967 Transparent Proxy).
  - Read-only function calls:
    - `name()`: `"AgentIdentity"`
    - `symbol()`: `"AGENT"`

### Integration Strategy:
1. **Canonical Registry Binding:** AgentPass will integrate with `0x8004A818BFB912233c491871b3d84c89A494BD9e` to register agent identities and bind agent vaults to ERC-8004 token IDs.
2. **Interface Abstraction:** The codebase will define `IERC8004IdentityRegistry.sol` to interact with this contract cleanly.
3. **Resilience & Fallback:** If testnet state purges or upgrades occur, the factory contract accepts a configurable registry address, allowing a self-deployed mock/canonical registry fallback if the testnet contract changes.

---

## Fallbacks

1. **P-256 Precompile Fallback:**
   If the `0x100` precompile is disabled or unavailable in future Monad hardforks, the smart contracts are designed with an interchangeable verifier pattern that can fall back to standard EVM cryptographic libraries (e.g. `FreshCryptoLib` / `FCL_elliptic`) with no breaking changes to the vault interface.
2. **RPC Provider Fallbacks:**
   Health checks and scripts support `QUICKNODE_RPC_URL` (Primary), `CROUTON_RPC_URL`, and `BACKUP_RPC_URL`. If the primary endpoint degrades, switching requires only updating `.env` without altering application code.
3. **ERC-8004 Registry Fallback:**
   If the testnet ERC-8004 registry becomes unresponsive or undergoes a breaking upgrade, a self-deployed `AgentIdentity` contract in `contracts/src/` can be deployed idempotently using existing deploy scripts.

---

## Risks

1. **Monad Reserve Balance:**
   Monad enforces a minimum reserve balance requirement for accounts to maintain state and process transactions. Newly deployed agent vaults or relayer accounts with zero balance may encounter failed transactions. Mitigated by funding vaults and relayers with initial bootstrap reserves during provisioning.
2. **Testnet Resets & Ephemeral State:**
   Monad testnet is subject to scheduled resets and state wipes. No hardcoded state or dependencies on persistent addresses are permitted. All deployment and configuration steps are codified in idempotent Foundry scripts (`script/Deploy*.s.sol`).
3. **Spend of Gas by Gas Limit:**
   On Monad, transactions can consume execution gas up to the specified gas limit under certain failure conditions. Relayer services and agent runtimes must implement tight gas estimation buffers rather than submitting arbitrary maximum gas limits.
