# SpendingGuard Contract Specification

## Overview

`SpendingGuard` is the core smart contract of the AgentPass protocol deployed on Monad Testnet (Chain ID `10143`). It serves as a unified, non-custodial multi-account vault and policy engine for autonomous AI agents. The contract manages native MON deposits, validates owner management actions using WebAuthn passkey signatures via Monad's native P-256 precompile (`0x0100`), and enforces granular spending velocity limits and destination allowlists for autonomous agent callers.

---

## Implementation status

| Component / Functionality | Scope Phase | Status | Details |
| --- | --- | --- | --- |
| Account Creation (`createAccount`) | Phase 7 | Done | Permissionless P-256 account derivation and initialization |
| Vault Deposits (`deposit`, `receive`, `fallback`) | Phase 7 | Done | Native MON deposits; plain transfers rejected to prevent stranding |
| Agent Registration (`addAgent`) | Phase 7 | Done | Owner-authorized agent creation with nonce bumping and digest binding |
| Read Views (`accountOf`, `agentOf`, `nonceOf`, `actionHash`) | Phase 7 | Done | Core state inspection and EIP-712 typed action hashing |
| Spending Velocity & Payments (`pay`, `tryPay`) | Phase 8 | Done | Daily velocity cap enforcement, non-reverting tryPay, and day rollover |
| Destination Target Allowlist (`setTargetAllowed`, `setAnyTarget`, `isTargetAllowed`) | Phase 9 | Done | Per-agent target allowlist permissions, anyTarget toggle, and shared validation |
| Account Lifecycle & Safety (`withdraw`, `setPaused`, `revokeAgent`) | Phase 10 | Planned | Owner withdrawals, emergency freezing, and agent revocation |
| Native WebAuthn P-256 Precompile (`_verifyOwner`) | Phase 14 | Planned | On-chain signature verification via Monad precompile at `0x0100` |

---

## Data Structures

### 1. Enums

#### `PaymentBlockReason`
Categorizes policy denials emitted by `tryPay`:
```solidity
enum PaymentBlockReason {
    NONE,                       // 0: Payment succeeded without policy violation
    PAUSED,                     // 1: Account is currently frozen by owner
    AGENT_NOT_ACTIVE,           // 2: Caller is not an authorized or active agent
    TARGET_NOT_ALLOWED,         // 3: Destination address is not permitted
    OVER_DAILY_LIMIT,           // 4: Requested amount exceeds remaining daily allowance
    INSUFFICIENT_VAULT_BALANCE, // 5: Requested amount exceeds deposited account balance
    ZERO_AMOUNT                 // 6: Payment amount must be strictly greater than zero
}
```

### 2. Structs

#### `WebAuthnAuth`
Contains the WebAuthn signature assertion components passed by the relayer for passkey verification:
```solidity
struct WebAuthnAuth {
    bytes authenticatorData;    // Raw authenticator data bytes
    string clientDataJSON;      // JSON client data string containing challenge and origin
    uint256 challengeIndex;     // Byte offset of the challenge in clientDataJSON
    uint256 typeIndex;          // Byte offset of "type":"webauthn.get" in clientDataJSON
    uint256 r;                  // P-256 signature scalar r
    uint256 s;                  // P-256 signature scalar s
}
```

#### `Account` (Storage Layout: 3 Slots)
Stores the root passkey configuration and deposited capital for a human owner:
```solidity
struct AccountStorage {
    bytes32 qx;                 // Slot 0: P-256 public key x-coordinate (32 bytes)
    bytes32 qy;                 // Slot 1: P-256 public key y-coordinate (32 bytes)
    uint128 balance;            // Slot 2: Deposited native MON balance (16 bytes, offset 0..15)
    uint64 nonce;               // Slot 2: Replay protection counter (8 bytes, offset 16..23)
    bool paused;                // Slot 2: Emergency freeze toggle (1 byte, offset 24)
}
```

