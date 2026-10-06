// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpendingGuardHarness} from "./harness/SpendingGuardHarness.sol";

contract InvariantRecipient {
    receive() external payable {}
}

contract SpendingGuardHandler is Test {
    SpendingGuardHarness internal guard;
    bytes32[] internal accounts;
    address internal agent;
    InvariantRecipient internal recipientContract;
    uint256 public ghost_sumOfBalances;

    constructor(SpendingGuardHarness _guard) {
        guard = _guard;
        agent = address(0xAA01);
        recipientContract = new InvariantRecipient();

        // Seed initial accounts with agents and initial deposits
        for (uint256 i = 1; i <= 3; i++) {
            bytes32 qx = bytes32(i * 100);
            bytes32 qy = bytes32(i * 200);
            vm.deal(address(this), 1 ether);
            bytes32 accountId =
                guard.createFundedAccountWithAgent{value: 1 ether}(qx, qy, 1 ether, agent, 10 ether, true);
            accounts.push(accountId);
            ghost_sumOfBalances += 1 ether;
        }
    }

    function deposit(uint256 accountIndex, uint128 amount) public {
        if (accounts.length == 0) return;
        uint256 idx = accountIndex % accounts.length;
        bytes32 targetAccount = accounts[idx];

        uint256 depositAmount = bound(uint256(amount), 1, 10 ether);
        vm.deal(address(this), depositAmount);

        guard.deposit{value: depositAmount}(targetAccount);
        ghost_sumOfBalances += depositAmount;
    }

    function createAccount(bytes32 qxSeed, bytes32 qySeed, uint128 initialDeposit) public {
        if (accounts.length >= 10) return; // Keep bound bounded and fast
        if (qxSeed == bytes32(0) || qySeed == bytes32(0)) return;

        bytes32 qx = keccak256(abi.encode(qxSeed, "x"));
        bytes32 qy = keccak256(abi.encode(qySeed, "y"));
        uint256 dep = bound(uint256(initialDeposit), 0, 5 ether);
        vm.deal(address(this), dep);

        bytes32 accountId = guard.createFundedAccountWithAgent{value: dep}(qx, qy, uint128(dep), agent, 10 ether, true);
        accounts.push(accountId);
        ghost_sumOfBalances += dep;
    }

    function pay(uint256 accountIndex, uint128 amount) public {
        if (accounts.length == 0) return;
        uint256 idx = accountIndex % accounts.length;
        bytes32 targetAccount = accounts[idx];

        uint256 payAmount = bound(uint256(amount), 1, 5 ether);

        vm.prank(agent);
        try guard.pay(targetAccount, payable(address(recipientContract)), payAmount) {
            ghost_sumOfBalances -= payAmount;
        } catch {
            // Reverted as expected (e.g., over daily limit or insufficient balance)
        }
    }

    function tryPay(uint256 accountIndex, uint128 amount) public {
        if (accounts.length == 0) return;
        uint256 idx = accountIndex % accounts.length;
        bytes32 targetAccount = accounts[idx];

        uint256 payAmount = bound(uint256(amount), 1, 5 ether);

        vm.prank(agent);
        (bool ok,) = guard.tryPay(targetAccount, payable(address(recipientContract)), payAmount);
        if (ok) {
            ghost_sumOfBalances -= payAmount;
        }
    }

    function warpTime(uint256 secondsToWarp) public {
        uint256 jump = bound(secondsToWarp, 1 hours, 2 days);
        vm.warp(block.timestamp + jump);
    }
}

contract SpendingGuardInvariantTest is Test {
    SpendingGuardHarness internal guard;
    SpendingGuardHandler internal handler;

    function setUp() public {
        guard = new SpendingGuardHarness();
        handler = new SpendingGuardHandler(guard);
        targetContract(address(handler));
    }

    function invariant_contractBalanceGteSumOfTrackedBalances() public view {
        assertGe(address(guard).balance, handler.ghost_sumOfBalances());
    }
}
