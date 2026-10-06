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
    // OUT-OF-SCOPE INTERFACE STUBS (Deferred to Phases 8 to 10)
    // ========================================================================

    function pay(bytes32, address payable, uint256, bytes calldata) external pure override returns (bytes memory) {
        revert("Phase 8");
    }

    function tryPay(bytes32, address payable, uint256, bytes calldata)
        external
        pure
        override
        returns (bool, PaymentBlockReason, bytes memory)
    {
        revert("Phase 8");
    }

    function setDailyLimit(bytes32, address, uint128, WebAuthnAuth calldata) external pure override {
        revert("Phase 8");
    }

    function setTargetAllowed(bytes32, address, address, bool, WebAuthnAuth calldata) external pure override {
        revert("Phase 9");
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