#### `Agent` (Storage Layout: 2 Slots)
Stores the authorization and spending metrics for an AI agent:
```solidity
struct AgentStorage {
    uint128 dailyLimit;         // Slot 0: Maximum native MON spendable per 24h day (16 bytes, offset 0..15)
    uint128 spentToday;         // Slot 0: Cumulative native MON spent today (16 bytes, offset 16..31)
    uint64 dayIndex;            // Slot 1: Day index: block.timestamp / 1 days (8 bytes, offset 0..7)
    bool active;                // Slot 1: True if agent is authorized to transact (1 byte, offset 8)
    bool anyTarget;             // Slot 1: True if target allowlist is bypassed (1 byte, offset 9)
}
```

### 3. Storage Layout

The contract maintains three core mappings:
- `mapping(bytes32 => AccountStorage) internal _accounts;`  
  Maps `accountId` to the owner's `AccountStorage` record.
- `mapping(bytes32 => mapping(address => AgentStorage)) internal _agents;`  
  Maps `accountId` and `agent` EOA address to the `AgentStorage` policy record.
- `mapping(bytes32 => mapping(address => mapping(address => bool))) internal _targetAllowlist;`  
  Maps `accountId`, `agent`, and destination `target` address to permission flag.

---

## Digest Format for Owner Actions

All owner actions (`addAgent`, `setDailyLimit`, `setTargetAllowed`, `setAnyTarget`, `revokeAgent`, `setPaused`, `withdraw`) require a WebAuthn passkey signature. The signed digest is constructed using EIP-712 structured data hashing to ensure strict domain separation and replay protection.

### Domain Separator
```
EIP712Domain(
    string name = "AgentPass SpendingGuard",
    string version = "1",
    uint256 chainId = 10143,
    address verifyingContract = address(SpendingGuard)
)
```

### TypeHash and Digest Derivation
```solidity
bytes32 public constant ACTION_TYPEHASH = keccak256(
    "SpendingGuardAction(bytes32 accountId,uint64 nonce,bytes4 actionSelector,bytes params)"
);

function actionHash(
    bytes32 accountId,
    uint64 nonce,
    bytes4 actionSelector,
    bytes memory params
) public view returns (bytes32 digest) {
    bytes32 structHash = keccak256(
        abi.encode(
            ACTION_TYPEHASH,
            accountId,
            nonce,
            actionSelector,
            keccak256(params)
        )
    );
    digest = keccak256(
        abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
    );
}
```

### WebAuthn Verification Pipeline
1. The client Web Application computes `digest = actionHash(...)`.
2. The browser passes `challenge = digest` to `navigator.credentials.get()`.
3. The hardware authenticator verifies user presence/biometrics and returns `authenticatorData`, `clientDataJSON`, and signature `(r, s)`.
4. `SpendingGuard._verifyOwner` performs:
   - Validates that `clientDataJSON` contains `digest` at `challengeIndex`.
   - Computes `clientDataHash = sha256(bytes(clientDataJSON))`.
   - Computes `signedMessageHash = sha256(abi.encodePacked(authenticatorData, clientDataHash))`.
   - Verifies canonical low-s ($s \le n/2$).
   - Invokes Monad's P-256 precompile at `0x0000000000000000000000000000000000000100` via `staticcall` with input `(signedMessageHash, r, s, qx, qy)`.
   - Asserts return code is `1`.
5. The account's `nonce` is incremented upon successful verification.

---

## Functions Specification

### 1. `createAccount`
```solidity
function createAccount(bytes32 qx, bytes32 qy) external returns (bytes32 accountId);
```
- **Inputs:** `qx`, `qy` (P-256 public key coordinates).
- **Caller:** Anyone (permissionless; typically relayer or owner browser).
- **Checks:**
  - `qx != 0 && qy != 0`.
  - `_accounts[accountId].qx == 0` (reverts with `AccountAlreadyExists(accountId)` if already registered).
- **State Changes:**
  - `accountId = keccak256(abi.encode(qx, qy))`.
  - Initializes `_accounts[accountId]` with `qx`, `qy`, `balance = 0`, `nonce = 0`, `paused = false`.
