// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpendingGuardHarness} from "./harness/SpendingGuardHarness.sol";
import {ISpendingGuard} from "../src/interfaces/ISpendingGuard.sol";

contract SpendingGuardBaseTest is Test {
    SpendingGuardHarness internal guard;

    bytes32 internal constant TEST_QX = bytes32(uint256(0x1111));
    bytes32 internal constant TEST_QY = bytes32(uint256(0x2222));
    bytes32 internal testAccountId;

    address internal ownerAgent1 = address(0xAA11);
    address internal ownerAgent2 = address(0xAA22);
    address internal relayer1 = address(0xBB11);
    address internal relayer2 = address(0xBB22);

    event AccountCreated(bytes32 indexed accountId, bytes32 qx, bytes32 qy);
    event Deposited(bytes32 indexed accountId, address indexed sender, uint256 amount);
    event AgentAdded(bytes32 indexed accountId, address indexed agent, uint128 dailyLimit, bool anyTarget);

    function setUp() public {
        guard = new SpendingGuardHarness();
        testAccountId = guard.createAccount(TEST_QX, TEST_QY);
    }

    // Helper to generate mock WebAuthnAuth accepted by SpendingGuardHarness
    function _mockAuth(bytes32 digest) internal pure returns (ISpendingGuard.WebAuthnAuth memory) {
        return ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: uint256(digest), s: 1
        });
    }

    // ==========================================
    // CREATE ACCOUNT TESTS
    // ==========================================

    function test_createAccount_correctAccountId() public {
        bytes32 qx = bytes32(uint256(0x3333));
        bytes32 qy = bytes32(uint256(0x4444));
        bytes32 expectedId = keccak256(abi.encode(qx, qy));

        bytes32 accountId = guard.createAccount(qx, qy);
        assertEq(accountId, expectedId);

        (bytes32 storedQx, bytes32 storedQy, uint256 balance, uint64 nonce, bool paused) = guard.accountOf(accountId);
        assertEq(storedQx, qx);
        assertEq(storedQy, qy);
        assertEq(balance, 0);
        assertEq(nonce, 0);
        assertFalse(paused);
    }

    function test_createAccount_emitsEvent() public {
        bytes32 qx = bytes32(uint256(0x5555));
        bytes32 qy = bytes32(uint256(0x6666));
        bytes32 expectedId = keccak256(abi.encode(qx, qy));

        vm.expectEmit(true, false, false, true);
        emit AccountCreated(expectedId, qx, qy);

        guard.createAccount(qx, qy);
    }

    function test_createAccount_revert_duplicate() public {
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountAlreadyExists.selector, testAccountId));
        guard.createAccount(TEST_QX, TEST_QY);
    }

    function test_createAccount_revert_zeroKey() public {
        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.createAccount(bytes32(0), TEST_QY);

        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.createAccount(TEST_QX, bytes32(0));
    }

    function test_createAccount_twoDifferentKeysGiveTwoAccounts() public {
        bytes32 qx1 = bytes32(uint256(0x7771));
        bytes32 qy1 = bytes32(uint256(0x7772));
        bytes32 qx2 = bytes32(uint256(0x8881));
        bytes32 qy2 = bytes32(uint256(0x8882));

        bytes32 id1 = guard.createAccount(qx1, qy1);
        bytes32 id2 = guard.createAccount(qx2, qy2);

        assertTrue(id1 != id2);
        (bytes32 storedQx1,,,,) = guard.accountOf(id1);
        (bytes32 storedQx2,,,,) = guard.accountOf(id2);
        assertEq(storedQx1, qx1);
        assertEq(storedQx2, qx2);
    }

    // ==========================================
    // DEPOSIT TESTS
    // ==========================================

    function test_deposit_increasesBalance() public {
        vm.deal(address(this), 1 ether);
        guard.deposit{value: 0.5 ether}(testAccountId);

        (,, uint256 balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, 0.5 ether);

        guard.deposit{value: 0.3 ether}(testAccountId);
        (,, balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, 0.8 ether);
    }

    function test_deposit_emitsEvent() public {
        vm.deal(address(this), 1 ether);

        vm.expectEmit(true, true, false, true);
        emit Deposited(testAccountId, address(this), 0.5 ether);

        guard.deposit{value: 0.5 ether}(testAccountId);
    }

    function test_deposit_revert_unknownAccount() public {
        bytes32 unknownId = keccak256("unknown");
        vm.deal(address(this), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownId));
        guard.deposit{value: 0.5 ether}(unknownId);
    }

    function test_deposit_revert_zeroValue() public {
        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.deposit{value: 0}(testAccountId);
    }

    function test_deposit_revert_plainTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(guard).call{value: 0.1 ether}("");
        assertFalse(ok);
    }

    function test_fallback_revert() public {
        (bool ok,) = address(guard).call(hex"deadbeef");
        assertFalse(ok);
    }

    function test_deposit_anyoneCanDeposit() public {
        address donor1 = address(0xDD01);
        address donor2 = address(0xDD02);

        vm.deal(donor1, 1 ether);
        vm.deal(donor2, 1 ether);

        vm.prank(donor1);
        guard.deposit{value: 0.2 ether}(testAccountId);

        vm.prank(donor2);
        guard.deposit{value: 0.3 ether}(testAccountId);

        (,, uint256 balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, 0.5 ether);
    }

    // ==========================================
    // ADD AGENT TESTS
    // ==========================================

    function test_addAgent_successPath() public {
        uint64 nonce = guard.nonceOf(testAccountId);
        uint128 dailyLimit = 0.05 ether;
        bool anyTarget = false;

        bytes memory params = abi.encode(ownerAgent1, dailyLimit, anyTarget);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);
        ISpendingGuard.WebAuthnAuth memory auth = _mockAuth(digest);

        vm.expectEmit(true, true, false, true);
        emit AgentAdded(testAccountId, ownerAgent1, dailyLimit, anyTarget);

        guard.addAgent(testAccountId, ownerAgent1, dailyLimit, anyTarget, auth);

        assertEq(guard.nonceOf(testAccountId), nonce + 1);

        (bool active, uint128 storedLimit, uint128 spentToday, uint64 dayIndex, bool storedAnyTarget) =
            guard.agentOf(testAccountId, ownerAgent1);
        assertTrue(active);
        assertEq(storedLimit, dailyLimit);
        assertEq(spentToday, 0);
        assertEq(dayIndex, uint64(block.timestamp / 1 days));
        assertFalse(storedAnyTarget);
        assertEq(guard.remainingToday(testAccountId, ownerAgent1), dailyLimit);
        assertFalse(guard.isTargetAllowed(testAccountId, ownerAgent1, address(0x1234)));
    }

    function test_addAgent_revert_zeroAgent() public {
        uint64 nonce = guard.nonceOf(testAccountId);
        bytes memory params = abi.encode(address(0), 0.05 ether, false);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, testAccountId, address(0)));
        guard.addAgent(testAccountId, address(0), 0.05 ether, false, _mockAuth(digest));
    }

    function test_addAgent_revert_zeroLimit() public {
        uint64 nonce = guard.nonceOf(testAccountId);
        bytes memory params = abi.encode(ownerAgent1, 0, false);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);

        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0, false, _mockAuth(digest));
    }

    function test_addAgent_revert_duplicateActiveAgent() public {
        uint64 nonce = guard.nonceOf(testAccountId);
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);

        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digest));

        // Try adding again
        uint64 nonce2 = guard.nonceOf(testAccountId);
        bytes32 digest2 = guard.actionHash(testAccountId, nonce2, guard.addAgent.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, testAccountId, ownerAgent1));
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digest2));
    }

    function test_addAgent_revert_unknownAccount() public {
        bytes32 unknownId = keccak256("unknown");
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digest = guard.actionHash(unknownId, 0, guard.addAgent.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownId));
        guard.addAgent(unknownId, ownerAgent1, 0.05 ether, false, _mockAuth(digest));
    }

    // ==========================================
    // DIGEST BINDING & SECURITY TESTS
    // ==========================================

    function test_digestBinding_revert_wrongAccountId() public {
        bytes32 otherId = guard.createAccount(bytes32(uint256(0x9991)), bytes32(uint256(0x9992)));
        uint64 nonce = guard.nonceOf(testAccountId);

        // Digest computed for otherId, but executed against testAccountId
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digestWrong = guard.actionHash(otherId, nonce, guard.addAgent.selector, params);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digestWrong));
    }

    function test_digestBinding_revert_wrongParams() public {
        uint64 nonce = guard.nonceOf(testAccountId);

        // Digest computed for 0.05 ether, but executed with 0.10 ether
        bytes memory paramsSigned = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, paramsSigned);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0.1 ether, false, _mockAuth(digest));
    }

    function test_digestBinding_revert_wrongActionSelector() public {
        uint64 nonce = guard.nonceOf(testAccountId);

        // Digest signed for setDailyLimit selector instead of addAgent selector
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digestWrong = guard.actionHash(testAccountId, nonce, guard.setDailyLimit.selector, params);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digestWrong));
    }

    function test_digestBinding_revert_wrongContractAddress() public {
        SpendingGuardHarness otherGuard = new SpendingGuardHarness();
        uint64 nonce = guard.nonceOf(testAccountId);

        // Digest computed using otherGuard address
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digestWrong = otherGuard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digestWrong));
    }

    function test_digestBinding_revert_wrongChainId() public {
        uint64 nonce = guard.nonceOf(testAccountId);
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);

        // Change chain ID
        vm.chainId(99999);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digest));
    }

    // ==========================================
    // REPLAY ATTACK TESTS
    // ==========================================

    function test_replay_revert_reusedAuth() public {
        uint64 nonce = guard.nonceOf(testAccountId);
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);
        ISpendingGuard.WebAuthnAuth memory auth = _mockAuth(digest);

        // First call succeeds
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, auth);

        // Replaying the exact same auth fails because nonce has moved from 0 to 1
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent2, 0.05 ether, false, auth);
    }

    function test_replay_revert_futureNonceAuth() public {
        uint64 nonce = guard.nonceOf(testAccountId);

        // Generate auth for nonce + 1
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digestFuture = guard.actionHash(testAccountId, nonce + 1, guard.addAgent.selector, params);

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digestFuture));
    }

    // ==========================================
    // RELAYER INDEPENDENCE TESTS
    // ==========================================

    function test_relayerIndependence_anySenderCanSubmit() public {
        // Relayer 1 submits agent 1
        uint64 nonce1 = guard.nonceOf(testAccountId);
        bytes memory params1 = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 digest1 = guard.actionHash(testAccountId, nonce1, guard.addAgent.selector, params1);

        vm.prank(relayer1);
        guard.addAgent(testAccountId, ownerAgent1, 0.05 ether, false, _mockAuth(digest1));

        // Relayer 2 submits agent 2
        uint64 nonce2 = guard.nonceOf(testAccountId);
        bytes memory params2 = abi.encode(ownerAgent2, 0.03 ether, true);
        bytes32 digest2 = guard.actionHash(testAccountId, nonce2, guard.addAgent.selector, params2);

        vm.prank(relayer2);
        guard.addAgent(testAccountId, ownerAgent2, 0.03 ether, true, _mockAuth(digest2));

        (bool active1,,,,) = guard.agentOf(testAccountId, ownerAgent1);
        (bool active2,,,,) = guard.agentOf(testAccountId, ownerAgent2);
        assertTrue(active1);
        assertTrue(active2);
    }

    // ==========================================
    // FUZZ TESTS (Prefix: testFuzz_)
    // ==========================================

    function testFuzz_depositsSumToBalance(uint64[5] memory amounts) public {
        uint256 expectedSum = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 val = uint256(amounts[i]);
            if (val == 0) val = 1; // avoid ZeroAmount revert
            vm.deal(address(this), val);
            guard.deposit{value: val}(testAccountId);
            expectedSum += val;
        }

        (,, uint256 balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, expectedSum);
        assertEq(address(guard).balance, expectedSum);
    }

    function testFuzz_nonceIncreasesByExactlyOne(uint8 count) public {
        uint256 n = bound(uint256(count), 1, 20);
        uint64 initialNonce = guard.nonceOf(testAccountId);

        for (uint256 i = 0; i < n; i++) {
            address agent = address(uint160(0x9000 + i));
            uint64 nonce = guard.nonceOf(testAccountId);
            bytes memory params = abi.encode(agent, 0.01 ether, false);
            bytes32 digest = guard.actionHash(testAccountId, nonce, guard.addAgent.selector, params);

            guard.addAgent(testAccountId, agent, 0.01 ether, false, _mockAuth(digest));
            assertEq(guard.nonceOf(testAccountId), nonce + 1);
        }

        assertEq(guard.nonceOf(testAccountId), initialNonce + uint64(n));
    }

    function testFuzz_actionHashInjectiveAcrossNonces(uint64 nonceA, uint64 nonceB) public view {
        vm.assume(nonceA != nonceB);
        bytes memory params = abi.encode(ownerAgent1, 0.05 ether, false);
        bytes32 hashA = guard.actionHash(testAccountId, nonceA, guard.addAgent.selector, params);
        bytes32 hashB = guard.actionHash(testAccountId, nonceB, guard.addAgent.selector, params);

        assertTrue(hashA != hashB);
    }

    function testFuzz_createAccountRandomKeys(bytes32 qx, bytes32 qy) public {
        vm.assume(qx != bytes32(0) && qy != bytes32(0));
        vm.assume(qx != TEST_QX || qy != TEST_QY);
        bytes32 expectedId = keccak256(abi.encode(qx, qy));

        bytes32 accountId = guard.createAccount(qx, qy);
        assertEq(accountId, expectedId);

        (bytes32 storedQx, bytes32 storedQy,,, bool paused) = guard.accountOf(accountId);
        assertEq(storedQx, qx);
        assertEq(storedQy, qy);
        assertFalse(paused);
    }
}
