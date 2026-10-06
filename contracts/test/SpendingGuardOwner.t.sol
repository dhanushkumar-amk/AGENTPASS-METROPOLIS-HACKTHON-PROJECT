// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ISpendingGuard} from "../src/interfaces/ISpendingGuard.sol";
import {SpendingGuardHarness} from "./harness/SpendingGuardHarness.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("RejectingRecipient: rejected");
    }
}

contract ReentrantRecipient {
    SpendingGuardHarness public immutable guard;
    bytes32 public accountId;
    address public agent;
    uint8 public attackMode; // 1: withdraw, 2: pay, 3: tryPay

    constructor(SpendingGuardHarness _guard) {
        guard = _guard;
    }

    function setAttack(bytes32 _accountId, address _agent, uint8 _mode) external {
        accountId = _accountId;
        agent = _agent;
        attackMode = _mode;
    }

    receive() external payable {
        if (attackMode == 1) {
            // Reenter withdraw
            ISpendingGuard.WebAuthnAuth memory dummyAuth = ISpendingGuard.WebAuthnAuth({
                authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: 0, s: 0
            });
            guard.withdraw(accountId, payable(address(this)), 0.01 ether, dummyAuth);
        } else if (attackMode == 2) {
            // Reenter pay
            guard.pay(accountId, payable(address(this)), 0.01 ether, "");
        } else if (attackMode == 3) {
            // Reenter tryPay
            guard.tryPay(accountId, payable(address(this)), 0.01 ether, "");
        }
    }
}

