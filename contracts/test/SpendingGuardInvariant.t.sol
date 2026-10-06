// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {SpendingGuardHarness} from "./harness/SpendingGuardHarness.sol";

contract SpendingGuardHandler is Test {
    SpendingGuardHarness internal guard;
    bytes32[] internal accounts;
    uint256 public ghost_sumOfBalances;

    constructor(SpendingGuardHarness _guard) {
        guard = _guard;
        // Seed initial accounts
        for (uint256 i = 1; i <= 3; i++) {
            bytes32 qx = bytes32(i * 100);
            bytes32 qy = bytes32(i * 200);
            bytes32 accountId = guard.createAccount(qx, qy);
            accounts.push(accountId);
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

    function createAccount(bytes32 qxSeed, bytes32 qySeed) public {
        if (accounts.length >= 10) return; // Keep bound bounded and fast
        if (qxSeed == bytes32(0) || qySeed == bytes32(0)) return;

        bytes32 qx = keccak256(abi.encode(qxSeed, "x"));
        bytes32 qy = keccak256(abi.encode(qySeed, "y"));

        bytes32 accountId = guard.createAccount(qx, qy);
        accounts.push(accountId);
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
