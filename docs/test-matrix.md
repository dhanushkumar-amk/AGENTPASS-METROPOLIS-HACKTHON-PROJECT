# Test Matrix & Verification Mapping

This document provides a comprehensive traceability matrix mapping every numbered requirement from [test-plan.md](file:///home/dhanushkumar/agentpass/docs/test-plan.md) and every threat from the [contract-spec.md Threat Model](file:///home/dhanushkumar/agentpass/docs/contract-spec.md#threat-model) directly to its verifying Foundry test functions.

---

## 1. Test Plan Traceability Matrix

| Item # | Test Plan Specification | Target Function(s) | Verifying Test Function(s) | Suite File |
| :---: | :--- | :--- | :--- | :--- |
| 1 | `test_01_createAccount_happyPath` | `createAccount` | `test_createAccount_correctAccountId`, `test_createAccount_emitsEvent` | `test/SpendingGuardBase.t.sol` |
| 2 | `test_02_createAccount_revert_alreadyExists` | `createAccount` | `test_createAccount_revert_duplicate` | `test/SpendingGuardBase.t.sol` |
| 3 | `test_03_createAccount_revert_zeroCoordinates` | `createAccount` | `test_createAccount_revert_zeroKey` | `test/SpendingGuardBase.t.sol` |
| 4 | `test_04_deposit_happyPath` | `deposit` | `test_deposit_increasesBalance`, `test_deposit_emitsEvent`, `test_deposit_anyoneCanDeposit` | `test/SpendingGuardBase.t.sol` |
| 5 | `test_05_deposit_revert_accountNotFound` | `deposit` | `test_deposit_revert_unknownAccount` | `test/SpendingGuardBase.t.sol` |
| 6 | `test_06_deposit_revert_zeroAmount` | `deposit` | `test_deposit_revert_zeroValue` | `test/SpendingGuardBase.t.sol` |
| 7 | `test_07_ownerAction_validP256Signature` | `_verifyOwner`, `addAgent` | `test_addAgent_successPath`, `test_setDailyLimit_successAndEventAndNonce` | `test/SpendingGuardBase.t.sol`, `test/SpendingGuardOwner.t.sol` |
| 8 | `test_08_ownerAction_revert_invalidSignature` | `_verifyOwner` | `test_setTargetAllowed_revert_badAuth`, `test_setDailyLimit_revert_badAuth`, `test_setAnyTarget_revert_badAuth` | `test/SpendingGuardAllowlist.t.sol`, `test/SpendingGuardOwner.t.sol` |
| 9 | `test_09_ownerAction_revert_replayNonce` | `nonceOf`, `actionHash` | `test_replay_revert_reusedAuth`, `test_replay_revert_futureNonceAuth` | `test/SpendingGuardBase.t.sol` |
| 10 | `test_10_ownerAction_revert_wrongChainDigest` | `domainSeparator`, `actionHash` | `test_digestBinding_revert_wrongChainId`, `test_digestBinding_allFourFunctions` | `test/SpendingGuardBase.t.sol`, `test/SpendingGuardOwner.t.sol` |
| 11 | `test_11_ownerAction_revert_wrongAccountId` | `actionHash` | `test_digestBinding_revert_wrongAccountId`, `test_digestBinding_allFourFunctions` | `test/SpendingGuardBase.t.sol`, `test/SpendingGuardOwner.t.sol` |
| 12 | `test_12_ownerAction_revert_wrongActionSelector` | `actionHash` | `test_digestBinding_revert_wrongActionSelector`, `test_digestBinding_allFourFunctions` | `test/SpendingGuardBase.t.sol`, `test/SpendingGuardOwner.t.sol` |
| 13 | `test_13_ownerAction_revert_signatureMalleabilityHighS` | `_verifyOwner` | `test_p256_malleableS_rejected` (Phase 14 integration test), `test_replay_revert_reusedAuth` | `test/fork/P256Precompile.t.sol`, `test/SpendingGuardBase.t.sol` |
| 14 | `test_14_addAgent_happyPath` | `addAgent` | `test_addAgent_successPath` | `test/SpendingGuardBase.t.sol` |
| 15 | `test_15_setDailyLimit_happyPath` | `setDailyLimit` | `test_setDailyLimit_successAndEventAndNonce` | `test/SpendingGuardOwner.t.sol` |
| 16 | `test_16_setTargetAllowed_happyPath` | `setTargetAllowed` | `test_setTargetAllowed_happyPathAndRemoval` | `test/SpendingGuardAllowlist.t.sol` |
| 17 | `test_17_setAnyTarget_toggle` | `setAnyTarget` | `test_setAnyTarget_happyPathAndToggle` | `test/SpendingGuardAllowlist.t.sol` |
| 18 | `test_18_setDailyLimit_lifecycle` | `setDailyLimit`, `remainingToday` | `test_setDailyLimit_midDayAdjustmentsAndRollover` | `test/SpendingGuardOwner.t.sol` |
| 19 | `test_19_setPaused_emergencyFreeze` | `setPaused`, `pay`, `tryPay` | `test_setPaused_successAndBlocking` | `test/SpendingGuardOwner.t.sol` |
| 20 | `test_20_revokeAgent_permanentRevocation` | `revokeAgent`, `addAgent` | `test_revokeAgent_successAndEnforcement` | `test/SpendingGuardOwner.t.sol` |
| 21 | `test_21_withdraw_accountingAndProtection` | `withdraw` | `test_withdraw_success_partialAndFull`, `test_withdraw_reverts_boundariesAndInvalidTargets`, `test_withdraw_Reentrancy_failsAndRollsBack`, `test_withdraw_rejectingRecipientRevertsTransferFailed` | `test/SpendingGuardOwner.t.sol` |
| 22 | `test_22_ownerActions_digestBindingAndInvariants` | Owner Actions, `actionHash` | `test_digestBinding_allFourFunctions`, `test_invariant_accountingSolvency`, `test_invariant_nonceEqualsOwnerActionsCount`, `testFuzz_ownerActionsSequence` | `test/SpendingGuardOwner.t.sol` |
| 21 | `test_21_pay_happyPath` | `pay` | `test_pay_happyPath`, `test_pay_withCalldata_happyPath`, `test_pay_overloadWithoutCalldata_happyPath` | `test/SpendingGuardPay.t.sol` |
| 22 | `test_22_pay_revert_unauthorizedAgent` | `pay` | `test_pay_revert_agentNotActive_stranger`, `test_pay_revert_agentNotActive_wrongAccount` | `test/SpendingGuardPay.t.sol` |
| 23 | `test_23_pay_revert_accountPaused` | `pay` | `test_pay_revert_paused` | `test/SpendingGuardPay.t.sol` |
| 24 | `test_24_pay_revert_targetNotAllowed` | `pay` | `test_pay_revert_targetNotAllowed_disallowedAddress`, `test_pay_revert_targetNotAllowed_zeroAddress` | `test/SpendingGuardPay.t.sol` |
| 25 | `test_25_pay_revert_dailyLimitExceeded` | `pay` | `test_pay_revert_overDailyLimit`, `test_boundaries_payDailyLimitPlusOneWeiBlocked`, `test_boundaries_payUint256MaxRevertsDailyLimitExceeded` | `test/SpendingGuardPay.t.sol` |
| 26 | `test_26_pay_revert_insufficientVaultBalance` | `pay` | `test_pay_revert_insufficientVaultBalance` | `test/SpendingGuardPay.t.sol` |
| 27 | `test_27_pay_revert_zeroAmount` | `pay` | `test_pay_revert_zeroAmount` | `test/SpendingGuardPay.t.sol` |
| 28 | `test_28_tryPay_withinLimit_succeeds` | `tryPay` | `test_tryPay_happyPath`, `test_tryPay_withCalldata_happyPath`, `test_tryPay_overloadWithoutCalldata_happyPath` | `test/SpendingGuardPay.t.sol` |
| 29 | `test_29_tryPay_overLimit_blockedWithoutReverting` | `tryPay` | `test_tryPay_blocked_overDailyLimit`, `test_boundaries_typeUint256MaxBlockedWithoutOverflow` | `test/SpendingGuardPay.t.sol` |
| 30 | `test_30_tryPay_paused_blockedWithoutReverting` | `tryPay` | `test_tryPay_blocked_paused` | `test/SpendingGuardPay.t.sol` |
| 31 | `test_31_tryPay_unauthorized_blockedWithoutReverting` | `tryPay` | `test_tryPay_blocked_agentNotActive_stranger`, `test_tryPay_blocked_agentNotActive_wrongAccount`, `test_tryPay_overloadWithoutCalldata_blockedPath` | `test/SpendingGuardPay.t.sol` |
| 32 | `test_32_tryPay_targetDisallowed_blockedWithoutReverting` | `tryPay` | `test_tryPay_blocked_targetNotAllowed_disallowedAddress`, `test_tryPay_blocked_targetNotAllowed_zeroAddress` | `test/SpendingGuardPay.t.sol` |
| 33 | `test_33_tryPay_insufficientBalance_blockedWithoutReverting` | `tryPay` | `test_tryPay_blocked_insufficientVaultBalance` | `test/SpendingGuardPay.t.sol` |
| 34 | `test_34_tryPay_zeroAmount_blockedWithoutReverting` | `tryPay` | `test_tryPay_blocked_zeroAmount` | `test/SpendingGuardPay.t.sol` |
| 35 | `test_35_dailyRollover_resetsSpentToday` | `remainingToday`, `pay` | `test_dayRollover_boundaryTransitions`, `test_remainingToday_variousStates` | `test/SpendingGuardPay.t.sol` |
| 36 | `test_36_midDayLimit_loweredBelowSpentToday` | `setDailyLimit`, `remainingToday` | `test_setDailyLimit_midDayAdjustmentsAndRollover` | `test/SpendingGuardOwner.t.sol` |
| 37 | `test_37_midDayLimit_raisedAboveSpentToday` | `setDailyLimit`, `remainingToday` | `test_setDailyLimit_midDayAdjustmentsAndRollover` | `test/SpendingGuardOwner.t.sol` |
| 38 | `test_38_demoScript_exactCumulativeSequence` | `pay`, `tryPay` | `testDemo_scriptExactNumbers`, `test_cumulative_multiplePaymentsAddUp` | `test/SpendingGuardPay.t.sol` |
| 39 | `test_39_reentrancy_attack_reverts` | `pay`, `tryPay`, `withdraw` | `test_Reentrancy_payReverts`, `test_Reentrancy_tryPayReverts`, `test_withdraw_Reentrancy_failsAndRollsBack` | `test/SpendingGuardPay.t.sol`, `test/SpendingGuardOwner.t.sol` |
| 40 | `test_40_frontRunning_createAccount_harmless` | `createAccount` | `test_createAccount_twoDifferentKeysGiveTwoAccounts`, `test_relayerIndependence_anySenderCanSubmit` | `test/SpendingGuardBase.t.sol`, `test/SpendingGuardAllowlist.t.sol` |
| 41 | `test_41_fuzz_dailyLimitAndPaymentAmounts` | `pay`, `tryPay` | `testFuzz_paymentsAndWarpsBoundedByLimit` | `test/SpendingGuardPay.t.sol` |
| 42 | `test_42_fuzz_multiAgentIndependentAllowances` | `_agents` storage isolation | `test_isolation_agentInTwoAccountsIndependent` | `test/SpendingGuardPay.t.sol` |
| 43 | `test_43_invariant_contractBalanceGteSumOfAccountBalances` | Accounting solvency | `invariant_contractBalanceGteSumOfTrackedBalances`, `test_invariant_accountingSolvency` | `test/SpendingGuardInvariant.t.sol`, `test/SpendingGuardOwner.t.sol` |

---

## 2. Threat Model Coverage Matrix

Mapping of all 8 threat vectors defined in [contract-spec.md Threat Model](file:///home/dhanushkumar/agentpass/docs/contract-spec.md#threat-model) to architectural defense mechanisms and validating test suites.

| Threat Vector | Severity | Architectural Defense | Verifying Test Function(s) |
| :--- | :--- | :--- | :--- |
| **1. Replay Attacks** | High | Monotonically increasing account nonces (`_accounts[accountId].nonce++`); EIP-712 typed action hash binding `(chainId, verifyingContract, accountId, nonce, selector, paramsHash)`. | `test_replay_revert_reusedAuth`, `test_replay_revert_futureNonceAuth`, `test_digestBinding_revert_wrongChainId`, `test_digestBinding_revert_wrongContractAddress`, `test_digestBinding_allFourFunctions`, `testFuzz_nonceIncreasesByExactlyOne` |
| **2. Signature Malleability** | Medium | Secp256r1 precompile requires canonical low-$s$ values ($s \le n/2$). Nonce increments atomically upon execution, invalidating alternate signature representations. | `test/fork/P256Precompile.t.sol:test_p256_malleableS_rejected`, `test_replay_revert_reusedAuth` |
| **3. Front-Running `createAccount`** | Low | Account identifier is deterministic and cryptographically bound to passkey coordinates: `accountId = keccak256(abi.encode(qx, qy))`. Front-runner pays gas but cannot authorize actions without the private key. | `test_createAccount_twoDifferentKeysGiveTwoAccounts`, `test_relayerIndependence_anySenderCanSubmit` |
| **4. Reentrancy via Native MON** | Critical | OpenZeppelin `ReentrancyGuard` (`nonReentrant` modifier) across all external payment and withdrawal entrypoints (`pay`, `tryPay`, `withdraw`); strict Checks-Effects-Interactions (CEI) state mutation before any low-level `.call`. | `test_Reentrancy_payReverts`, `test_Reentrancy_tryPayReverts`, `test_withdraw_Reentrancy_failsAndRollsBack`, `test_CEI_stateUpdatedBeforeExternalCall` |
| **5. Multi-Account Pooled Funds Risk** | Critical | Strict per-account ledger isolation in mapping storage; strict arithmetic underflow guards; invariant testing verifies contract native MON balance $\ge \sum \text{account balances}$ at every state step. | `invariant_contractBalanceGteSumOfTrackedBalances`, `test_invariant_accountingSolvency`, `test_payIntegration_allowlistAccountAndAgentIsolation` |
| **6. Relayer Compromise / Parameter Altering** | High | Relayer is an untrusted submission conduit. Action digest binds recipient address, amount, limit, and flags. Any tampered parameter invalidates owner signature. | `test_relayerCannotRedirect_withdrawAuth`, `test_digestBinding_mismatchedParameters`, `test_relayerIndependence_anySenderCanSubmit` |
| **7. Agent Key Compromise** | High | Blast radius strictly capped by `dailyLimit` and recipient allowlist. Owner retains instantaneous unilateral power to call `setPaused` or `revokeAgent` to permanently deactivate agent. | `test_setPaused_successAndBlocking`, `test_revokeAgent_successAndEnforcement`, `test_pay_revert_overDailyLimit`, `test_payIntegration_allowlistEnforcement` |
| **8. Griefing via Spam Deposits** | Low | Accounting uses tracked internal balance increments, ignoring uncredited balance surpluses. Zero-value deposits revert with `ZeroAmount()`. Plain native transfers without `deposit(accountId)` revert. | `test_deposit_revert_zeroValue`, `test_deposit_revert_plainTransfer`, `test_fallback_revert`, `testFuzz_depositsSumToBalance` |

---

## 3. Summary of Additional Tests Added

To close all test gaps and satisfy strict coverage requirements, the following test functions were added:

1. **`test_withdraw_revert_unknownAccount()`** in `SpendingGuardOwner.t.sol` — Verifies `withdraw` reverts with `AccountNotFound(accountId)` when supplied with an unregistered account identifier.
2. **`test_CEI_stateUpdatedBeforeExternalCall()`** in `SpendingGuardPay.t.sol` — Deploys `CEIObserverRecipient` to assert that account balance is decremented and `spentToday` is incremented BEFORE the external MON transfer `.call` fires, permanently killing mutant M5.
3. **`test_pay_overloadWithoutCalldata_happyPath()`** in `SpendingGuardPay.t.sol` — Tests the 3-parameter overload of `pay(accountId, target, amount)`.
4. **`test_tryPay_overloadWithoutCalldata_happyPath()`** in `SpendingGuardPay.t.sol` — Tests the 3-parameter overload of `tryPay(accountId, target, amount)` on successful path.
5. **`test_tryPay_overloadWithoutCalldata_blockedPath()`** in `SpendingGuardPay.t.sol` — Tests the 3-parameter overload of `tryPay(accountId, target, amount)` when blocked by policy.
6. **`test_boundaries_payUint256MaxRevertsDailyLimitExceeded()`** in `SpendingGuardPay.t.sol` — Verifies `type(uint256).max` payment amount safely casts in custom error revert without integer overflow.