contract SpendingGuardOwnerTest is Test {
    SpendingGuardHarness internal guard;

    bytes32 internal accountId;
    bytes32 internal otherAccountId;

    address internal agent = address(0xAA11);
    address internal otherAgent = address(0xBB22);
    address internal recipient = address(0xCC33);
    address internal stranger = address(0xDD44);

    event DailyLimitSet(bytes32 indexed accountId, address indexed agent, uint128 oldLimit, uint128 newLimit);
    event PausedSet(bytes32 indexed accountId, bool paused);
    event AgentRevoked(bytes32 indexed accountId, address indexed agent);
    event Withdrawn(bytes32 indexed accountId, address indexed recipient, uint256 amount);
    event Deposited(bytes32 indexed accountId, address indexed sender, uint256 amount);
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

        vm.deal(address(this), 100 ether);
        accountId = guard.createFundedAccountWithAgent{value: 1 ether}(
            bytes32(uint256(0x101)), bytes32(uint256(0x102)), 1 ether, agent, 0.05 ether, true
        );

        otherAccountId = guard.createFundedAccountWithAgent{value: 1 ether}(
            bytes32(uint256(0x201)), bytes32(uint256(0x202)), 1 ether, otherAgent, 0.05 ether, true
        );
    }

    function _signAction(bytes32 accId, bytes4 selector, bytes memory params)
        internal
        view
        returns (ISpendingGuard.WebAuthnAuth memory)
    {
        return guard.signActionHarness(accId, selector, params);
    }

    // ==========================================
    // 1. SET DAILY LIMIT TESTS
    // ==========================================

    function test_setDailyLimit_successAndEventAndNonce() public {
        uint64 nonceBefore = guard.nonceOf(accountId);
        uint128 newLimit = 0.1 ether;
        bytes memory params = abi.encode(agent, newLimit);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setDailyLimit.selector, params);

        vm.expectEmit(true, true, true, true);
        emit DailyLimitSet(accountId, agent, 0.05 ether, newLimit);

        guard.setDailyLimit(accountId, agent, newLimit, auth);

        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
        (, uint128 limit, uint128 spent,,) = guard.agentOf(accountId, agent);
        assertEq(limit, newLimit);
        assertEq(spent, 0);
        assertEq(guard.remainingToday(accountId, agent), newLimit);
    }

    function test_setDailyLimit_idempotent() public {
        uint64 nonceBefore = guard.nonceOf(accountId);
        uint128 sameLimit = 0.05 ether;
        bytes memory params = abi.encode(agent, sameLimit);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setDailyLimit.selector, params);

        vm.expectEmit(true, true, true, true);
        emit DailyLimitSet(accountId, agent, 0.05 ether, sameLimit);

        guard.setDailyLimit(accountId, agent, sameLimit, auth);

        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
        (, uint128 limit,,,) = guard.agentOf(accountId, agent);
        assertEq(limit, sameLimit);
    }

    function test_setDailyLimit_revert_zeroLimit() public {
        bytes memory params = abi.encode(agent, uint128(0));
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setDailyLimit.selector, params);

        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.setDailyLimit(accountId, agent, 0, auth);
    }

    function test_setDailyLimit_revert_inactiveAgent() public {
        address unadded = address(0x999);
        bytes memory params = abi.encode(unadded, uint128(0.1 ether));
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setDailyLimit.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, unadded));
        guard.setDailyLimit(accountId, unadded, 0.1 ether, auth);
    }

    function test_setDailyLimit_revert_unknownAccount() public {
        bytes32 unknownAcc = keccak256("unknown");
        bytes memory params = abi.encode(agent, uint128(0.1 ether));
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(unknownAcc, guard.setDailyLimit.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownAcc));
        guard.setDailyLimit(unknownAcc, agent, 0.1 ether, auth);
    }

    function test_setDailyLimit_revert_badAuth() public {
        ISpendingGuard.WebAuthnAuth memory badAuth = ISpendingGuard.WebAuthnAuth({
            authenticatorData: hex"", clientDataJSON: "", challengeIndex: 0, typeIndex: 0, r: 12345, s: 1
        });

        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(accountId, agent, 0.1 ether, badAuth);
    }

    function test_setDailyLimit_midDayAdjustmentsAndRollover() public {
        // Spend 0.03 ether today (limit 0.05 ether)
        vm.prank(agent);
        guard.pay(accountId, payable(recipient), 0.03 ether);
        assertEq(guard.remainingToday(accountId, agent), 0.02 ether);

        // Lower limit mid-day below spent amount (0.02 < 0.03 spent): remainingToday floors at 0 without underflow
        bytes memory paramsLower = abi.encode(agent, uint128(0.02 ether));
        guard.setDailyLimit(
            accountId, agent, 0.02 ether, _signAction(accountId, guard.setDailyLimit.selector, paramsLower)
        );
        assertEq(guard.remainingToday(accountId, agent), 0);

        // Further payments are blocked
        vm.prank(agent);
        (bool okBlocked, ISpendingGuard.PaymentBlockReason reason) =
            guard.tryPay(accountId, payable(recipient), 0.005 ether);
        assertFalse(okBlocked);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));

        // Raising limit mid-day (to 0.08 ether) restores capacity (0.08 - 0.03 = 0.05) and lets blocked payment pass
        bytes memory paramsRaise = abi.encode(agent, uint128(0.08 ether));
        guard.setDailyLimit(
            accountId, agent, 0.08 ether, _signAction(accountId, guard.setDailyLimit.selector, paramsRaise)
        );
        assertEq(guard.remainingToday(accountId, agent), 0.05 ether);

        vm.prank(agent);
        (bool okRaised,) = guard.tryPay(accountId, payable(recipient), 0.04 ether);
        assertTrue(okRaised);
        assertEq(guard.remainingToday(accountId, agent), 0.01 ether);

        // Now lower limit to 0.02 ether again
        bytes memory paramsLower2 = abi.encode(agent, uint128(0.02 ether));
        guard.setDailyLimit(
            accountId, agent, 0.02 ether, _signAction(accountId, guard.setDailyLimit.selector, paramsLower2)
        );
        assertEq(guard.remainingToday(accountId, agent), 0);

        // After day rolls over, lowered limit (0.02 ether) applies cleanly from start
        uint256 todayIndex = block.timestamp / 1 days;
        vm.warp((todayIndex + 1) * 1 days);
        assertEq(guard.remainingToday(accountId, agent), 0.02 ether);

        vm.prank(agent);
        (bool okNewDay,) = guard.tryPay(accountId, payable(recipient), 0.02 ether);
        assertTrue(okNewDay);
        assertEq(guard.remainingToday(accountId, agent), 0);
    }

    // ==========================================
    // 2. SET PAUSED TESTS
    // ==========================================

    function test_setPaused_successAndBlocking() public {
        uint64 nonceBefore = guard.nonceOf(accountId);
        bytes memory params = abi.encode(true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setPaused.selector, params);

        vm.expectEmit(true, true, true, true);
        emit PausedSet(accountId, true);

        guard.setPaused(accountId, true, auth);

        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
        (,,,, bool paused) = guard.accountOf(accountId);
        assertTrue(paused);

        // tryPay blocked with PAUSED
        vm.prank(agent);
        vm.expectEmit(true, true, true, true);
        emit PaymentBlocked(accountId, agent, recipient, 0.01 ether, ISpendingGuard.PaymentBlockReason.PAUSED);
        (bool ok, ISpendingGuard.PaymentBlockReason reason) = guard.tryPay(accountId, payable(recipient), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.PAUSED));

        // pay strictly reverts with AccountPaused
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountPaused.selector, accountId));
        guard.pay(accountId, payable(recipient), 0.01 ether);

        // Deposits still work while paused
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        guard.deposit{value: 0.5 ether}(accountId);
        (,, uint256 bal,,) = guard.accountOf(accountId);
        assertEq(bal, 1.5 ether);

        // Owner actions (including withdraw) still work while paused
        address payable withdrawDest = payable(address(0x7777));
        bytes memory paramsWithdraw = abi.encode(withdrawDest, 0.2 ether);
        ISpendingGuard.WebAuthnAuth memory authWithdraw =
            _signAction(accountId, guard.withdraw.selector, paramsWithdraw);
        guard.withdraw(accountId, withdrawDest, 0.2 ether, authWithdraw);
        assertEq(withdrawDest.balance, 0.2 ether);

        // Unpause restores payments
        bytes memory paramsUnpause = abi.encode(false);
        ISpendingGuard.WebAuthnAuth memory authUnpause = _signAction(accountId, guard.setPaused.selector, paramsUnpause);
        guard.setPaused(accountId, false, authUnpause);

        (,,,, bool unpaused) = guard.accountOf(accountId);
        assertFalse(unpaused);

        vm.prank(agent);
        (bool okAfterUnpause,) = guard.tryPay(accountId, payable(recipient), 0.01 ether);
        assertTrue(okAfterUnpause);
    }

    function test_setPaused_idempotent() public {
        uint64 nonceBefore = guard.nonceOf(accountId);
        bytes memory params = abi.encode(false);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.setPaused.selector, params);

        vm.expectEmit(true, true, true, true);
        emit PausedSet(accountId, false);

        guard.setPaused(accountId, false, auth);
        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
    }

    function test_setPaused_revert_unknownAccount() public {
        bytes32 unknownAcc = keccak256("unknown");
        bytes memory params = abi.encode(true);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(unknownAcc, guard.setPaused.selector, params);

        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownAcc));
        guard.setPaused(unknownAcc, true, auth);
    }

    // ==========================================
    // 3. REVOKE AGENT TESTS
    // ==========================================

    function test_revokeAgent_successAndEnforcement() public {
        uint64 nonceBefore = guard.nonceOf(accountId);
        bytes memory params = abi.encode(agent);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.revokeAgent.selector, params);

        vm.expectEmit(true, true, true, true);
        emit AgentRevoked(accountId, agent);

        guard.revokeAgent(accountId, agent, auth);

        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
        (bool active,,,,) = guard.agentOf(accountId, agent);
        assertFalse(active);

        // Revoked agent returns 0 for remainingToday and false for isTargetAllowed
        assertEq(guard.remainingToday(accountId, agent), 0);
        assertFalse(guard.isTargetAllowed(accountId, agent, recipient));

        // tryPay returns AGENT_NOT_ACTIVE
        vm.prank(agent);
        (bool ok, ISpendingGuard.PaymentBlockReason reason) = guard.tryPay(accountId, payable(recipient), 0.01 ether);
        assertFalse(ok);
        assertEq(uint256(reason), uint256(ISpendingGuard.PaymentBlockReason.AGENT_NOT_ACTIVE));

        // pay reverts with UnauthorizedAgent
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, agent));
        guard.pay(accountId, payable(recipient), 0.01 ether);

        // Revoking twice reverts (UnauthorizedAgent)
        bytes memory params2 = abi.encode(agent);
        ISpendingGuard.WebAuthnAuth memory auth2 = _signAction(accountId, guard.revokeAgent.selector, params2);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, agent));
        guard.revokeAgent(accountId, agent, auth2);

        // Re-adding the same address to this account reverts with AgentAlreadyRevoked
        bytes memory paramsReAdd = abi.encode(agent, uint128(0.05 ether), true);
        ISpendingGuard.WebAuthnAuth memory authReAdd = _signAction(accountId, guard.addAgent.selector, paramsReAdd);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AgentAlreadyRevoked.selector, accountId, agent));
        guard.addAgent(accountId, agent, 0.05 ether, true, authReAdd);

        // A revoked agent in account A is unaffected in otherAccountId
        // Let's add agent to otherAccountId: succeeds
        bytes memory paramsAddOther = abi.encode(agent, uint128(0.05 ether), true);
        ISpendingGuard.WebAuthnAuth memory authAddOther =
            _signAction(otherAccountId, guard.addAgent.selector, paramsAddOther);
        guard.addAgent(otherAccountId, agent, 0.05 ether, true, authAddOther);

        vm.prank(agent);
        (bool okOther,) = guard.tryPay(otherAccountId, payable(recipient), 0.01 ether);
        assertTrue(okOther);

        // Other agents in accountId are unaffected
        address agent2 = address(0xAA22);
        bytes memory paramsAdd2 = abi.encode(agent2, uint128(0.05 ether), true);
        ISpendingGuard.WebAuthnAuth memory authAdd2 = _signAction(accountId, guard.addAgent.selector, paramsAdd2);
        guard.addAgent(accountId, agent2, 0.05 ether, true, authAdd2);

        vm.prank(agent2);
        (bool okAgent2,) = guard.tryPay(accountId, payable(recipient), 0.01 ether);
        assertTrue(okAgent2);
    }

    function test_revokeAgent_revert_unknownAgentOrAccount() public {
        address unadded = address(0x888);
        bytes memory params = abi.encode(unadded);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.revokeAgent.selector, params);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, unadded));
        guard.revokeAgent(accountId, unadded, auth);

        bytes32 unknownAcc = keccak256("unknown");
        bytes memory params2 = abi.encode(agent);
        ISpendingGuard.WebAuthnAuth memory auth2 = _signAction(unknownAcc, guard.revokeAgent.selector, params2);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.AccountNotFound.selector, unknownAcc));
        guard.revokeAgent(unknownAcc, agent, auth2);
    }

    // ==========================================
    // 4. WITHDRAW TESTS
    // ==========================================

    function test_withdraw_success_partialAndFull() public {
        address payable chosenTo = payable(address(0x5555));
        uint256 startBal = chosenTo.balance;
        uint64 nonceBefore = guard.nonceOf(accountId);

        // Partial withdrawal of 0.4 ether
        bytes memory params1 = abi.encode(chosenTo, 0.4 ether);
        ISpendingGuard.WebAuthnAuth memory auth1 = _signAction(accountId, guard.withdraw.selector, params1);

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(accountId, chosenTo, 0.4 ether);

        guard.withdraw(accountId, chosenTo, 0.4 ether, auth1);

        assertEq(chosenTo.balance, startBal + 0.4 ether);
        assertEq(guard.nonceOf(accountId), nonceBefore + 1);
        (,, uint256 remainingBal,,) = guard.accountOf(accountId);
        assertEq(remainingBal, 0.6 ether);

        // Full withdrawal of remaining 0.6 ether
        bytes memory params2 = abi.encode(chosenTo, 0.6 ether);
        ISpendingGuard.WebAuthnAuth memory auth2 = _signAction(accountId, guard.withdraw.selector, params2);
        guard.withdraw(accountId, chosenTo, 0.6 ether, auth2);

        assertEq(chosenTo.balance, startBal + 1 ether);
        (,, uint256 finalBal,,) = guard.accountOf(accountId);
        assertEq(finalBal, 0);

        // After full withdrawal: tryPay returns INSUFFICIENT_VAULT_BALANCE when within daily limit,
        // or OVER_DAILY_LIMIT when amount exceeds daily limit (asserting exact check order!)
        vm.startPrank(agent);
        (bool ok1, ISpendingGuard.PaymentBlockReason reason1) = guard.tryPay(accountId, payable(recipient), 0.02 ether);
        assertFalse(ok1);
        assertEq(uint256(reason1), uint256(ISpendingGuard.PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE));

        (bool ok2, ISpendingGuard.PaymentBlockReason reason2) = guard.tryPay(accountId, payable(recipient), 0.1 ether);
        assertFalse(ok2);
        assertEq(uint256(reason2), uint256(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));
        vm.stopPrank();
    }

    function test_withdraw_reverts_boundariesAndInvalidTargets() public {
        address payable chosenTo = payable(address(0x5555));

        // Amount over balance reverts InsufficientBalance
        bytes memory paramsOver = abi.encode(chosenTo, 2 ether);
        ISpendingGuard.WebAuthnAuth memory authOver = _signAction(accountId, guard.withdraw.selector, paramsOver);
        vm.expectRevert(
            abi.encodeWithSelector(ISpendingGuard.InsufficientBalance.selector, accountId, 2 ether, 1 ether)
        );
        guard.withdraw(accountId, chosenTo, 2 ether, authOver);

        // Zero amount reverts ZeroAmount
        bytes memory paramsZero = abi.encode(chosenTo, 0);
        ISpendingGuard.WebAuthnAuth memory authZero = _signAction(accountId, guard.withdraw.selector, paramsZero);
        vm.expectRevert(ISpendingGuard.ZeroAmount.selector);
        guard.withdraw(accountId, chosenTo, 0, authZero);

        // Zero address reverts InvalidTarget
        bytes memory paramsZeroTo = abi.encode(address(0), 0.1 ether);
        ISpendingGuard.WebAuthnAuth memory authZeroTo = _signAction(accountId, guard.withdraw.selector, paramsZeroTo);
        vm.expectRevert(ISpendingGuard.InvalidTarget.selector);
        guard.withdraw(accountId, payable(address(0)), 0.1 ether, authZeroTo);

        // Address(this) reverts InvalidTarget
        bytes memory paramsThisTo = abi.encode(address(guard), 0.1 ether);
        ISpendingGuard.WebAuthnAuth memory authThisTo = _signAction(accountId, guard.withdraw.selector, paramsThisTo);
        vm.expectRevert(ISpendingGuard.InvalidTarget.selector);
        guard.withdraw(accountId, payable(address(guard)), 0.1 ether, authThisTo);
    }

    function test_withdraw_rejectingRecipientRevertsTransferFailed() public {
        RejectingRecipient rejector = new RejectingRecipient();
        uint64 nonceBefore = guard.nonceOf(accountId);

        bytes memory params = abi.encode(address(rejector), 0.1 ether);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.withdraw.selector, params);

        vm.expectRevert(ISpendingGuard.TransferFailed.selector);
        guard.withdraw(accountId, payable(address(rejector)), 0.1 ether, auth);

        // State rolls back: nonce and balance unchanged
        assertEq(guard.nonceOf(accountId), nonceBefore);
        (,, uint256 bal,,) = guard.accountOf(accountId);
        assertEq(bal, 1 ether);
    }

    function test_withdraw_Reentrancy_failsAndRollsBack() public {
        ReentrantRecipient attacker = new ReentrantRecipient(guard);
        uint64 nonceBefore = guard.nonceOf(accountId);

        // Attack mode 1: attacker tries to reenter withdraw
        attacker.setAttack(accountId, agent, 1);
        bytes memory params1 = abi.encode(address(attacker), 0.1 ether);
        ISpendingGuard.WebAuthnAuth memory auth1 = _signAction(accountId, guard.withdraw.selector, params1);

        vm.expectRevert(ISpendingGuard.TransferFailed.selector);
        guard.withdraw(accountId, payable(address(attacker)), 0.1 ether, auth1);
        assertEq(guard.nonceOf(accountId), nonceBefore);

        // Attack mode 2: attacker tries to reenter pay
        attacker.setAttack(accountId, agent, 2);
        bytes memory params2 = abi.encode(address(attacker), 0.1 ether);
        ISpendingGuard.WebAuthnAuth memory auth2 = _signAction(accountId, guard.withdraw.selector, params2);

        vm.expectRevert(ISpendingGuard.TransferFailed.selector);
        guard.withdraw(accountId, payable(address(attacker)), 0.1 ether, auth2);
        assertEq(guard.nonceOf(accountId), nonceBefore);

        // Attack mode 3: attacker tries to reenter tryPay
        attacker.setAttack(accountId, agent, 3);
        bytes memory params3 = abi.encode(address(attacker), 0.1 ether);
        ISpendingGuard.WebAuthnAuth memory auth3 = _signAction(accountId, guard.withdraw.selector, params3);

        vm.expectRevert(ISpendingGuard.TransferFailed.selector);
        guard.withdraw(accountId, payable(address(attacker)), 0.1 ether, auth3);
        assertEq(guard.nonceOf(accountId), nonceBefore);
    }

    // ==========================================
    // 5. RELAYER CANNOT REDIRECT TEST
    // ==========================================

    function test_relayerCannotRedirect_withdrawAuth() public {
        address payable intendedTo = payable(address(0x1111));
        address payable maliciousTo = payable(address(0x6666));
        uint256 intendedAmount = 0.5 ether;

        // Owner signs auth for intendedTo and intendedAmount
        bytes memory validParams = abi.encode(intendedTo, intendedAmount);
        ISpendingGuard.WebAuthnAuth memory auth = _signAction(accountId, guard.withdraw.selector, validParams);

        // Relayer attempts to redirect funds to maliciousTo -> REVERTS
        vm.prank(stranger);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.withdraw(accountId, maliciousTo, intendedAmount, auth);

        // Relayer attempts to alter amount to 0.6 ether -> REVERTS
        vm.prank(stranger);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.withdraw(accountId, intendedTo, 0.6 ether, auth);

        // Valid submission by stranger (relayer independence) -> SUCCEEDS
        vm.prank(stranger);
        guard.withdraw(accountId, intendedTo, intendedAmount, auth);
        assertEq(intendedTo.balance, intendedAmount);
    }

    // ==========================================
    // 6. DIGEST BINDING FOR ALL FOUR FUNCTIONS
    // ==========================================

    function test_digestBinding_allFourFunctions() public {
        // 1. setDailyLimit binding
        bytes memory limitParams = abi.encode(agent, uint128(0.1 ether));
        ISpendingGuard.WebAuthnAuth memory limitAuth = _signAction(accountId, guard.setDailyLimit.selector, limitParams);

        // Add agent to otherAccountId so agent is active for account check
        bytes memory addP = abi.encode(agent, uint128(0.05 ether), true);
        guard.addAgent(
            otherAccountId, agent, 0.05 ether, true, _signAction(otherAccountId, guard.addAgent.selector, addP)
        );

        // Wrong accountId
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(otherAccountId, agent, 0.1 ether, limitAuth);

        // Wrong params (different agent or different limit)
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(accountId, agent, 0.2 ether, limitAuth);

        // Wrong selector (reuse setPaused auth)
        bytes memory pauseParams = abi.encode(true);
        ISpendingGuard.WebAuthnAuth memory pauseAuth = _signAction(accountId, guard.setPaused.selector, pauseParams);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(accountId, agent, 0.1 ether, pauseAuth);

        // Wrong chainId
        uint256 origChainId = vm.getChainId();
        vm.chainId(99999);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(accountId, agent, 0.1 ether, limitAuth);
        vm.chainId(origChainId);

        // Wrong contract address
        SpendingGuardHarness secondGuard = new SpendingGuardHarness();
        vm.deal(address(this), 10 ether);
        bytes32 secondAcc = secondGuard.createFundedAccountWithAgent{value: 1 ether}(
            bytes32(uint256(0x301)), bytes32(uint256(0x302)), 1 ether, agent, 0.05 ether, true
        );
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        secondGuard.setDailyLimit(secondAcc, agent, 0.1 ether, limitAuth);

        // Execute valid limitAuth
        guard.setDailyLimit(accountId, agent, 0.1 ether, limitAuth);

        // Replay of same auth fails (stale nonce)
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setDailyLimit(accountId, agent, 0.1 ether, limitAuth);

        // 2. setPaused replay fails
        ISpendingGuard.WebAuthnAuth memory validPauseAuth =
            _signAction(accountId, guard.setPaused.selector, abi.encode(true));
        guard.setPaused(accountId, true, validPauseAuth);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.setPaused(accountId, true, validPauseAuth);

        // 3. revokeAgent replay fails (agent now inactive -> UnauthorizedAgent)
        ISpendingGuard.WebAuthnAuth memory validRevokeAuth =
            _signAction(accountId, guard.revokeAgent.selector, abi.encode(agent));
        guard.revokeAgent(accountId, agent, validRevokeAuth);
        vm.expectRevert(abi.encodeWithSelector(ISpendingGuard.UnauthorizedAgent.selector, accountId, agent));
        guard.revokeAgent(accountId, agent, validRevokeAuth);

        // 4. withdraw replay fails
        ISpendingGuard.WebAuthnAuth memory validWithdrawAuth =
            _signAction(accountId, guard.withdraw.selector, abi.encode(recipient, 0.1 ether));
        guard.withdraw(accountId, payable(recipient), 0.1 ether, validWithdrawAuth);
        vm.expectRevert(ISpendingGuard.InvalidSignature.selector);
        guard.withdraw(accountId, payable(recipient), 0.1 ether, validWithdrawAuth);
    }

    // ==========================================
    // 7. INVARIANTS
    // ==========================================

    function test_invariant_accountingSolvency() public {
        uint256 totalDeposited = 2 ether; // 1 ether each for accountId and otherAccountId
        uint256 totalWithdrawn = 0;
        uint256 totalPaid = 0;

        // Perform some operations
        vm.prank(agent);
        guard.pay(accountId, payable(recipient), 0.02 ether);
        totalPaid += 0.02 ether;

        bytes memory paramsWithdraw = abi.encode(payable(recipient), 0.3 ether);
        guard.withdraw(
            accountId, payable(recipient), 0.3 ether, _signAction(accountId, guard.withdraw.selector, paramsWithdraw)
        );
        totalWithdrawn += 0.3 ether;

        (,, uint256 bal1,,) = guard.accountOf(accountId);
        (,, uint256 bal2,,) = guard.accountOf(otherAccountId);

        // Invariant: totalDeposited == totalPaid + totalWithdrawn + sumOfBalances
        assertEq(totalDeposited, totalPaid + totalWithdrawn + bal1 + bal2);
        // Invariant: contract balance >= sum of tracked balances
        assertGe(address(guard).balance, bal1 + bal2);
    }

    function test_invariant_nonceEqualsOwnerActionsCount() public {
        uint64 startNonce = guard.nonceOf(accountId);
        uint64 ownerActionCount = 0;

        // 1. setDailyLimit
        bytes memory p1 = abi.encode(agent, uint128(0.08 ether));
        guard.setDailyLimit(accountId, agent, 0.08 ether, _signAction(accountId, guard.setDailyLimit.selector, p1));
        ownerActionCount++;

        // 2. setPaused
        bytes memory p2 = abi.encode(true);
        guard.setPaused(accountId, true, _signAction(accountId, guard.setPaused.selector, p2));
        ownerActionCount++;

        // 3. withdraw while paused
        bytes memory p3 = abi.encode(payable(recipient), 0.1 ether);
        guard.withdraw(accountId, payable(recipient), 0.1 ether, _signAction(accountId, guard.withdraw.selector, p3));
        ownerActionCount++;

        // 4. setPaused unpause
        bytes memory p4 = abi.encode(false);
        guard.setPaused(accountId, false, _signAction(accountId, guard.setPaused.selector, p4));
        ownerActionCount++;

        // 5. revokeAgent
        bytes memory p5 = abi.encode(agent);
        guard.revokeAgent(accountId, agent, _signAction(accountId, guard.revokeAgent.selector, p5));
        ownerActionCount++;

        assertEq(guard.nonceOf(accountId), startNonce + ownerActionCount);
    }

    // ==========================================
    // 8. FUZZ TEST: RANDOM SEQUENCE VS REFERENCE MODEL
    // ==========================================

    function testFuzz_ownerActionsSequence(uint8[6] memory actionTypes, uint16[6] memory rawAmounts) public {
        // Model state
        uint256 modelBalance = 1 ether;
        uint128 modelLimit = 0.05 ether;
        uint128 modelSpentToday = 0;
        bool modelPaused = false;
        bool modelRevoked = false;

        for (uint256 i = 0; i < 6; i++) {
            uint8 action = actionTypes[i] % 5;
            uint256 amt = (uint256(rawAmounts[i]) % 100 + 1) * 0.001 ether; // 0.001 to 0.1 ether

            if (action == 0) {
                // Deposit
                vm.deal(stranger, amt);
                vm.prank(stranger);
                guard.deposit{value: amt}(accountId);
                modelBalance += amt;
            } else if (action == 1) {
                // Change limit
                uint128 newLim = uint128(amt);
                if (newLim > 0 && !modelRevoked) {
                    bytes memory p = abi.encode(agent, newLim);
                    guard.setDailyLimit(
                        accountId, agent, newLim, _signAction(accountId, guard.setDailyLimit.selector, p)
                    );
                    modelLimit = newLim;
                }
            } else if (action == 2) {
                // Toggle paused
                bool newP = !modelPaused;
                bytes memory p = abi.encode(newP);
                guard.setPaused(accountId, newP, _signAction(accountId, guard.setPaused.selector, p));
                modelPaused = newP;
            } else if (action == 3) {
                // Try payment
                vm.prank(agent);
                (bool ok,) = guard.tryPay(accountId, payable(recipient), amt);

                uint128 remaining = modelSpentToday >= modelLimit ? 0 : modelLimit - modelSpentToday;
                bool expectedOk = !modelPaused && !modelRevoked && (amt <= remaining) && (amt <= modelBalance);

                assertEq(ok, expectedOk);
                if (ok) {
                    modelBalance -= amt;
                    modelSpentToday += uint128(amt);
                }
            } else if (action == 4) {
                // Withdraw
                if (amt <= modelBalance && amt > 0) {
                    bytes memory p = abi.encode(payable(recipient), amt);
                    guard.withdraw(
                        accountId, payable(recipient), amt, _signAction(accountId, guard.withdraw.selector, p)
                    );
                    modelBalance -= amt;
                }
            }
        }

        // Validate final state consistency
        (,, uint256 actualBal,, bool actualPaused) = guard.accountOf(accountId);
        assertEq(actualBal, modelBalance);
        assertEq(actualPaused, modelPaused);
    }
}
