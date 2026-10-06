# SpendingGuard Foundry Test Plan (Phase 11 Implementation)

## Overview

This test plan defines the comprehensive Foundry test matrix for `SpendingGuard` to be implemented in Phase 11. The test suite enforces 100% branch and function coverage across policy evaluation, cryptographic passkey verification via the Monad P-256 precompile (`0x0100`), daily rollover math, non-reverting `tryPay` behaviors, reentrancy guards, and fuzz/invariant properties.

---

## Numbered Test Matrix

### Suite 1: Account Lifecycle & Vault Deposits (`SpendingGuardLifecycleTest`)

1. **`test_01_createAccount_happyPath`**  
   - Validates that `createAccount(qx, qy)` deterministically derives `accountId = keccak256(abi.encode(qx, qy))`.
   - Asserts stored state: `qx`, `qy`, `balance = 0`, `nonce = 0`, `paused = false`.
   - Asserts emission of `AccountCreated(accountId, qx, qy)`.

2. **`test_02_createAccount_revert_alreadyExists`**  
   - Calling `createAccount` a second time with identical `(qx, qy)` coordinates reverts with `AccountAlreadyExists(accountId)`.

3. **`test_03_createAccount_revert_zeroCoordinates`**  
   - Calling `createAccount` with `qx == 0` or `qy == 0` reverts.

4. **`test_04_deposit_happyPath`**  
   - Anyone deposits native MON to `deposit(accountId)`.
   - Asserts account vault balance increments by `msg.value`.
   - Asserts emission of `Deposited(accountId, msg.sender, msg.value)`.

5. **`test_05_deposit_revert_accountNotFound`**  
   - Depositing to an uninitialized `accountId` reverts with `AccountNotFound(accountId)`.

6. **`test_06_deposit_revert_zeroAmount`**  
   - Sending a transaction to `deposit` with `msg.value == 0` reverts with `ZeroAmount()`.

---

### Suite 2: Owner Passkey Authorization & Nonce Mechanics (`SpendingGuardAuthTest`)

7. **`test_07_ownerAction_validP256Signature`**  
   - Generates a valid secp256r1 signature test vector for `addAgent`.
   - Submits through relayer; verifies staticcall to Monad P-256 precompile at `0x0100` succeeds.
   - Asserts account `nonce` increments from `0` to `1`.

8. **`test_08_ownerAction_revert_invalidSignature`**  
   - Modifies signature bytes `(r, s)` or client challenge.
   - Asserts execution reverts with `InvalidSignature()`.

9. **`test_09_ownerAction_revert_replayNonce`**  
   - Submits a previously executed WebAuthn signature payload with an old nonce.
   - Asserts execution reverts with `InvalidNonce(expected, provided)`.

10. **`test_10_ownerAction_revert_wrongChainDigest`**  
    - Signs digest computed with a mismatched chain ID (e.g. `1` instead of `10143`).
    - Asserts execution reverts with `InvalidSignature()`.

11. **`test_11_ownerAction_revert_wrongAccountId`**  
    - Signs digest specifying Account A; submits payload against Account B.
    - Asserts execution reverts with `InvalidSignature()`.

12. **`test_12_ownerAction_revert_wrongActionSelector`**  
    - Signs digest for `setDailyLimit`; submits payload calling `withdraw`.
    - Asserts execution reverts with `InvalidSignature()`.

13. **`test_13_ownerAction_revert_signatureMalleabilityHighS`**  
    - Passes signature scalar with high-$s$ ($s > n/2$).
    - Asserts precompile / verifier rejects malleable signature variant.

---

### Suite 3: Agent Configuration & Policy Management (`SpendingGuardPolicyTest`)

14. **`test_14_addAgent_happyPath`**  
    - Owner registers agent EOA with `dailyLimit = 0.05 MON` and `anyTarget = false`.
    - Asserts agent is marked `active = true`, `dayIndex = block.timestamp / 1 days`.
    - Asserts emission of `AgentAdded(accountId, agent, dailyLimit, anyTarget)`.

15. **`test_15_setDailyLimit_happyPath`**  
    - Owner updates daily limit from `0.05 MON` to `0.10 MON`.
    - Asserts emission of `DailyLimitUpdated(accountId, agent, 0.05 ether, 0.10 ether)`.

16. **`test_16_setTargetAllowed_happyPath`**  
    - Owner approves target address `0xTarget`.
    - Asserts `isTargetAllowed(accountId, agent, 0xTarget)` returns `true`.
    - Asserts emission of `TargetAllowedSet(accountId, agent, 0xTarget, true)`.

