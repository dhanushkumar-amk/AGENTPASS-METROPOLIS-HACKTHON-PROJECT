// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpendingGuardHarness} from "./harness/SpendingGuardHarness.sol";
import {ISpendingGuard} from "../src/interfaces/ISpendingGuard.sol";

contract SpendingGuardAllowlistTest is Test {
    SpendingGuardHarness internal guard;

    bytes32 internal accountId;
    bytes32 internal otherAccountId;

    address internal agent = address(0xAA01);
    address internal otherAgent = address(0xAA02);
    address internal targetA = address(0xCC01);
    address internal targetB = address(0xCC02);

    event TargetAllowedSet(bytes32 indexed accountId, address indexed agent, address indexed target, bool allowed);
    event AnyTargetSet(bytes32 indexed accountId, address indexed agent, bool anyTarget);
    event PaymentExecuted(bytes32 indexed accountId, address indexed agent, address indexed target, uint256 amount);
    event PaymentBlocked(
        bytes32 indexed accountId,
        address indexed agent,
        address indexed target,
        uint256 amount,
        ISpendingGuard.PaymentBlockReason reason
    );

    function setUp() public {
        guard = new SpendingGuardHarness();
        vm.deal(address(guard), 1000 ether);

        // Account 1: 1 ether balance, agent with 0.1 ether limit, anyTarget = false
        accountId = guard.createFundedAccountWithAgent{value: 1 ether}(
            bytes32(uint256(0x101)), bytes32(uint256(0x102)), 1 ether, agent, 0.1 ether, false
        );

        // Account 2: 1 ether balance, otherAgent with 0.1 ether limit, anyTarget = false
        otherAccountId = guard.createFundedAccountWithAgent{value: 1 ether}(
            bytes32(uint256(0x201)), bytes32(uint256(0x202)), 1 ether, otherAgent, 0.1 ether, false
        );
    }

    // ==========================================
    // TEST HELPERS
    // ==========================================

    function _signAction(bytes32 accId, bytes4 selector, bytes memory params)
        internal
        view
        returns (ISpendingGuard.WebAuthnAuth memory)
    {
        return guard.signActionHarness(accId, selector, params);
    }

    function _setTargetAllowed(bytes32 accId, address ag, address target, bool allowed) internal {
        bytes memory params = abi.encode(ag, target, allowed);
        guard.setTargetAllowed(accId, ag, target, allowed, _signAction(accId, guard.setTargetAllowed.selector, params));
    }

    function _setAnyTarget(bytes32 accId, address ag, bool anyTarget) internal {
        bytes memory params = abi.encode(ag, anyTarget);
        guard.setAnyTarget(accId, ag, anyTarget, _signAction(accId, guard.setAnyTarget.selector, params));
    }

    // ==========================================
    // SET TARGET ALLOWED HAPPY PATH & REMOVAL
    // ==========================================

    function test_setTargetAllowed_happyPathAndRemoval() public {
        uint64 initialNonce = guard.nonceOf(accountId);

        // 1. Grant targetA
        vm.expectEmit(true, true, true, true);
        emit TargetAllowedSet(accountId, agent, targetA, true);

        bytes memory params = abi.encode(agent, targetA, true);
        guard.setTargetAllowed(
            accountId, agent, targetA, true, _signAction(accountId, guard.setTargetAllowed.selector, params)
        );

        assertEq(guard.nonceOf(accountId), initialNonce + 1);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        // 2. Revoke targetA
        vm.expectEmit(true, true, true, true);
        emit TargetAllowedSet(accountId, agent, targetA, false);

        params = abi.encode(agent, targetA, false);
        guard.setTargetAllowed(
            accountId, agent, targetA, false, _signAction(accountId, guard.setTargetAllowed.selector, params)
        );

        assertEq(guard.nonceOf(accountId), initialNonce + 2);
        assertFalse(guard.isTargetAllowed(accountId, agent, targetA));
    }

    function test_setTargetAllowed_idempotent() public {
        uint64 nonceBefore = guard.nonceOf(accountId);

        // Set true twice
        _setTargetAllowed(accountId, agent, targetA, true);
        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        _setTargetAllowed(accountId, agent, targetA, true);
        assertEq(guard.nonceOf(accountId), nonceBefore + 2);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        // Set false twice
        _setTargetAllowed(accountId, agent, targetA, false);
        assertEq(guard.nonceOf(accountId), nonceBefore + 3);
        assertFalse(guard.isTargetAllowed(accountId, agent, targetA));

        _setTargetAllowed(accountId, agent, targetA, false);
        assertEq(guard.nonceOf(accountId), nonceBefore + 4);
        assertFalse(guard.isTargetAllowed(accountId, agent, targetA));
    }

    // ==========================================
    // SET ANY TARGET HAPPY PATH & TOGGLE
    // ==========================================

    function test_setAnyTarget_happyPathAndToggle() public {
        uint64 initialNonce = guard.nonceOf(accountId);

        // Toggle anyTarget = true
        vm.expectEmit(true, true, true, true);
        emit AnyTargetSet(accountId, agent, true);

        bytes memory params = abi.encode(agent, true);
        guard.setAnyTarget(accountId, agent, true, _signAction(accountId, guard.setAnyTarget.selector, params));

        assertEq(guard.nonceOf(accountId), initialNonce + 1);
        (,,,, bool anyTargetAfterTrue) = guard.agentOf(accountId, agent);
        assertTrue(anyTargetAfterTrue);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        // Toggle anyTarget = false
        vm.expectEmit(true, true, true, true);
        emit AnyTargetSet(accountId, agent, false);

        params = abi.encode(agent, false);
        guard.setAnyTarget(accountId, agent, false, _signAction(accountId, guard.setAnyTarget.selector, params));

        assertEq(guard.nonceOf(accountId), initialNonce + 2);
        (,,,, bool anyTargetAfterFalse) = guard.agentOf(accountId, agent);
        assertFalse(anyTargetAfterFalse);
        assertFalse(guard.isTargetAllowed(accountId, agent, targetA));
    }

    function test_setAnyTarget_idempotent() public {
        uint64 nonceBefore = guard.nonceOf(accountId);

        _setAnyTarget(accountId, agent, true);
        assertEq(guard.nonceOf(accountId), nonceBefore + 1);

        _setAnyTarget(accountId, agent, true);
        assertEq(guard.nonceOf(accountId), nonceBefore + 2);
    }

    // ==========================================
    // REVERTS FOR SET TARGET ALLOWED
    // ==========================================

    function test_setTargetAllowed_revert_zeroTarget() public {
        bytes memory params = abi.encode(agent, address(0), true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setTargetAllowed.selector, params);

        vm.expectRevert(ISpendingGuard.InvalidTarget.selector);
        guard.setTargetAllowed(accountId, agent, address(0), true, auth);
    }

    function test_setTargetAllowed_revert_inactiveAgent() public {
        address inactiveAgent = address(0x9999);
        bytes memory params = abi.encode(inactiveAgent, targetA, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setTargetAllowed.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, inactiveAgent));
        guard.setTargetAllowed(accountId, inactiveAgent, targetA, true, auth);
    }

    function test_setTargetAllowed_revert_agentOfDifferentAccount() public {
        // agent belongs to accountId, not otherAccountId
        bytes memory params = abi.encode(agent, targetA, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(otherAccountId, guard.setTargetAllowed.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, otherAccountId, agent));
        guard.setTargetAllowed(otherAccountId, agent, targetA, true, auth);
    }

    function test_setTargetAllowed_revert_unknownAccount() public {
        bytes32 unknownAccount = bytes32(uint256(0xDEAD));
        ISpendingGuard.WebAuthnAuth memory auth = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: 12345, s: 1
        });

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownAccount));
        guard.setTargetAllowed(unknownAccount, agent, targetA, true, auth);
    }

    function test_setTargetAllowed_revert_badAuth() public {
        bytes memory params = abi.encode(agent, targetA, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setTargetAllowed.selector, params);
        auth.r = auth.r ^ 0x1; // Corrupt signature

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, agent, targetA, true, auth);
    }

    // ==========================================
    // REVERTS FOR SET ANY TARGET
    // ==========================================

    function test_setAnyTarget_revert_unknownAccount() public {
        bytes32 unknownAccount = bytes32(uint256(0xDEAD));
        ISpendingGuard.WebAuthnAuth memory auth = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: 12345, s: 1
        });

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownAccount));
        guard.setAnyTarget(unknownAccount, agent, true, auth);
    }

    function test_setAnyTarget_revert_inactiveAgent() public {
        address inactiveAgent = address(0x9999);
        bytes memory params = abi.encode(inactiveAgent, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setAnyTarget.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, inactiveAgent));
        guard.setAnyTarget(accountId, inactiveAgent, true, auth);
    }

    function test_setAnyTarget_revert_badAuth() public {
        bytes memory params = abi.encode(agent, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setAnyTarget.selector, params);
        auth.r = auth.r ^ 0x1;

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setAnyTarget(accountId, agent, true, auth);
    }

    // ==========================================
    // DIGEST BINDING & REPLAY PROTECTION
    // ==========================================

    function test_digestBinding_mismatchedParameters() public {
        // Register otherAgent in accountId first so it is active
        bytes memory addAgentParams = abi.encode(otherAgent, uint128(0.1 ether), false);
        guard.addAgent(
            accountId, otherAgent, 0.1 ether, false, _signAction(accountId, guard.addAgent.selector, addAgentParams)
        );

        bytes memory validParams = abi.encode(agent, targetA, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setTargetAllowed.selector, validParams);

        // 1. Mismatched target (targetB instead of targetA)
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, agent, targetB, true, auth);

        // 2. Mismatched allowed flag (false instead of true)
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, agent, targetA, false, auth);

        // 3. Mismatched agent (otherAgent active, but auth was for agent)
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, otherAgent, targetA, true, auth);

        // 4. Mismatched accountId
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(otherAccountId, otherAgent, targetA, true, auth);

        // 5. Mismatched selector (e.g. using addAgent auth for setTargetAllowed)
        bytes memory paramsForAdd = abi.encode(agent, uint128(0.1 ether), false);
        ISpendingGuard.WebAuthnAuth memory authForAdd = _signAction(accountId, guard.addAgent.selector, paramsForAdd);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, agent, targetA, true, authForAdd);

        // 6. Mismatched chainId
        uint256 origChainId = vm.getChainId();
        vm.chainId(99999);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, agent, targetA, true, auth);
        vm.chainId(origChainId);

        // 7. Mismatched contract address
        SpendingGuardHarness secondGuard = new SpendingGuardHarness();
        bytes32 secondAcc = secondGuard.createAccount(bytes32(uint256(0x101)), bytes32(uint256(0x102)));
        secondGuard.addAgent(
            secondAcc,
            agent,
            0.1 ether,
            false,
            secondGuard.signActionHarness(
                secondAcc, secondGuard.addAgent.selector, abi.encode(agent, uint128(0.1 ether), false)
            )
        );
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        secondGuard.setTargetAllowed(secondAcc, agent, targetA, true, auth);

        // 8. Stale nonce and replay after success
        // Now execute valid auth: succeeds
        guard.setTargetAllowed(accountId, agent, targetA, true, auth);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        // Replay of same auth must revert because nonce moved
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setTargetAllowed(accountId, agent, targetA, true, auth);
    }

    // ==========================================
    // RELAYER INDEPENDENCE
    // ==========================================

    function test_relayerIndependence_anySenderCanSubmit() public {
        address randomRelayer = address(0x7777);
        bytes memory params = abi.encode(agent, targetA, true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setTargetAllowed.selector, params);

        vm.prank(randomRelayer);
        guard.setTargetAllowed(accountId, agent, targetA, true, auth);

        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));
    }

    // ==========================================
    // PAY INTEGRATION & TARGET ALLOWLIST ENFORCEMENT
    // ==========================================

    function test_payIntegration_allowlistEnforcement() public {
        // anyTarget is false initially.
        // 1. Unlisted recipient: tryPay blocked & pay reverts
        assertFalse(guard.isTargetAllowed(accountId, agent, targetA));

        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(accountId, agent, targetA, 0.01 ether, ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED);
        (bool ok1, ISpendingGuard.PaymentBlockReason r1) = guard.tryPay(accountId, payable(targetA), 0.01 ether);
        assertFalse(ok1);
        assertEq(uint256(r1), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.TargetNotAllowed.selector, accountId, agent, targetA));
        guard.pay(accountId, payable(targetA), 0.01 ether);

        // 2. Add targetA to allowlist: both isTargetAllowed and tryPay succeed
        _setTargetAllowed(accountId, agent, targetA, true);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        vm.prank(agent);
        (bool ok2, ISpendingGuard.PaymentBlockReason r2) = guard.tryPay(accountId, payable(targetA), 0.01 ether);
        assertTrue(ok2);
        assertEq(uint256(r2), uint256(ISpendingGuard.PaymentBlockReason.NONE));

        vm.prank(agent);
        guard.pay(accountId, payable(targetA), 0.01 ether);

        // 3. Remove targetA from allowlist: blocked again
        _setTargetAllowed(accountId, agent, targetA, false);
        assertFalse(guard.isTargetAllowed(accountId, agent, targetA));

        vm.prank(agent);
        (bool ok3, ISpendingGuard.PaymentBlockReason r3) = guard.tryPay(accountId, payable(targetA), 0.01 ether);
        assertFalse(ok3);
        assertEq(uint256(r3), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));
    }

    function test_payIntegration_allowlistAccountAndAgentIsolation() public {
        // Register otherAgent for accountId
        bytes memory paramsAdd = abi.encode(otherAgent, uint128(0.1 ether), false);
        guard.addAgent(
            accountId, otherAgent, 0.1 ether, false, _signAction(accountId, guard.addAgent.selector, paramsAdd)
        );

        // Allow targetA only for agent under accountId
        _setTargetAllowed(accountId, agent, targetA, true);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));

        // otherAgent in accountId cannot pay targetA
        assertFalse(guard.isTargetAllowed(accountId, otherAgent, targetA));
        vm.prank(otherAgent);
        (bool ok1, ISpendingGuard.PaymentBlockReason r1) = guard.tryPay(accountId, payable(targetA), 0.01 ether);
        assertFalse(ok1);
        assertEq(uint256(r1), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));

        // otherAccountId cannot use targetA allowlist
        assertFalse(guard.isTargetAllowed(otherAccountId, otherAgent, targetA));
        vm.prank(otherAgent);
        (bool ok2, ISpendingGuard.PaymentBlockReason r2) = guard.tryPay(otherAccountId, payable(targetA), 0.01 ether);
        assertFalse(ok2);
        assertEq(uint256(r2), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));
    }

    function test_payIntegration_anyTargetIgnoresListExceptAddressZero() public {
        // Enable anyTarget for agent
        _setAnyTarget(accountId, agent, true);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));
        assertTrue(guard.isTargetAllowed(accountId, agent, targetB));

        // targetA succeeds without being in allowlist
        vm.prank(agent);
        (bool okA,) = guard.tryPay(accountId, payable(targetA), 0.01 ether);
        assertTrue(okA);

        // address(0) is ALWAYS blocked, even with anyTarget = true
        assertFalse(guard.isTargetAllowed(accountId, agent, address(0)));
        vm.prank(agent);
        (bool okZero, ISpendingGuard.PaymentBlockReason rZero) =
            guard.tryPay(accountId, payable(address(0)), 0.01 ether);
        assertFalse(okZero);
        assertEq(uint256(rZero), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.TargetNotAllowed.selector, accountId, agent, address(0)));
        guard.pay(accountId, payable(address(0)), 0.01 ether);

        // Turn anyTarget off: now targetB is blocked
        _setAnyTarget(accountId, agent, false);
        assertFalse(guard.isTargetAllowed(accountId, agent, targetB));
        vm.prank(agent);
        (bool okB, ISpendingGuard.PaymentBlockReason rB) = guard.tryPay(accountId, payable(targetB), 0.01 ether);
        assertFalse(okB);
        assertEq(uint256(rB), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));

        // Turn anyTarget back on: targetB is allowed again
        _setAnyTarget(accountId, agent, true);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetB));
        vm.prank(agent);
        (bool okB2,) = guard.tryPay(accountId, payable(targetB), 0.01 ether);
        assertTrue(okB2);
    }

    function test_isTargetAllowed_agreesWithTryPayInEveryState() public {
        address[] memory targets = new address[](3);
        targets[0] = address(0);
        targets[1] = targetA;
        targets[2] = targetB;

        // State 1: anyTarget = false, no targets allowlisted
        for (uint256 i = 0; i < targets.length; i++) {
            bool viewAllowed = guard.isTargetAllowed(accountId, agent, targets[i]);
            vm.prank(agent);
            (bool ok,) = guard.tryPay(accountId, payable(targets[i]), 0.001 ether);
            assertEq(viewAllowed, ok, "State 1 mismatch");
        }

        // State 2: targetA allowlisted
        _setTargetAllowed(accountId, agent, targetA, true);
        for (uint256 i = 0; i < targets.length; i++) {
            bool viewAllowed = guard.isTargetAllowed(accountId, agent, targets[i]);
            vm.prank(agent);
            (bool ok,) = guard.tryPay(accountId, payable(targets[i]), 0.001 ether);
            assertEq(viewAllowed, ok, "State 2 mismatch");
        }

        // State 3: anyTarget = true
        _setAnyTarget(accountId, agent, true);
        for (uint256 i = 0; i < targets.length; i++) {
            bool viewAllowed = guard.isTargetAllowed(accountId, agent, targets[i]);
            vm.prank(agent);
            (bool ok,) = guard.tryPay(accountId, payable(targets[i]), 0.001 ether);
            assertEq(viewAllowed, ok, "State 3 mismatch");
        }

        // State 4: anyTarget = false again, targetA removed
        _setAnyTarget(accountId, agent, false);
        _setTargetAllowed(accountId, agent, targetA, false);
        for (uint256 i = 0; i < targets.length; i++) {
            bool viewAllowed = guard.isTargetAllowed(accountId, agent, targets[i]);
            vm.prank(agent);
            (bool ok,) = guard.tryPay(accountId, payable(targets[i]), 0.001 ether);
            assertEq(viewAllowed, ok, "State 4 mismatch");
        }
    }

    // ==========================================
    // FUZZ TEST: REFERENCE MODEL COMPARISON
    // ==========================================

    function testFuzz_allowlistMatchesReferenceModel(uint8[6] memory ops) public {
        bool modelAnyTarget = false;
        address[3] memory sampleTargets = [targetA, targetB, address(0x9999)];
        bool[3] memory refAllowed = [false, false, false];

        for (uint256 i = 0; i < 6; i++) {
            uint8 op = ops[i] % 3;
            uint256 tIdx = i % 3;
            address selectedTarget = sampleTargets[tIdx];

            if (op == 0) {
                // Toggle allowlist entry
                bool newAllowed = (i % 2 == 0);
                _setTargetAllowed(accountId, agent, selectedTarget, newAllowed);
                refAllowed[tIdx] = newAllowed;
            } else if (op == 1) {
                // Toggle anyTarget
                bool newAnyTarget = (i % 2 == 1);
                _setAnyTarget(accountId, agent, newAnyTarget);
                modelAnyTarget = newAnyTarget;
            } else {
                // Verify agreement
                bool expected = (selectedTarget != address(0)) && (modelAnyTarget || refAllowed[tIdx]);
                assertEq(guard.isTargetAllowed(accountId, agent, selectedTarget), expected);

                vm.prank(agent);
                (bool ok,) = guard.tryPay(accountId, payable(selectedTarget), 0.001 ether);
                assertEq(ok, expected);
            }
        }
    }

    // ==========================================
    // INVARIANT: PAY / TRYPAY NEVER MUTATES ALLOWLIST OR NONCE
    // ==========================================

    function test_invariant_payNeverMutatesAllowlistOrNonce() public {
        _setTargetAllowed(accountId, agent, targetA, true);
        uint64 nonceBefore = guard.nonceOf(accountId);
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));
        assertFalse(guard.isTargetAllowed(accountId, agent, targetB));

        // Execute successful pay
        vm.prank(agent);
        guard.pay(accountId, payable(targetA), 0.01 ether);

        // Execute blocked tryPay
        vm.prank(agent);
        guard.tryPay(accountId, payable(targetB), 0.01 ether);

        // Nonce of account must NOT have changed from payments
        assertEq(guard.nonceOf(accountId), nonceBefore);

        // Permissions must NOT have changed
        assertTrue(guard.isTargetAllowed(accountId, agent, targetA));
        assertFalse(guard.isTargetAllowed(accountId, agent, targetB));
    }
}
