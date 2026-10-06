// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpendingGuard} from "../src/SpendingGuard.sol";
import {ISpendingGuard} from "../src/interfaces/ISpendingGuard.sol";

/// @title SpendingGuardP256Test
/// @notice Comprehensive test suite for concrete SpendingGuard with real P-256 cryptography.
contract SpendingGuardP256Test is Test {
    SpendingGuard internal guard;

    // secp256r1 curve group order
    uint256 internal constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    // Test owner P-256 private key
    uint256 internal constant OWNER_KEY = 0x4242424242424242424242424242424242424242424242424242424242424242;
    uint256 internal constant OTHER_KEY = 0x9999999999999999999999999999999999999999999999999999999999999999;

    bytes32 internal ownerQx;
    bytes32 internal ownerQy;
    bytes32 internal accountId;

    address internal agent = address(0xAA11);
    address internal otherAgent = address(0xAA22);
    address internal demoRecipient = address(0xBB11);
    address internal attackerRecipient = address(0xDEAD);
    address internal relayer = address(0xCC11);

    function setUp() public {
        guard = new SpendingGuard();

        (uint256 qx, uint256 qy) = vm.publicKeyP256(OWNER_KEY);
        ownerQx = bytes32(qx);
        ownerQy = bytes32(qy);

        accountId = guard.createAccount(ownerQx, ownerQy);
        vm.deal(relayer, 100 ether);
    }

    // Helper to generate real P-256 signed WebAuthnAuth struct
    function _signAction(uint256 privKey, bytes32 digest)
        internal
        pure
        returns (ISpendingGuard.WebAuthnAuth memory auth)
    {
        (bytes32 r, bytes32 s) = vm.signP256(privKey, digest);
        auth = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"",
            clientDataJSON: "",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r),
            s: uint256(s)
        });
    }

    // ==========================================
    // 1. CREATE ACCOUNT & BASIC CHECKS
    // ==========================================

    function test_p256_createAccount() public {
        (uint256 qx2, uint256 qy2) = vm.publicKeyP256(OTHER_KEY);
        bytes32 acc2 = guard.createAccount(bytes32(qx2), bytes32(qy2));
        assertEq(acc2, keccak256(abi.encode(bytes32(qx2), bytes32(qy2))));

        (bytes32 storedQx, bytes32 storedQy, uint256 bal, uint64 nonce, bool paused) = guard.accountOf(acc2);
        assertEq(storedQx, bytes32(qx2));
        assertEq(storedQy, bytes32(qy2));
        assertEq(bal, 0);
        assertEq(nonce, 0);
        assertFalse(paused);
    }

    // ==========================================
    // 2. ADD AGENT & SET TARGET ALLOWED
    // ==========================================

    function test_p256_addAgent_validSignature() public {
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest = guard.actionHash(accountId, nonce, guard.addAgent.selector, params);

        ISpendingGuard.WebAuthnAuth memory auth = _signAction(OWNER_KEY, digest);

        vm.prank(relayer);
        guard.addAgent(accountId, agent, 0.05 ether, false, auth);

        (bool active, uint128 dailyLimit, uint128 spentToday,, bool anyTarget) =
            guard.agentOf(accountId, agent);
        assertTrue(active);
        assertEq(spentToday, 0);
        assertEq(dailyLimit, 0.05 ether);
        assertFalse(anyTarget);
        assertEq(guard.nonceOf(accountId), nonce + 1);
    }

    function test_p256_setTargetAllowed_validSignature() public {
        // First add agent
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params1 = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest1 = guard.actionHash(accountId, nonce, guard.addAgent.selector, params1);
        guard.addAgent(accountId, agent, 0.05 ether, false, _signAction(OWNER_KEY, digest1));

        // Now set target allowed
        nonce = guard.nonceOf(accountId);
        bytes memory params2 = abi.encode(agent, demoRecipient, true);
        bytes32 digest2 = guard.actionHash(accountId, nonce, guard.setTargetAllowed.selector, params2);

        vm.prank(relayer);
        guard.setTargetAllowed(accountId, agent, demoRecipient, true, _signAction(OWNER_KEY, digest2));

        assertTrue(guard.isTargetAllowed(accountId, agent, demoRecipient));
        assertEq(guard.nonceOf(accountId), nonce + 1);
    }

    // ==========================================
    // 3. INVALID SIGNATURES & TAMPERING
    // ==========================================

    function test_p256_revert_differentKey() public {
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest = guard.actionHash(accountId, nonce, guard.addAgent.selector, params);

        // Signed with OTHER_KEY instead of OWNER_KEY
        ISpendingGuard.WebAuthnAuth memory badAuth = _signAction(OTHER_KEY, digest);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(accountId, agent, 0.05 ether, false, badAuth);
    }

    function test_p256_revert_tamperedDigest() public {
        bytes32 fakeDigest = keccak256("tampered_intent");
        ISpendingGuard.WebAuthnAuth memory authOverFakeDigest = _signAction(OWNER_KEY, fakeDigest);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(accountId, agent, 0.05 ether, false, authOverFakeDigest);
    }

    function test_p256_revert_replaySignature() public {
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest = guard.actionHash(accountId, nonce, guard.addAgent.selector, params);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(OWNER_KEY, digest);

        guard.addAgent(accountId, agent, 0.05 ether, false, auth);
        assertEq(guard.nonceOf(accountId), nonce + 1);

        // Attacker attempts to replay the same auth to register a different agent
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(accountId, otherAgent, 0.05 ether, false, auth);
    }

    function test_p256_revert_wrongChainId() public {
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent, uint128(0.05 ether), false);

        // Construct digest with wrong chainId (e.g., Ethereum mainnet 1 instead of block.chainid)
        bytes32 foreignDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SpendingGuard"),
                keccak256("1"),
                uint256(1), // wrong chainId
                address(guard)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SpendingGuardAction(bytes32 accountId,uint64 nonce,bytes4 actionSelector,bytes params)"),
                accountId,
                nonce,
                guard.addAgent.selector,
                keccak256(params)
            )
        );
        bytes32 foreignDigest = keccak256(abi.encodePacked("\x19\x01", foreignDomainSeparator, structHash));

        ISpendingGuard.WebAuthnAuth memory auth = _signAction(OWNER_KEY, foreignDigest);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(accountId, agent, 0.05 ether, false, auth);
    }

    function test_p256_revert_unsupportedAuthMode() public {
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest = guard.actionHash(accountId, nonce, guard.addAgent.selector, params);

        (bytes32 r, bytes32 s) = vm.signP256(OWNER_KEY, digest);

        // 1. Non-empty authenticatorData
        ISpendingGuard.WebAuthnAuth memory authWithAuthData = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"010203",
            clientDataJSON: "",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r),
            s: uint256(s)
        });
        vm.expectRevert(ISpendingGuard.UnsupportedAuthMode.selector);
        guard.addAgent(accountId, agent, 0.05 ether, false, authWithAuthData);

        // 2. Non-empty clientDataJSON
        ISpendingGuard.WebAuthnAuth memory authWithClientData = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"",
            clientDataJSON: "{\"type\":\"webauthn.get\"}",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r),
            s: uint256(s)
        });
        vm.expectRevert(ISpendingGuard.UnsupportedAuthMode.selector);
        guard.addAgent(accountId, agent, 0.05 ether, false, authWithClientData);
    }

    // ==========================================
    // 4. SIGNATURE MALLEABILITY (n - s)
    // ==========================================

    function test_p256_signatureMalleability_behavior() public {
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest = guard.actionHash(accountId, nonce, guard.addAgent.selector, params);

        (bytes32 r, bytes32 s) = vm.signP256(OWNER_KEY, digest);

        // Compute high-s malleable variant: s' = n - s
        uint256 sMalleable = P256_N - uint256(s);

        ISpendingGuard.WebAuthnAuth memory authStandard = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"",
            clientDataJSON: "",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r),
            s: uint256(s)
        });

        // 1. First execution succeeds with standard signature
        guard.addAgent(accountId, agent, 0.05 ether, false, authStandard);
        assertEq(guard.nonceOf(accountId), nonce + 1);

        // 2. Attempting to submit the malleable variant (s') against the account fails
        // because the sequential nonce was consumed upon the first execution.
        ISpendingGuard.WebAuthnAuth memory authMalleable = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"",
            clientDataJSON: "",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r),
            s: sMalleable
        });

        // Replaying with otherAgent fails InvalidSignature due to nonce mismatch
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(accountId, otherAgent, 0.05 ether, false, authMalleable);

        // 3. Moreover, on a FRESH action with current nonce, both (r, s) and (r, s') are valid
        // mathematically, demonstrating that malleability is harmless as long as the nonce advances.
        uint64 nonce2 = guard.nonceOf(accountId);
        bytes memory params2 = abi.encode(agent, uint128(0.08 ether));
        bytes32 digest2 = guard.actionHash(accountId, nonce2, guard.setDailyLimit.selector, params2);
        (bytes32 r2, bytes32 s2) = vm.signP256(OWNER_KEY, digest2);
        uint256 s2Malleable = P256_N - uint256(s2);

        ISpendingGuard.WebAuthnAuth memory authFreshMalleable = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"",
            clientDataJSON: "",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r2),
            s: s2Malleable
        });
        // Executes successfully with malleable s'
        guard.setDailyLimit(accountId, agent, 0.08 ether, authFreshMalleable);
        assertEq(guard.nonceOf(accountId), nonce2 + 1);

        // Replaying the original (r2, s2) now fails because nonce advanced
        ISpendingGuard.WebAuthnAuth memory authOriginalReplay = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"",
            clientDataJSON: "",
            challengeIndex: 0,
            typeIndex: 0,
            r: uint256(r2),
            s: uint256(s2)
        });
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(accountId, agent, 0.08 ether, authOriginalReplay);
    }

    // ==========================================
    // 5. RELAYER CANNOT REDIRECT WITHDRAWAL
    // ==========================================

    function test_p256_relayerCannotRedirect_withdraw() public {
        guard.deposit{value: 1 ether}(accountId);

        uint64 nonce = guard.nonceOf(accountId);
        // Owner authorizes withdrawal to demoRecipient of 0.5 ether
        bytes memory params = abi.encode(demoRecipient, 0.5 ether);
        bytes32 digest = guard.actionHash(accountId, nonce, guard.withdraw.selector, params);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(OWNER_KEY, digest);

        // Relayer attempts to redirect to attackerRecipient
        vm.prank(relayer);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.withdraw(accountId, payable(attackerRecipient), 0.5 ether, auth);

        // Relayer attempts to tamper with amount
        vm.prank(relayer);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.withdraw(accountId, payable(demoRecipient), 0.6 ether, auth);

        // Legitimate execution to demoRecipient succeeds
        uint256 recipientBalBefore = demoRecipient.balance;
        vm.prank(relayer);
        guard.withdraw(accountId, payable(demoRecipient), 0.5 ether, auth);
        assertEq(demoRecipient.balance, recipientBalBefore + 0.5 ether);
    }

    // ==========================================
    // 6. FULL DEMO SEQUENCE WITH REAL SIGNATURES
    // ==========================================

    function test_p256_fullDemoSequence() public {
        // 1. Deposit 0.1 ether
        guard.deposit{value: 0.1 ether}(accountId);

        // 2. Owner adds agent with 0.05 ether limit
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory addAgentParams = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest1 = guard.actionHash(accountId, nonce, guard.addAgent.selector, addAgentParams);
        guard.addAgent(accountId, agent, 0.05 ether, false, _signAction(OWNER_KEY, digest1));

        // 3. Owner sets demoRecipient as allowed target
        nonce = guard.nonceOf(accountId);
        bytes memory setTargetParams = abi.encode(agent, demoRecipient, true);
        bytes32 digest2 = guard.actionHash(accountId, nonce, guard.setTargetAllowed.selector, setTargetParams);
        guard.setTargetAllowed(accountId, agent, demoRecipient, true, _signAction(OWNER_KEY, digest2));

        // 4. Agent tryPay 0.02 ether -> ok
        vm.prank(agent);
        (bool ok1, ISpendingGuard.PaymentBlockReason r1) =
            guard.tryPay(accountId, payable(demoRecipient), 0.02 ether);
        assertTrue(ok1);
        assertEq(uint8(r1), uint8(ISpendingGuard.PaymentBlockReason.NONE));

        // 5. Agent tryPay 0.06 ether -> blocked OVER_DAILY_LIMIT
        vm.prank(agent);
        (bool ok2, ISpendingGuard.PaymentBlockReason r2) =
            guard.tryPay(accountId, payable(demoRecipient), 0.06 ether);
        assertFalse(ok2);
        assertEq(uint8(r2), uint8(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));

        // 6. Agent tryPay 0.02 ether -> ok (spentTotal = 0.04 ether)
        vm.prank(agent);
        (bool ok3, ISpendingGuard.PaymentBlockReason r3) =
            guard.tryPay(accountId, payable(demoRecipient), 0.02 ether);
        assertTrue(ok3);
        assertEq(uint8(r3), uint8(ISpendingGuard.PaymentBlockReason.NONE));

        // 7. Agent tryPay 0.02 ether -> blocked OVER_DAILY_LIMIT (0.04 + 0.02 = 0.06 > 0.05)
        vm.prank(agent);
        (bool ok4, ISpendingGuard.PaymentBlockReason r4) =
            guard.tryPay(accountId, payable(demoRecipient), 0.02 ether);
        assertFalse(ok4);
        assertEq(uint8(r4), uint8(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));

        // 8. Assert balances and limits
        (,, uint256 vaultBal,,) = guard.accountOf(accountId);
        assertEq(vaultBal, 0.06 ether);
        assertEq(demoRecipient.balance, 0.04 ether);
        assertEq(guard.remainingToday(accountId, agent), 0.01 ether);
    }
}