17. **`test_17_revokeAgent_happyPath`**  
    - Owner calls `revokeAgent(accountId, agent)`.
    - Asserts `agentOf(accountId, agent).active` becomes `false`.
    - Asserts emission of `AgentRevoked(accountId, agent)`.

18. **`test_18_setPaused_emergencyFreeze`**  
    - Owner toggles `setPaused(accountId, true)`.
    - Asserts `accountOf(accountId).paused == true`.
    - Asserts emission of `PausedSet(accountId, true)`.

19. **`test_19_withdraw_happyPath`**  
    - Owner withdraws `0.05 MON` from a `0.1 MON` balance to recipient address.
    - Asserts recipient native MON balance increases; vault balance decrements.
    - Asserts emission of `Withdrawn(accountId, recipient, 0.05 ether)`.

20. **`test_20_withdraw_revert_insufficientBalance`**  
    - Owner attempts to withdraw `0.2 MON` when balance is `0.1 MON`.
    - Asserts execution reverts with `InsufficientBalance(accountId, 0.2 ether, 0.1 ether)`.

---

### Suite 4: Strict `pay()` Execution & Policy Reverts (`SpendingGuardPayTest`)

21. **`test_21_pay_happyPath`**  
    - Active agent invokes `pay(accountId, target, 0.02 MON, "")`.
    - Asserts target receives 0.02 MON native transfer.
    - Asserts `balance` decrements by 0.02 MON; `spentToday` increments by 0.02 MON.
    - Asserts emission of `PaymentExecuted(accountId, agent, target, 0.02 ether)`.

22. **`test_22_pay_revert_unauthorizedAgent`**  
    - Unregistered EOA calls `pay()`.
    - Asserts revert with `UnauthorizedAgent(accountId, caller)`.

23. **`test_23_pay_revert_accountPaused`**  
    - Agent calls `pay()` while account is paused.
    - Asserts revert with `AccountPaused(accountId)`.

24. **`test_24_pay_revert_targetNotAllowed`**  
    - Agent calls `pay()` to unlisted destination when `anyTarget == false`.
    - Asserts revert with `TargetNotAllowed(accountId, agent, target)`.

25. **`test_25_pay_revert_dailyLimitExceeded`**  
    - Agent with daily limit `0.05 MON` calls `pay()` for `0.06 MON`.
    - Asserts revert with `DailyLimitExceeded(accountId, agent, 0.06 ether, 0.05 ether)`.

26. **`test_26_pay_revert_insufficientVaultBalance`**  
    - Vault balance is `0.01 MON`, daily limit is `0.05 MON`. Agent attempts to pay `0.02 MON`.
    - Asserts revert with `InsufficientBalance(accountId, 0.02 ether, 0.01 ether)`.

27. **`test_27_pay_revert_zeroAmount`**  
    - Agent calls `pay()` with `amount == 0`.
    - Asserts revert with `ZeroAmount()`.

---

### Suite 5: Graceful `tryPay()` Execution & Event Emission (`SpendingGuardTryPayTest`)

28. **`test_28_tryPay_withinLimit_succeeds`**  
    - Agent calls `tryPay(accountId, target, 0.02 MON, "")`.
    - Asserts returns `(true, PaymentBlockReason.NONE, "")`.
    - Asserts emission of `PaymentExecuted`.

29. **`test_29_tryPay_overLimit_blockedWithoutReverting`**  
    - Agent with `0.05 MON` limit calls `tryPay()` for `0.06 MON`.
    - **CRITICAL:** Transaction does NOT revert.
    - Asserts returns `(false, PaymentBlockReason.OVER_DAILY_LIMIT, "")`.
    - Asserts emission of `PaymentBlocked(accountId, agent, target, 0.06 ether, OVER_DAILY_LIMIT)`.
    - Asserts `spentToday` remains unchanged.

30. **`test_30_tryPay_paused_blockedWithoutReverting`**  
    - Account is paused. Agent calls `tryPay()`.
    - Asserts returns `(false, PaymentBlockReason.PAUSED, "")`.
    - Asserts emission of `PaymentBlocked(..., PAUSED)`.

31. **`test_31_tryPay_unauthorized_blockedWithoutReverting`**  
    - Non-agent caller invokes `tryPay()`.
    - Asserts returns `(false, PaymentBlockReason.AGENT_NOT_ACTIVE, "")`.
    - Asserts emission of `PaymentBlocked(..., AGENT_NOT_ACTIVE)`.

