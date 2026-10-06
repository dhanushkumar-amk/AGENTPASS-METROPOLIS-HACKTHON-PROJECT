// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpendingGuardBase} from "./SpendingGuardBase.sol";

/// @title SpendingGuard
/// @author AgentPass Protocol
/// @notice Production spending-limit and identity layer for AI agents with raw P-256 owner verification.
/// @dev Extends SpendingGuardBase and implements _verifyOwner using the native secp256r1 precompile
///      at address 0x0000000000000000000000000000000000000100 on Monad testnet (RIP-7212 / EIP-7951).
contract SpendingGuard is SpendingGuardBase {
    /// @notice Address of the native secp256r1 / P-256 curve verification precompile.
    address internal constant P256_PRECOMPILE = address(0x0000000000000000000000000000000000000100);

    /// @notice Concrete implementation of owner verification using the native P-256 precompile.
    /// @dev Raw mode (Phase 12): directly verifies the 32-byte digest against curve points (qx, qy)
    ///      using the precompile at address 0x0100.
    ///      WebAuthn envelope data (authenticatorData, clientDataJSON) is deferred to Phase 14 and must be empty.
    ///      Note on signature malleability: In ECDSA/P-256, both (r, s) and (r, n - s) are mathematically valid.
    ///      Signature malleability is harmless here because every owner action consumes the sequential
    ///      account nonce atomically upon execution, preventing replay of any malleable signature variant.
    /// @param accountId Unique identifier of the vault account.
    /// @param digest 32-byte EIP-712 typed action hash committing to action parameters, nonce, and chain ID.
    /// @param auth WebAuthnAuth struct containing raw P-256 signature scalars (r, s).
    function _verifyOwner(bytes32 accountId, bytes32 digest, WebAuthnAuth calldata auth) internal view override {
        // Raw P-256 mode requires WebAuthn envelope fields to be empty.
        if (auth.authenticatorData.length != 0 || bytes(auth.clientDataJSON).length != 0) {
            revert UnsupportedAuthMode();
        }

        bytes32 qx = _accounts[accountId].qx;
        bytes32 qy = _accounts[accountId].qy;

        bytes memory input = abi.encodePacked(digest, bytes32(auth.r), bytes32(auth.s), qx, qy);

        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(input);
        if (!success || ret.length != 32 || abi.decode(ret, (uint256)) != 1) {
            revert InvalidSignature();
        }
    }
}
