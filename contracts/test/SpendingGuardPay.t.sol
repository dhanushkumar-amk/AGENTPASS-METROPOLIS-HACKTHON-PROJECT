// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpendingGuardHarness} from "./harness/SpendingGuardHarness.sol";
import {ISpendingGuard} from "../src/interfaces/ISpendingGuard.sol";

contract MaliciousReentrantRecipient {
    SpendingGuardHarness public guard;
    bytes32 public accountId;
    bool public callTryPay;

    constructor(SpendingGuardHarness _guard, bytes32 _accountId, bool _callTryPay) {
        guard = _guard;
        accountId = _accountId;
        callTryPay = _callTryPay;
    }

    receive() external payable {
        if (callTryPay) {
            guard.tryPay(accountId, payable(address(this)), 0.01 ether);
        } else {
            guard.pay(accountId, payable(address(this)), 0.01 ether);
        }
    }
}

contract RevertingRecipient {
    receive() external payable {
        revert("Rejecting native MON");
    }
}

contract SpendingGuardPayTest is Test {
    SpendingGuardHarness internal guard;

    bytes32 internal testAccountId;
    bytes32 internal otherAccountId;

    address internal agent = address(0xAA01);
    address internal otherAgent = address(0xAA02);
    address internal recipient = address(0xBB01);

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

        // Account 1: 1 ether balance, agent with 0.05 ether daily limit, anyTarget = true
        testAccountId = guard.createFundedAccountWithAgent(
            bytes32(uint256(0x101)), bytes32(uint256(0x102)), 1 ether, agent, 0.05 ether, true
        );

        // Account 2: 0.5 ether balance, otherAgent with 0.03 ether daily limit, anyTarget = false
        otherAccountId = guard.createFundedAccountWithAgent(
            bytes32(uint256(0x201)), bytes32(uint256(0x202)), 0.5 ether, otherAgent, 0.03 ether, false
        );
    }

    // ==========================================
    // PAY & TRYPAY HAPPY PATHS
    // ==========================================

    function test_pay_happyPath() public {
        uint256 initialRecipientBalance = recipient.balance;
        uint256 payAmount = 0.02 ether;

        vm.expectEmit(true, true, true, true);
        emit PaymentExecuted(testAccountId, agent, recipient, payAmount);

        vm.prank(agent);
        guard.pay(testAccountId, payable(recipient), payAmount);

        assertEq(recipient.balance, initialRecipientBalance + payAmount);
        (,, uint256 balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, 1 ether - payAmount);

        (,, uint128 spentToday,,) = guard.agentOf(testAccountId, agent);
        assertEq(spentToday, payAmount);
        assertEq(guard.remainingToday(testAccountId, agent), 0.05 ether - payAmount);
    }

    function test_tryPay_happyPath() public {
        uint256 payAmount = 0.02 ether;

        vm.expectEmit(true, true, true, true);
        emit PaymentExecuted(testAccountId, agent, recipient, payAmount);

        vm.prank(agent);
        (bool ok, ISpendingGuard.PaymentBlockReason reason) = guard.tryPay(testAccountId, payable(recipient), payAmount);

        assertTrue(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.NONE));

        (,, uint128 spentToday,,) = guard.agentOf(testAccountId, agent);
        assertEq(spentToday, payAmount);
    }

    function test_pay_withCalldata_happyPath() public {
        vm.prank(agent);
        bytes memory res = guard.pay(testAccountId, payable(recipient), 0.01 ether, hex"");
        assertEq(res.length, 0);
    }

    function test_tryPay_withCalldata_happyPath() public {
        vm.prank(agent);
        (bool ok, ISpendingGuard.PaymentBlockReason reason, bytes memory res) =
            guard.tryPay(testAccountId, payable(recipient), 0.01 ether, hex"");
        assertTrue(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.NONE));
        assertEq(res.length, 0);
    }

    function test_isTargetAllowed_view() public {
        // testAccountId has anyTarget = true
        assertTrue(guard.isTargetAllowed(testAccountId, agent, recipient));
        // otherAccountId has anyTarget = false and recipient is not allowlisted
        assertFalse(guard.isTargetAllowed(otherAccountId, otherAgent, recipient));
        // test with harness setter
        guard.setTargetAllowedForTest(otherAccountId, otherAgent, recipient, true);
        assertTrue(guard.isTargetAllowed(otherAccountId, otherAgent, recipient));
    }

    // ==========================================
    // ALL REASON CODES VIA TRYPAY (NON-REVERTING)
    // ==========================================

    function test_tryPay_blocked_zeroAmount() public {
        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(testAccountId, agent, recipient, 0, ISpendingGuard.PaymentBlockReason.ZERO_AMOUNT);

        (bool ok, ISpendingGuard.PaymentBlockReason reason) = guard.tryPay(testAccountId, payable(recipient), 0);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.ZERO_AMOUNT));
        _assertStateUnchanged(testAccountId, agent, 1 ether, 0);
    }

    function test_tryPay_blocked_agentNotActive_stranger() public {
        address stranger = address(0x999);
        vm.prank(stranger);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            testAccountId, stranger, recipient, 0.01 ether, ISpendingGuard.PaymentBlockReason.AGENT_NOT_ACTIVE
        );

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(recipient), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.AGENT_NOT_ACTIVE));
        _assertStateUnchanged(testAccountId, agent, 1 ether, 0);
    }

    function test_tryPay_blocked_agentNotActive_wrongAccount() public {
        // Agent is valid for testAccountId, but attempts to spend from otherAccountId
        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            otherAccountId, agent, recipient, 0.01 ether, ISpendingGuard.PaymentBlockReason.AGENT_NOT_ACTIVE
        );

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(otherAccountId, payable(recipient), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.AGENT_NOT_ACTIVE));
        _assertStateUnchanged(testAccountId, agent, 1 ether, 0);
    }

    function test_tryPay_blocked_paused() public {
        guard.setPausedForTest(testAccountId, true);

        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(testAccountId, agent, recipient, 0.01 ether, ISpendingGuard.PaymentBlockReason.PAUSED);

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(recipient), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.PAUSED));
        _assertStateUnchanged(testAccountId, agent, 1 ether, 0);
    }

    function test_tryPay_blocked_targetNotAllowed_zeroAddress() public {
        // Even with anyTarget = true, address(0) is strictly disallowed
        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            testAccountId, agent, address(0), 0.01 ether, ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED
        );

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(address(0)), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));
        _assertStateUnchanged(testAccountId, agent, 1 ether, 0);
    }

    function test_tryPay_blocked_targetNotAllowed_disallowedAddress() public {
        // otherAgent has anyTarget = false and recipient is not allowlisted
        vm.prank(otherAgent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            otherAccountId, otherAgent, recipient, 0.01 ether, ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED
        );

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(otherAccountId, payable(recipient), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.TARGET_NOT_ALLOWED));
        _assertStateUnchanged(otherAccountId, otherAgent, 0.5 ether, 0);
    }

    function test_tryPay_blocked_overDailyLimit() public {
        // Daily limit is 0.05 ether; requested is 0.06 ether
        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            testAccountId, agent, recipient, 0.06 ether, ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT
        );

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(recipient), 0.06 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
        _assertStateUnchanged(testAccountId, agent, 1 ether, 0);
    }

    function test_tryPay_blocked_insufficientVaultBalance() public {
        // Create an account with 0.01 ether balance but 0.05 ether daily limit
        bytes32 lowBalAccount = guard.createFundedAccountWithAgent(
            bytes32(uint256(0x301)), bytes32(uint256(0x302)), 0.01 ether, agent, 0.05 ether, true
        );

        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            lowBalAccount, agent, recipient, 0.02 ether, ISpendingGuard.PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE
        );

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(lowBalAccount, payable(recipient), 0.02 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE));
        _assertStateUnchanged(lowBalAccount, agent, 0.01 ether, 0);
    }

    // ==========================================
    // ALL REASON CODES VIA PAY() (REVERTING)
    // ==========================================

    function test_pay_revert_zeroAmount() public {
        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.pay(testAccountId, payable(recipient), 0);
    }

    function test_pay_revert_agentNotActive_stranger() public {
        address stranger = address(0x999);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, testAccountId, stranger));
        guard.pay(testAccountId, payable(recipient), 0.01 ether);
    }

    function test_pay_revert_agentNotActive_wrongAccount() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, otherAccountId, agent));
        guard.pay(otherAccountId, payable(recipient), 0.01 ether);
    }

    function test_pay_revert_paused() public {
        guard.setPausedForTest(testAccountId, true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountPaused.selector, testAccountId));
        guard.pay(testAccountId, payable(recipient), 0.01 ether);
    }

    function test_pay_revert_targetNotAllowed_zeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ISpendingGuard.TargetNotAllowed.selector, testAccountId, agent, address(0))
        );
        guard.pay(testAccountId, payable(address(0)), 0.01 ether);
    }

    function test_pay_revert_targetNotAllowed_disallowedAddress() public {
        vm.prank(otherAgent);
        vm.expectRevert(
            abi.encodeWithSelector(ISpendingGuard.TargetNotAllowed.selector, otherAccountId, otherAgent, recipient)
        );
        guard.pay(otherAccountId, payable(recipient), 0.01 ether);
    }

    function test_pay_revert_overDailyLimit() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpendingGuard.DailyLimitExceeded.selector,
                testAccountId,
                agent,
                uint128(0.06 ether),
                uint128(0.05 ether)
            )
        );
        guard.pay(testAccountId, payable(recipient), 0.06 ether);
    }

    function test_pay_revert_insufficientVaultBalance() public {
        bytes32 lowBalAccount = guard.createFundedAccountWithAgent(
            bytes32(uint256(0x301)), bytes32(uint256(0x302)), 0.01 ether, agent, 0.05 ether, true
        );
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ISpendingGuard.InsufficientBalance.selector, lowBalAccount, 0.02 ether, 0.01 ether)
        );
        guard.pay(lowBalAccount, payable(recipient), 0.02 ether);
    }

    // ==========================================
    // BOUNDARIES & OVERFLOW PROTECTION
    // ==========================================

    function test_boundaries_payExactDailyLimitSucceeds() public {
        vm.prank(agent);
        guard.pay(testAccountId, payable(recipient), 0.05 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0);
    }

    function test_boundaries_payDailyLimitPlusOneWeiBlocked() public {
        vm.prank(agent);
        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(recipient), 0.05 ether + 1);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
    }

    function test_boundaries_typeUint256MaxBlockedWithoutOverflow() public {
        vm.prank(agent);
        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(recipient), type(uint256).max);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
    }

    function test_cumulative_multiplePaymentsAddUp() public {
        vm.startPrank(agent);
        guard.pay(testAccountId, payable(recipient), 0.02 ether);
        guard.pay(testAccountId, payable(recipient), 0.02 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0.01 ether);

        (bool ok, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(testAccountId, payable(recipient), 0.02 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
        vm.stopPrank();
    }

    // ==========================================
    // DEMO SCRIPT TEST (4 EXACT STEPS)
    // ==========================================

    function testDemo_scriptExactNumbers() public {
        // Vault: 0.1 ether, Agent daily limit: 0.05 ether, anyTarget: true
        bytes32 demoAccountId = guard.createFundedAccountWithAgent(
            bytes32(uint256(0x901)), bytes32(uint256(0x902)), 0.1 ether, agent, 0.05 ether, true
        );

        vm.startPrank(agent);

        // Step 1: tryPay 0.02 MON -> ok
        vm.expectEmit(true, true, true, true);
        emit PaymentExecuted(demoAccountId, agent, recipient, 0.02 ether);
        {
            (bool ok, ISpendingGuard.PaymentBlockReason reason) =
                guard.tryPay(demoAccountId, payable(recipient), 0.02 ether);
            assertTrue(ok);
            assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.NONE));
            _assertBalancesAndSpent(demoAccountId, agent, 0.08 ether, 0.02 ether, 0.03 ether);
        }

        // Step 2: tryPay 0.06 MON -> blocked OVER_DAILY_LIMIT
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            demoAccountId, agent, recipient, 0.06 ether, ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT
        );
        {
            (bool ok, ISpendingGuard.PaymentBlockReason reason) =
                guard.tryPay(demoAccountId, payable(recipient), 0.06 ether);
            assertFalse(ok);
            assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
            _assertBalancesAndSpent(demoAccountId, agent, 0.08 ether, 0.02 ether, 0.03 ether);
        }

        // Step 3: tryPay 0.02 MON -> ok (cumulative 0.04 MON)
        vm.expectEmit(true, true, true, true);
        emit PaymentExecuted(demoAccountId, agent, recipient, 0.02 ether);
        {
            (bool ok, ISpendingGuard.PaymentBlockReason reason) =
                guard.tryPay(demoAccountId, payable(recipient), 0.02 ether);
            assertTrue(ok);
            assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.NONE));
            _assertBalancesAndSpent(demoAccountId, agent, 0.06 ether, 0.04 ether, 0.01 ether);
        }

        // Step 4: tryPay 0.02 MON -> blocked OVER_DAILY_LIMIT (0.04 + 0.02 = 0.06 > 0.05)
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(
            demoAccountId, agent, recipient, 0.02 ether, ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT
        );
        {
            (bool ok, ISpendingGuard.PaymentBlockReason reason) =
                guard.tryPay(demoAccountId, payable(recipient), 0.02 ether);
            assertFalse(ok);
            assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
            _assertBalancesAndSpent(demoAccountId, agent, 0.06 ether, 0.04 ether, 0.01 ether);
        }

        vm.stopPrank();
    }

    // ==========================================
    // DAY ROLLOVER LOGIC
    // ==========================================

    function test_dayRollover_boundaryTransitions() public {
        vm.prank(agent);
        guard.pay(testAccountId, payable(recipient), 0.05 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0);

        uint256 todayIndex = block.timestamp / 1 days;
        uint256 nextDayBoundary = (todayIndex + 1) * 1 days;

        // Warp to 1 second before next day boundary: still blocked
        vm.warp(nextDayBoundary - 1);
        assertEq(guard.remainingToday(testAccountId, agent), 0);
        vm.prank(agent);
        (bool okBefore,) = guard.tryPay(testAccountId, payable(recipient), 0.01 ether);
        assertFalse(okBefore);

        // Warp exactly to next day boundary: full limit restored
        vm.warp(nextDayBoundary);
        assertEq(guard.remainingToday(testAccountId, agent), 0.05 ether);
        vm.prank(agent);
        (bool okAtBoundary,) = guard.tryPay(testAccountId, payable(recipient), 0.02 ether);
        assertTrue(okAtBoundary);

        (,, uint128 spentToday,,) = guard.agentOf(testAccountId, agent);
        assertEq(spentToday, 0.02 ether);
    }

    // ==========================================
    // REMAINING TODAY VIEW & MID-DAY LIMIT CHANGES
    // ==========================================

    function test_remainingToday_variousStates() public {
        // Inactive agent returns 0
        address inactiveAgent = address(0x888);
        assertEq(guard.remainingToday(testAccountId, inactiveAgent), 0);

        // Full limit for new agent
        assertEq(guard.remainingToday(testAccountId, agent), 0.05 ether);

        // Reduced after spending
        vm.prank(agent);
        guard.pay(testAccountId, payable(recipient), 0.03 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0.02 ether);

        // Lowered mid-day below spent amount: floors at 0 without underflow
        guard.setDailyLimitForTest(testAccountId, agent, 0.02 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0);

        // Raised mid-day: expands allowance and unlocks previously blocked payment
        guard.setDailyLimitForTest(testAccountId, agent, 0.08 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0.05 ether);

        vm.prank(agent);
        (bool okAfterRaise,) = guard.tryPay(testAccountId, payable(recipient), 0.04 ether);
        assertTrue(okAfterRaise);
    }

    // ==========================================
    // MULTI-ACCOUNT ISOLATION
    // ==========================================

    function test_isolation_agentInTwoAccountsIndependent() public {
        // Add same agent to otherAccountId with different limit (0.02 ether)
        bytes memory params = abi.encode(agent, 0.02 ether, true);
        uint64 nonce = guard.nonceOf(otherAccountId);
        bytes32 digest = guard.actionHash(otherAccountId, nonce, guard.addAgent.selector, params);
        ISpendingGuard.WebAuthnAuth memory auth = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: uint256(digest), s: 1
        });
        guard.addAgent(otherAccountId, agent, 0.02 ether, true, auth);

        // Spend from account 1
        vm.prank(agent);
        guard.pay(testAccountId, payable(recipient), 0.04 ether);
        assertEq(guard.remainingToday(testAccountId, agent), 0.01 ether);
        assertEq(guard.remainingToday(otherAccountId, agent), 0.02 ether); // Account 2 untouched

        // Agent cannot spend more than account 2 limit on account 2
        vm.prank(agent);
        (bool ok2,) = guard.tryPay(otherAccountId, payable(recipient), 0.03 ether);
        assertFalse(ok2);
    }

    // ==========================================
    // REENTRANCY TESTS (Match T6: Reentr)
    // ==========================================

    function test_Reentrancy_payReverts() public {
        MaliciousReentrantRecipient attacker = new MaliciousReentrantRecipient(guard, testAccountId, false);

        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.PaymentTransferFailed.selector);
        guard.pay(testAccountId, payable(address(attacker)), 0.02 ether);

        // Assert state fully rolled back
        (,, uint256 balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, 1 ether);
        (,, uint128 spentToday,,) = guard.agentOf(testAccountId, agent);
        assertEq(spentToday, 0);
    }

    function test_Reentrancy_tryPayReverts() public {
        MaliciousReentrantRecipient attacker = new MaliciousReentrantRecipient(guard, testAccountId, true);

        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.PaymentTransferFailed.selector);
        guard.tryPay(testAccountId, payable(address(attacker)), 0.02 ether);

        // Assert state fully rolled back
        (,, uint256 balance,,) = guard.accountOf(testAccountId);
        assertEq(balance, 1 ether);
        (,, uint128 spentToday,,) = guard.agentOf(testAccountId, agent);
        assertEq(spentToday, 0);
    }

    // ==========================================
    // RECIPIENT REJECTION & SELF-TRANSFER TESTS
    // ==========================================

    function test_recipientRejection_revertsTransferFailed() public {
        RevertingRecipient rejecting = new RevertingRecipient();

        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.PaymentTransferFailed.selector);
        guard.pay(testAccountId, payable(address(rejecting)), 0.02 ether);

        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.PaymentTransferFailed.selector);
        guard.tryPay(testAccountId, payable(address(rejecting)), 0.02 ether);
    }

    function test_recipientSpendingGuardSelf_failsSafely() public {
        // Paying guard's own address fails safely because receive() reverts
        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.PaymentTransferFailed.selector);
        guard.pay(testAccountId, payable(address(guard)), 0.02 ether);

        vm.prank(agent);
        vm.expectRevert(ISpendingGuard.PaymentTransferFailed.selector);
        guard.tryPay(testAccountId, payable(address(guard)), 0.02 ether);
    }

    // ==========================================
    // FUZZ TEST
    // ==========================================

    function testFuzz_paymentsAndWarpsBoundedByLimit(uint128[4] memory amounts, uint16[4] memory timeJumps) public {
        uint256 currentDeposit = 100 ether;
        bytes32 fuzzAccountId = guard.createFundedAccountWithAgent(
            bytes32(uint256(0xF1)), bytes32(uint256(0xF2)), uint128(currentDeposit), agent, 10 ether, true
        );

        uint256 totalPaidSuccess = 0;

        for (uint256 i = 0; i < 4; i++) {
            // Jump time forward
            vm.warp(block.timestamp + uint256(timeJumps[i]));

            uint256 amt = uint256(bound(uint256(amounts[i]), 1, 15 ether));
            uint256 available = guard.remainingToday(fuzzAccountId, agent);

            vm.prank(agent);
            (bool ok,) = guard.tryPay(fuzzAccountId, payable(recipient), amt);

            if (ok) {
                totalPaidSuccess += amt;
                assertTrue(amt <= available);
            }

            (,, uint128 spentToday,,) = guard.agentOf(fuzzAccountId, agent);
            assertTrue(spentToday <= 10 ether);
        }

        (,, uint256 finalBalance,,) = guard.accountOf(fuzzAccountId);
        assertEq(totalPaidSuccess + finalBalance, currentDeposit);
    }

    // ==========================================
    // INTERNAL HELPERS
    // ==========================================

    function _assertStateUnchanged(bytes32 accId, address ag, uint256 expectedBalance, uint128 expectedSpent)
        internal
        view
    {
        (,, uint256 bal,,) = guard.accountOf(accId);
        (,, uint128 spent,,) = guard.agentOf(accId, ag);
        assertEq(bal, expectedBalance);
        assertEq(spent, expectedSpent);
    }

    function _assertBalancesAndSpent(
        bytes32 accId,
        address ag,
        uint256 expectedBal,
        uint128 expectedSpent,
        uint256 expectedRemaining
    ) internal view {
        (,, uint256 bal,,) = guard.accountOf(accId);
        (,, uint128 spent,,) = guard.agentOf(accId, ag);
        assertEq(bal, expectedBal);
        assertEq(spent, expectedSpent);
        assertEq(guard.remainingToday(accId, ag), expectedRemaining);
    }
}