32. **`test_32_tryPay_targetDisallowed_blockedWithoutReverting`**  
    - Target not in allowlist. Agent calls `tryPay()`.
    - Asserts returns `(false, PaymentBlockReason.TARGET_NOT_ALLOWED, "")`.
    - Asserts emission of `PaymentBlocked(..., TARGET_NOT_ALLOWED)`.

33. **`test_33_tryPay_insufficientBalance_blockedWithoutReverting`**  
    - Vault balance less than payment amount.
    - Asserts returns `(false, PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE, "")`.
    - Asserts emission of `PaymentBlocked(..., INSUFFICIENT_VAULT_BALANCE)`.

34. **`test_34_tryPay_zeroAmount_blockedWithoutReverting`**  
    - `amount == 0` passed to `tryPay()`.
    - Asserts returns `(false, PaymentBlockReason.ZERO_AMOUNT, "")`.
    - Asserts emission of `PaymentBlocked(..., ZERO_AMOUNT)`.

---

### Suite 6: Daily Rollover Math & Edge Cases (`SpendingGuardRolloverTest`)

35. **`test_35_dailyRollover_resetsSpentToday`**  
    - Agent spends `0.05 MON` (max allowance for day).
    - Advances block timestamp by 24 hours: `vm.warp(block.timestamp + 1 days)`.
    - Agent calls `pay()` for `0.03 MON`.
    - Asserts transaction succeeds; `spentToday` resets and is now `0.03 MON`.

36. **`test_36_midDayLimit_loweredBelowSpentToday`**  
    - Agent spends `0.04 MON` out of `0.05 MON` limit.
    - Owner lowers limit to `0.03 MON`.
    - Asserts `remainingToday()` returns `0` (no arithmetic underflow).
    - Agent attempts `tryPay(0.01 MON)` -> blocked with `OVER_DAILY_LIMIT`.

37. **`test_37_midDayLimit_raisedAboveSpentToday`**  
    - Agent spends `0.04 MON` out of `0.05 MON` limit.
    - Owner raises limit to `0.10 MON`.
    - Asserts `remainingToday()` immediately expands to `0.06 MON`.
    - Agent successfully pays `0.05 MON`.

38. **`test_38_demoScript_exactCumulativeSequence`**  
    - Vault initialized with `0.1 MON`, Agent limit `0.05 MON`.
    - Action 1: `pay(0.02 MON)` -> succeeds. (Spent: 0.02, Remain: 0.03, Bal: 0.08)
    - Action 2: `tryPay(0.06 MON)` -> blocked (`OVER_DAILY_LIMIT`). (Spent: 0.02, Remain: 0.03)
    - Action 3: `pay(0.02 MON)` -> succeeds. (Spent: 0.04, Remain: 0.01, Bal: 0.06)
    - Action 4: `tryPay(0.02 MON)` -> blocked (`OVER_DAILY_LIMIT`: 0.04 + 0.02 = 0.06 > 0.05).
    - Verifies cumulative daily tracking across multiple independent calls.

---

### Suite 7: Security Invariants & Fuzzing (`SpendingGuardSecurityFuzzTest`)

39. **`test_39_reentrancy_attack_reverts`**  
    - Target contract implements a malicious `receive()` hook that re-enters `pay()` or `withdraw()`.
    - Asserts execution reverts with `ReentrancyGuardReentrantCall()`.

40. **`test_40_frontRunning_createAccount_harmless`**  
    - Attacker front-runs `createAccount(qx, qy)` using victim's coordinates.
    - Proves victim still solely controls the created account because all privileged actions require signatures from `(qx, qy)`.

41. **`test_41_fuzz_dailyLimitAndPaymentAmounts`**  
    - Fuzz test taking random initial balances, daily limits, and dynamic payment sequences.
    - Property: `spentToday` within any 24h window never exceeds `dailyLimit`.

42. **`test_42_fuzz_multiAgentIndependentAllowances`**  
    - Deploys multiple agents under one account.
    - Proves spending by Agent 1 does not decrement or affect Agent 2's `spentToday` counter.

43. **`test_43_invariant_contractBalanceGteSumOfAccountBalances`**  
    - Invariant test: Contract native MON balance $\ge \sum \text{account balances}$ across arbitrary combinations of deposits, payments, and withdrawals.