- **Events:** `AccountCreated(accountId, qx, qy)`.
- **Errors:** `AccountAlreadyExists`.

### 2. `deposit`
```solidity
function deposit(bytes32 accountId) external payable;
```
- **Inputs:** `accountId`. `msg.value` contains native MON.
- **Caller:** Anyone (owner, agent, sponsor, or faucet).
- **Checks:**
  - `_accounts[accountId].qx != 0` (reverts with `AccountNotFound(accountId)` if unregistered).
  - `msg.value > 0` (reverts with `ZeroAmount()`).
- **State Changes:**
  - `_accounts[accountId].balance += msg.value`.
- **Events:** `Deposited(accountId, msg.sender, msg.value)`.
- **Errors:** `AccountNotFound`, `ZeroAmount`.

### 3. `addAgent`
```solidity
function addAgent(
    bytes32 accountId,
    address agent,
    uint128 dailyLimit,
    bool anyTarget,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `agent` address, `dailyLimit` (wei), `anyTarget` flag, WebAuthn `auth` struct.
- **Caller:** Anyone (typically relayer submitting owner action).
- **Checks:**
  - Account exists and is not paused.
  - `agent != address(0)`.
  - Validates passkey signature via `_verifyOwner(accountId, nonce, selector, params, auth)`.
- **State Changes:**
  - `_accounts[accountId].nonce++`.
  - `_agents[accountId][agent] = Agent({ active: true, dailyLimit: dailyLimit, spentToday: 0, dayIndex: uint64(block.timestamp / 1 days), anyTarget: anyTarget })`.
- **Events:** `AgentAdded(accountId, agent, dailyLimit, anyTarget)`.
- **Errors:** `AccountNotFound`, `AccountPaused`, `InvalidNonce`, `InvalidSignature`.

### 4. `setDailyLimit`
```solidity
function setDailyLimit(
    bytes32 accountId,
    address agent,
    uint128 newDailyLimit,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `agent`, `newDailyLimit`, `auth`.
- **Caller:** Anyone (relayer with valid owner signature).
- **Checks:**
  - Account exists and not paused; agent exists.
  - Validates owner signature and increments nonce.
- **State Changes:**
  - Updates `dailyLimit = newDailyLimit`.
- **Events:** `DailyLimitUpdated(accountId, agent, oldLimit, newDailyLimit)`.
- **Errors:** `AccountNotFound`, `AccountPaused`, `UnauthorizedAgent`, `InvalidNonce`, `InvalidSignature`.

### 5. `setTargetAllowed`
```solidity
function setTargetAllowed(
    bytes32 accountId,
    address agent,
    address target,
    bool allowed,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `agent`, `target`, `allowed`, `auth`.
- **Caller:** Anyone (relayer with valid owner passkey signature).
- **Checks:**
  - Account exists (`AccountNotFound`).
  - Agent is active for account (`UnauthorizedAgent`).
  - Destination target is non-zero (`InvalidTarget` if `target == address(0)`).
  - Validates EIP-712 owner signature over `(agent, target, allowed)` digest and increments nonce.
- **State Changes:**
  - `_targetAllowlist[accountId][agent][target] = allowed`.
- **Idempotence:** Setting the same value again does NOT revert; verifies signature, bumps nonce, and emits event.
- **Events:** `TargetAllowedSet(accountId, agent, target, allowed)`.
- **Errors:** `AccountNotFound`, `UnauthorizedAgent`, `InvalidTarget`, `InvalidNonce`, `InvalidSignature`.

### 6. `setAnyTarget`
```solidity
function setAnyTarget(
    bytes32 accountId,
    address agent,
    bool anyTarget,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `agent`, `anyTarget`, `auth`.
- **Caller:** Anyone (relayer with valid owner passkey signature).
- **Checks:**
  - Account exists (`AccountNotFound`).
  - Agent is active for account (`UnauthorizedAgent`).
  - Validates EIP-712 owner signature over `(agent, anyTarget)` digest and increments nonce.
- **State Changes:**
  - `_agents[accountId][agent].anyTarget = anyTarget`.
- **Idempotence:** Setting the same value again does NOT revert; verifies signature, bumps nonce, and emits event.
- **Events:** `AnyTargetSet(accountId, agent, anyTarget)`.
- **Errors:** `AccountNotFound`, `UnauthorizedAgent`, `InvalidNonce`, `InvalidSignature`.

### 7. `revokeAgent`
```solidity
function revokeAgent(
    bytes32 accountId,
    address agent,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `agent`, `auth`.
- **Caller:** Anyone (relayer with valid owner signature).
- **Checks:**
  - Account exists; agent is active.
  - Validates owner signature and increments nonce.
- **State Changes:**
  - `_agents[accountId][agent].active = false`.
- **Events:** `AgentRevoked(accountId, agent)`.
- **Errors:** `AccountNotFound`, `UnauthorizedAgent`, `InvalidNonce`, `InvalidSignature`.

### 7. `setPaused`
```solidity
function setPaused(
    bytes32 accountId,
    bool paused,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `paused`, `auth`.
- **Caller:** Anyone (relayer with valid owner signature).
- **Checks:**
  - Account exists.
  - Validates owner signature and increments nonce.
- **State Changes:**
  - `_accounts[accountId].paused = paused`.
- **Events:** `PausedSet(accountId, paused)`.
- **Errors:** `AccountNotFound`, `InvalidNonce`, `InvalidSignature`.

### 8. `withdraw`
```solidity
function withdraw(
    bytes32 accountId,
    address payable recipient,
    uint256 amount,
    WebAuthnAuth calldata auth
) external;
```
- **Inputs:** `accountId`, `recipient`, `amount`, `auth`.
- **Caller:** Anyone (relayer with valid owner signature).
- **Checks:**
  - Account exists; `recipient != address(0)`; `amount > 0`.
  - `_accounts[accountId].balance >= amount` (reverts with `InsufficientBalance`).
  - Validates owner signature and increments nonce.
- **State Changes:**
  - `_accounts[accountId].balance -= amount`.
  - Transfers `amount` native MON to `recipient` using low-level `.call{value: amount}("")`.
  - Reverts with `PaymentTransferFailed()` if transfer fails.
- **Events:** `Withdrawn(accountId, recipient, amount)`.
- **Errors:** `AccountNotFound`, `InsufficientBalance`, `PaymentTransferFailed`, `InvalidNonce`, `InvalidSignature`.

### 9. `pay`
```solidity
function pay(
    bytes32 accountId,
    address payable target,
    uint256 amount,
    bytes calldata data
) external returns (bytes memory result);
```
- **Inputs:** `accountId`, `target`, `amount`, `data`.
- **Caller:** Strict: `msg.sender == agent` (must be active agent for `accountId`).
- **Checks (Strict - Evaluates `_checkPay` and reverts with matching custom error):**
  1. `amount == 0` -> reverts `ZeroAmount()`.
  2. Agent not active for account (`!_agents[accountId][agent].active`, covers unknown accounts) -> reverts `UnauthorizedAgent(accountId, agent)`.
  3. Account paused (`_accounts[accountId].paused`) -> reverts `AccountPaused(accountId)`.
  4. Target not allowed (`to == address(0)` OR `(!anyTarget && !_targetAllowlist[accountId][agent][to])`) -> reverts `TargetNotAllowed(accountId, agent, target)`.
  5. Over daily limit (`effectiveSpent + amount > dailyLimit`) -> reverts `DailyLimitExceeded(...)`.
  6. Insufficient vault balance (`amount > balance`) -> reverts `InsufficientBalance(...)`.
- **State Changes:**
  - If `agent.dayIndex != today`: sets `dayIndex = today`, resets `spentToday = 0`.
  - `_agents[accountId][msg.sender].spentToday += uint128(amount)`.
  - `_accounts[accountId].balance -= uint128(amount)`.
  - Executes call: `(bool ok, bytes memory res) = target.call{value: amount}(data)`.
  - Asserts `ok` (reverts with `PaymentTransferFailed()`).
- **Events:** `PaymentExecuted(accountId, msg.sender, target, amount)`.
- **Errors:** Custom errors above.

### 10. `tryPay`
```solidity
function tryPay(
    bytes32 accountId,
    address payable target,
    uint256 amount,
    bytes calldata data
) external returns (bool success, PaymentBlockReason reason, bytes memory result);

function tryPay(
    bytes32 accountId,
    address payable target,
    uint256 amount
) external returns (bool ok, PaymentBlockReason reason);
```
- **Inputs:** `accountId`, `target`, `amount`, optional `data`.
- **Caller:** `msg.sender == agent`.
- **Checks (Non-Reverting Policy Verification):**
  - Runs `_checkPay(accountId, msg.sender, target, amount)`.
  - If `reason != PaymentBlockReason.NONE`:
    - Does NOT revert and does NOT change any state.
    - Emits `PaymentBlocked(accountId, msg.sender, target, amount, reason)`.
    - Returns `(false, reason, "")` (or `(false, reason)` for 3-arg overload).
  - Reverts ONLY for reentrancy (`ReentrancyGuardReentrantCall`) or physical MON transfer failure (`PaymentTransferFailed`).
- **State Changes:**
  - If approved: updates `spentToday` and `balance` following CEI, transfers native MON, emits `PaymentExecuted`, and returns `(true, PaymentBlockReason.NONE, result)`.
- **Events:** `PaymentExecuted` (on success) OR `PaymentBlocked` (on policy block).

### Authoritative Check Order Table (`_checkPay`)

The internal view function `_checkPay(bytes32 accountId, address agent, address to, uint256 amount)` evaluates transaction safety in strict, deterministic order returning `PaymentBlockReason`:

| Order | Check Condition | Failing Condition | Reason Code (`PaymentBlockReason`) | Revert Error on `pay` |
| --- | --- | --- | --- | --- |
| 1 | Non-zero amount | `amount == 0` | `ZERO_AMOUNT` | `ZeroAmount()` |
| 2 | Agent active for account | `!_agents[accountId][agent].active` (covers unknown account) | `AGENT_NOT_ACTIVE` | `UnauthorizedAgent(accountId, agent)` |
| 3 | Account unpaused | `_accounts[accountId].paused` | `PAUSED` | `AccountPaused(accountId)` |
| 4 | Destination allowed | `to == address(0)` OR `(!anyTarget && !_targetAllowlist[accountId][agent][to])` | `TARGET_NOT_ALLOWED` | `TargetNotAllowed(accountId, agent, to)` |
| 5 | Daily spending velocity | `amount > dailyLimit` OR `effectiveSpent + amount > dailyLimit` | `OVER_DAILY_LIMIT` | `DailyLimitExceeded(accountId, agent, req, remaining)` |
| 6 | Vault balance solvency | `amount > _accounts[accountId].balance` | `INSUFFICIENT_VAULT_BALANCE` | `InsufficientBalance(accountId, amount, balance)` |

#### Target Zero-Address Disallow Rule
`to == address(0)` is **ALWAYS disallowed**, even if `anyTarget == true`. Autonomous agents cannot accidentally or maliciously transfer vault funds to the burn address `address(0)`.

#### Lazy Daily Reset
The 24-hour spending window is calculated on-demand (lazy evaluation):
- `today = uint64(block.timestamp / 1 days)` (UTC midnight boundary).
- `effectiveSpent = (agent.dayIndex == today) ? agent.spentToday : 0`.
- In `_executePay`, if `agent.dayIndex != today`, the contract atomically sets `agent.dayIndex = today` and resets `agent.spentToday = 0` before adding the payment amount. No periodic cron jobs or background ticks are required.
- `remainingToday(accountId, agent)` returns `0` if the agent is inactive; otherwise returns `dailyLimit - effectiveSpent`, floored at `0` (preventing underflow if the owner lowers `dailyLimit` mid-day below what was already spent).

### 11–16. View Functions

- `accountOf(bytes32 accountId)`: Returns `(bytes32 qx, bytes32 qy, uint256 balance, uint64 nonce, bool paused)`.
- `agentOf(bytes32 accountId, address agent)`: Returns `(bool active, uint128 dailyLimit, uint128 spentToday, uint64 dayIndex, bool anyTarget)`.
- `remainingToday(bytes32 accountId, address agent)`: Returns available spending capacity in wei, accounting for 24h rollover dynamically.
- `isTargetAllowed(bytes32 accountId, address agent, address target)`: Returns false for address(0) or inactive agent; otherwise returns agent.anyTarget || allowlist entry. Identical shared validation logic as pay and tryPay.
- `nonceOf(bytes32 accountId)`: Returns current owner nonce.
- `actionHash(bytes32 accountId, uint64 nonce, bytes4 actionSelector, bytes memory params)`: Returns 32-byte typed digest.

---

## Daily-Limit Window Logic and Edge Cases

### Time Calculation
The current day window is derived using UTC integer division:
```solidity
uint64 currentDay = uint64(block.timestamp / 1 days);
```

### Rollover Logic
When an agent attempts a transaction (`pay` or `tryPay`), the contract checks:
```solidity
if (currentDay > agent.dayIndex) {
    agent.spentToday = 0;
    agent.dayIndex = currentDay;
}
```
In view functions (`remainingToday`):
```solidity
if (currentDay > agent.dayIndex) {
    return agent.dailyLimit;
} else if (agent.spentToday >= agent.dailyLimit) {
    return 0;
} else {
    return agent.dailyLimit - agent.spentToday;
}
```

### Edge Cases

1. **Day Rollover:**
   - At `00:00:00 UTC`, `block.timestamp / 1 days` increments.
   - The very first transaction in the new day resets `spentToday` to `0` and updates `dayIndex`.
   - The agent immediately has access to its full `dailyLimit`.

2. **Limit Lowered Mid-Day:**
   - Owner updates `dailyLimit` from $L_{old}$ to $L_{new}$ where $L_{new} < \text{spentToday}$.
   - The contract updates `agent.dailyLimit = newLimit` without altering `spentToday`.
   - In subsequent checks: `spentToday + amount <= newDailyLimit` evaluates to false.
   - `remainingToday` returns `0` (protected against underflow via conditional check).
   - Agent is blocked from any further spending until the next UTC day rollover.

3. **Limit Raised Mid-Day:**
   - Owner updates `dailyLimit` from $L_{old}$ to $L_{new}$ where $L_{new} > L_{old}$.
   - The agent's available capacity expands immediately: $\text{remaining} = L_{new} - \text{spentToday}$.

4. **Zero Limit Assigned:**
   - Setting `dailyLimit = 0` effectively pauses an individual agent's spending privileges without de-registering or altering its allowlist.

---

## Demo script

The following scenario validates budget enforcement, non-reverting `tryPay` handling, and cumulative daily limits using exact test values:

### Scenario Parameters
- Vault deposited balance: **`0.1 MON`**
- Agent configured daily limit: **`0.05 MON`**

### Step-by-Step Execution Walkthrough

```
+-----------------------------------------------------------------------------------------------+
| Step | Action                 | Amount   | Checks & Invariants             | Outcome / Result |
+------+------------------------+----------+---------------------------------+------------------+
| 0    | deposit                | 0.1 MON  | Vault balance initialized       | Balance = 0.1    |
|      | addAgent               | 0.05 MON | Agent limit = 0.05 MON          | Limit = 0.05     |
+------+------------------------+----------+---------------------------------+------------------+
| 1    | agent.pay(...)         | 0.02 MON | 0.02 <= 0.05 limit [PASS]       | Succeeded        |
|      |                        |          | 0.02 <= 0.1 balance [PASS]      | Spent = 0.02     |
|      |                        |          |                                 | Remain = 0.03    |
|      |                        |          |                                 | Balance = 0.08   |
+------+------------------------+----------+---------------------------------+------------------+
| 2    | agent.tryPay(...)      | 0.06 MON | 0.02 + 0.06 = 0.08 > 0.05 limit | BLOCKED          |
|      |                        |          | Exceeds dailyLimit [FAIL]       | Reason:          |
|      |                        |          | Emits PaymentBlocked            | OVER_DAILY_LIMIT |
|      |                        |          | DOES NOT REVERT                 | Spent = 0.02     |
|      |                        |          | Returns (false, OVER_..., "")   | Remain = 0.03    |
+------+------------------------+----------+---------------------------------+------------------+
| 3    | agent.pay(...)         | 0.02 MON | Cumulative: 0.02 + 0.02 = 0.04  | Succeeded        |
|      |                        |          | 0.04 <= 0.05 limit [PASS]       | Spent = 0.04     |
|      |                        |          | 0.02 <= 0.08 balance [PASS]     | Remain = 0.01    |
|      |                        |          |                                 | Balance = 0.06   |
+------+------------------------+----------+---------------------------------+------------------+
| 4    | agent.tryPay(...)      | 0.02 MON | Cumulative: 0.04 + 0.02 = 0.06  | BLOCKED          |
|      |                        |          | 0.06 > 0.05 limit [FAIL]        | Reason:          |
|      |                        |          | Proves cumulative daily total   | OVER_DAILY_LIMIT |
|      |                        |          | Returns (false, OVER_..., "")   | Spent = 0.04     |
+-----------------------------------------------------------------------------------------------+
```

---

## Threat model

### 1. Replay Attacks
- **Risk:** An attacker or malicious relayer captures a valid owner WebAuthn signature and replays it to alter limits or drain funds.
- **Mitigation:** Every owner action commits to a sequential, monotonically increasing account `nonce` in its typed digest. The contract increments `_accounts[accountId].nonce` during execution. Any replayed signature produces an immediate `InvalidNonce` revert. Furthermore, the digest commits to `chainId` (`10143`) and `verifyingContract`, preventing cross-chain and cross-contract replays.

### 2. Signature Malleability
- **Risk:** In ECDSA/P-256 signatures, $(r, s)$ and $(r, -s \pmod n)$ are both valid mathematically.
- **Mitigation:** The precompile verification verifies canonical low-$s$ values ($s \le n/2$). Replay of a malleable signature variant fails because the underlying nonce is consumed upon first execution.

### 3. Front-Running `createAccount`
- **Risk:** An attacker observes an owner's `createAccount(qx, qy)` transaction in the mempool and front-runs it.
- **Mitigation:** **Harmless by design.** The account identifier is computed as `accountId = keccak256(abi.encode(qx, qy))`. The account state is permanently tied to the owner's passkey coordinates `(qx, qy)`. A front-runner merely deploys the owner's account for them, paying the deployment gas. The attacker gains zero administrative or spending privileges because only signatures verified against `(qx, qy)` can execute owner actions.

### 4. Reentrancy via Native MON Transfer
- **Risk:** When `pay`, `tryPay`, or `withdraw` transfers native MON to a recipient contract, the recipient's `receive()` or `fallback()` hook executes and attempts to re-enter `SpendingGuard`.
- **Mitigation:**
  - OpenZeppelin `ReentrancyGuard` pattern applied across all external transfer pathways.
  - Strict **Checks-Effects-Interactions (CEI)** pattern: state variables (`balance`, `spentToday`, `nonce`) are decremented and persisted *before* low-level calls are triggered.

### 5. Pooled Funds Risk
- **Risk:** In a multi-account single-contract architecture, an arithmetic bug or reentrancy might allow Account A to spend funds deposited by Account B.
- **Mitigation:** Account balances are partitioned in separate storage slots by `accountId`. Balance deductions are strictly bounded: `balance >= amount`. Invariant testing in Foundry guarantees contract native MON balance $\ge \sum \text{balances}$.

### 6. Relayer Compromise
- **Risk:** The relayer service is hacked or runs malicious code.
- **Mitigation:** Relayers are untrusted message couriers. The relayer cannot alter function parameters or destination addresses without invalidating the owner's P-256 cryptographic signature. Censorship by a relayer is defeated by submitting transactions directly or routing through alternate relayers.

### 7. Agent Key Compromise
- **Risk:** An autonomous AI agent server is compromised, prompt-injected, or leaks its EOA private key.
- **Mitigation:**
  - The attacker cannot access or withdraw the owner's vault capital.
  - Losses are strictly bounded to the remaining `dailyLimit` for that specific day and to addresses on the agent's allowlist.
  - The owner can immediately invoke `revokeAgent` or `setPaused` using their hardware passkey.

### 8. Griefing via Spam Deposits
- **Risk:** A malicious third party spams `deposit(accountId)` calls.
- **Mitigation:** Inbound deposits only increase the victim's vault balance. The attacker burns their own gas and native MON to donate funds to the target account.

---

## Error codes

| Error Identifier | Type | Condition |
| --- | --- | --- |
| `AccountAlreadyExists(bytes32 accountId)` | Custom Error | Calling `createAccount` with coordinates of an existing account |
| `AccountNotFound(bytes32 accountId)` | Custom Error | Referencing an uninitialized `accountId` |
| `AccountPaused(bytes32 accountId)` | Custom Error | Attempting payment or configuration while account is paused |
| `InvalidSignature()` | Custom Error | WebAuthn P-256 signature verification failed |
| `InvalidNonce(uint64 expected, uint64 provided)` | Custom Error | Replay protection nonce does not match current account nonce |
| `UnauthorizedAgent(bytes32 accountId, address agent)` | Custom Error | Caller is not an active agent authorized for the account |
| `TargetNotAllowed(bytes32 accountId, address agent, address target)` | Custom Error | Target address is not in allowlist and `anyTarget` is false |
| `DailyLimitExceeded(bytes32 accountId, address agent, uint128 requested, uint128 available)` | Custom Error | Payment amount exceeds remaining 24-hour spending capacity in `pay()` |
| `InsufficientBalance(bytes32 accountId, uint256 requested, uint256 available)` | Custom Error | Amount exceeds deposited account vault balance |
| `ZeroAmount()` | Custom Error | Attempting to deposit, pay, or withdraw 0 wei |
| `PaymentTransferFailed()` | Custom Error | Low-level native MON `.call{value: ...}` transfer failed |
| `ReentrancyGuardReentrantCall()` | Custom Error | Detected reentrant invocation |
| `PaymentBlockReason.PAUSED` | Reason Enum | `tryPay`: Account is frozen |
| `PaymentBlockReason.AGENT_NOT_ACTIVE` | Reason Enum | `tryPay`: Caller is not an active agent |
| `PaymentBlockReason.TARGET_NOT_ALLOWED` | Reason Enum | `tryPay`: Target destination disallowed |
| `PaymentBlockReason.OVER_DAILY_LIMIT` | Reason Enum | `tryPay`: Amount exceeds remaining daily allowance |
| `PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE` | Reason Enum | `tryPay`: Vault has insufficient deposited MON |
| `PaymentBlockReason.ZERO_AMOUNT` | Reason Enum | `tryPay`: Payment amount requested was zero |

---

## Out of scope

The following items are deliberately excluded from the MVP scope:
1. **ERC-20 Token Allowances:** The MVP is strictly native MON. Multi-token ERC-20 spending policies are scheduled as a post-hackathon enhancement.
2. **On-Contract ERC-8004 Identity Registration:** Decoupled from the core `SpendingGuard` contract to maintain modularity. Agent identity registration will be handled via dedicated factory wrappers.
3. **Agent Reputation Scoring:** Subjective credit and behavioral metrics are handled off-chain or by higher-level governance layers.
4. **Contract Upgradeability:** `SpendingGuard` is intentionally immutable. No upgradeable proxy patterns (UUPS/Transparent) are used to prevent centralized administrative control and ensure trustless execution.
5. **Multi-Owner / Multi-Passkey Thresholds:** Accounts are controlled by a single root P-256 passkey. Multi-signature passkey quorums are deferred to v2.
