# AgentPass TypeScript SDK Specification

## Overview

The `@agentpass/sdk` library provides an ultra-lightweight, zero-friction integration surface for autonomous AI agents, orchestrators (e.g. LangChain, ElizaOS, CrewAI), and backend services operating on Monad Testnet (Chain ID `10143`).

The SDK abstracts raw Web3 transaction serialization, ABI encoding, and policy error parsing into simple asynchronous methods that allow an agent to query its budget and execute policy-bounded micro-transactions in a few lines of code.

---

## SDK Surface Definition

### Types & Enums

```typescript
import { type Address, type Hash, type Hex } from "viem";

export enum PaymentBlockReason {
  NONE = 0,
  PAUSED = 1,
  AGENT_NOT_ACTIVE = 2,
  TARGET_NOT_ALLOWED = 3,
  OVER_DAILY_LIMIT = 4,
  INSUFFICIENT_VAULT_BALANCE = 5,
  ZERO_AMOUNT = 6,
}

export interface SpendingGuardConfig {
  rpcUrl: string;             // Monad RPC endpoint URL
  guardAddress: Address;      // Deployed SpendingGuard contract address
  accountId: Hash;            // Owner passkey account identifier
  agentPrivateKey?: Hex;      // Agent EOA private key for executing payments
}

export interface PaymentParams {
  target: Address;            // Destination recipient or service contract
  amount: bigint;             // Native MON transfer value in wei
  data?: Hex;                 // Optional calldata for smart contract invocation
}

export interface TryPaymentResult {
  success: boolean;           // True if payment executed, false if blocked by policy
  reason: PaymentBlockReason; // Policy code (NONE if successful)
  reasonEnglish: string;      // Human-readable plain English explanation
  txHash?: Hash;              // On-chain transaction hash if submitted
  result?: Hex;               // Call returndata if applicable
}
```

---

## Core Client Interface: `AgentPassClient`

```typescript
export class AgentPassClient {
  /**
   * Initializes the AgentPass client.
   * @param config Network, contract, accountId, and optional agent credentials.
   */
  constructor(config: SpendingGuardConfig);

  /**
   * Executes a strict payment. Reverts with an explanatory error if any
   * spending policy, balance, or target condition is violated.
   * @param params Target address, MON amount in wei, and optional calldata.
   * @returns Transaction hash of confirmed execution.
   */
  async pay(params: PaymentParams): Promise<Hash>;

  /**
   * Non-reverting policy-guarded payment. Catches policy violations gracefully,
   * parses on-chain denial events, and returns a structured result.
   * @param params Target address, MON amount in wei, and optional calldata.
   * @returns Structured result containing success flag and plain English reason.
   */
  async tryPay(params: PaymentParams): Promise<TryPaymentResult>;

  /**
   * Returns the remaining native MON (in wei) the agent is allowed to spend
   * during the current 24-hour UTC window.
   * @param agentAddress Optional agent address override (defaults to client key).
   */
  async remainingToday(agentAddress?: Address): Promise<bigint>;

  /**
   * Checks whether a destination target address is permitted for an agent.
   * Returns false for address(0) or inactive agents; returns true if anyTarget is enabled or target is allowlisted.
   * @param target Destination address to query.
   * @param agentAddress Optional agent address override (defaults to client key).
   */
  async isTargetAllowed(target: Address, agentAddress?: Address): Promise<boolean>;

  /**
   * Updates an agent's daily spending limit via passkey-authorized owner action.
   * @param agent Address of the agent.
   * @param newDailyLimit New limit in wei.
   * @param auth Passkey WebAuthn signature assertion.
   */
  async setDailyLimit(agent: Address, newDailyLimit: bigint, auth: WebAuthnAuth): Promise<Hash>;

  /**
   * Emergency freezes or unfreezes all outgoing payments for the account.
   * @param paused True to freeze, false to unfreeze.
   * @param auth Passkey WebAuthn signature assertion.
   */
  async setPaused(paused: boolean, auth: WebAuthnAuth): Promise<Hash>;

  /**
   * Permanently revokes an agent for the account.
   * @param agent Address of the agent to revoke.
   * @param auth Passkey WebAuthn signature assertion.
   */
  async revokeAgent(agent: Address, auth: WebAuthnAuth): Promise<Hash>;

  /**
   * Withdraws vault funds to a designated recipient. Works even while paused.
   * @param to Destination recipient address.
   * @param amount Amount of native MON in wei.
   * @param auth Passkey WebAuthn signature assertion.
   */
  async withdraw(to: Address, amount: bigint, auth: WebAuthnAuth): Promise<Hash>;

  /**
   * Translates a numeric PaymentBlockReason enum into clear, actionable plain English.
   * @param reason The reason code returned by tryPay or PaymentBlocked event.
   */
  parseReason(reason: PaymentBlockReason): string;
}
```

---

## Plain English Reason Translation

The `parseReason(reason)` utility guarantees understandable, actionable error messages for agent reasoning loops:

| Reason Code | Enum Key | Plain English Explanation |
| --- | --- | --- |
| `0` | `NONE` | "Payment executed successfully." |
| `1` | `PAUSED` | "Account is paused: The owner has temporarily frozen outgoing payments." |
| `2` | `AGENT_NOT_ACTIVE` | "Agent unauthorized: This agent key is not registered or has been revoked." |
| `3` | `TARGET_NOT_ALLOWED` | "Target disallowed: The destination address is not approved in your allowlist." |
| `4` | `OVER_DAILY_LIMIT` | "Daily limit exceeded: This payment exceeds your remaining allowance for today." |
| `5` | `INSUFFICIENT_VAULT_BALANCE` | "Insufficient funds: The vault does not have enough deposited MON to cover this payment." |
| `6` | `ZERO_AMOUNT` | "Invalid amount: Payment amount must be strictly greater than zero." |

---

## 10-Line Usage Example

```typescript
import { AgentPassClient } from "@agentpass/sdk";
import { parseEther } from "viem";

const pass = new AgentPassClient({ rpcUrl: process.env.MONAD_RPC!, guardAddress: "0x1234...5678", accountId: "0xabcd...ef01", agentPrivateKey: process.env.AGENT_KEY! as `0x${string}` });
const remaining = await pass.remainingToday();
console.log(`Agent remaining allowance today: ${remaining} wei`);

const payment = await pass.tryPay({ target: "0x8765...4321", amount: parseEther("0.02") });
if (!payment.success) {
  console.warn(`Payment blocked by policy: ${payment.reasonEnglish}`);
} else {
  console.log(`Payment confirmed! Tx: ${payment.txHash}`);
}
```
