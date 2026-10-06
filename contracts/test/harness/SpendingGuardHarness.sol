// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpendingGuardBase} from "../../src/SpendingGuardBase.sol";

/**
 * ============================================================================
 * WARNING: NEVER DEPLOY TO ANY LIVE CHAIN. FOR FOUNDRY TESTING ONLY.
 * This harness overrides _verifyOwner with an insecure stub for unit testing.
 * The stub accepts an auth only if auth.r == uint256(digest) and account exists.
 * ============================================================================
 */
contract SpendingGuardHarness is SpendingGuardBase {
    /// @dev Stub verifier: accepts signature if auth.r == uint256(digest) and account exists.
    function _verifyOwner(bytes32 accountId, bytes32 digest, WebAuthnAuth calldata auth) internal view override {
        if (_accounts[accountId].qx == bytes32(0)) {
            revert AccountNotFound(accountId);
        }
        if (auth.r != uint256(digest)) {
            revert InvalidSignature();
        }
    }

    // ========================================================================
    // TEST-ONLY STATE SETTERS & HELPERS (NEVER IN PRODUCTION)
    // ========================================================================

    function setPausedForTest(bytes32 accountId, bool paused) external {
        _accounts[accountId].paused = paused;
    }

    function setDailyLimitForTest(bytes32 accountId, address agent, uint128 newDailyLimit) external {
        _agents[accountId][agent].dailyLimit = newDailyLimit;
    }

    function signActionForTest(bytes32 accountId, bytes4 selector, bytes memory params)
        external
        view
        returns (WebAuthnAuth memory)
    {
        uint64 nonce = _accounts[accountId].nonce;
        bytes32 digest = actionHash(accountId, nonce, selector, params);
        return WebAuthnAuth({
            authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: uint256(digest), s: 1
        });
    }

    function createFundedAccountWithAgent(
        bytes32 qx,
        bytes32 qy,
        uint128 initialDeposit,
        address agent,
        uint128 dailyLimit,
        bool anyTarget
    ) external payable returns (bytes32 accountId) {
        accountId = this.createAccount(qx, qy);
        uint128 dep = msg.value > 0 ? uint128(msg.value) : initialDeposit;
        if (dep > 0) {
            _accounts[accountId].balance += dep;
            emit Deposited(accountId, msg.sender, dep);
        }
        _accounts[accountId].nonce++;
        _agents[accountId][agent] = AgentStorage({
            dailyLimit: dailyLimit,
            spentToday: 0,
            dayIndex: uint64(block.timestamp / 1 days),
            active: true,
            anyTarget: anyTarget
        });
        emit AgentAdded(accountId, agent, dailyLimit, anyTarget);
    }

    // ========================================================================
    // OUT-OF-SCOPE INTERFACE STUBS (Deferred to Phase 10)
    // ========================================================================

    function setDailyLimit(bytes32, address, uint128, WebAuthnAuth calldata) external pure override {
        revert("Phase 10");
    }

    function revokeAgent(bytes32, address, WebAuthnAuth calldata) external pure override {
        revert("Phase 10");
    }

    function setPaused(bytes32, bool, WebAuthnAuth calldata) external pure override {
        revert("Phase 10");
    }

    function withdraw(bytes32, address payable, uint256, WebAuthnAuth calldata) external pure override {
        revert("Phase 10");
    }
}
