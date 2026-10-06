// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SpendingGuard} from "../../src/SpendingGuard.sol";
import {ISpendingGuard} from "../../src/interfaces/ISpendingGuard.sol";

/// @title SpendingGuardForkTest
/// @notice Happy-path verification against the real P-256 precompile on a live Monad testnet fork.
/// @dev Skips cleanly when the RPC env var is unset to ensure CI runs without secrets. Never contains a URL.
contract SpendingGuardForkTest is Test {
    SpendingGuard internal guard;

    uint256 internal constant OWNER_KEY = 0x5555555555555555555555555555555555555555555555555555555555555555;
    bytes32 internal ownerQx;
    bytes32 internal ownerQy;
    bytes32 internal accountId;

    address internal agent = address(0xAA99);
    address internal demoRecipient = address(0xBB99);
    address internal relayer = address(0xCC99);

    function setUp() public {
        string memory rpc = vm.envOr("QUICKNODE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }

        vm.createSelectFork(rpc);

        guard = new SpendingGuard();

        (uint256 qx, uint256 qy) = vm.publicKeyP256(OWNER_KEY);
        ownerQx = bytes32(qx);
        ownerQy = bytes32(qy);

        accountId = guard.createAccount(ownerQx, ownerQy);
        vm.deal(relayer, 10 ether);
    }

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

    function test_p256_fork_happyPath() public {
        string memory rpc = vm.envOr("QUICKNODE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console.log("SKIPPED: QUICKNODE_RPC_URL is unset. Skipping fork test cleanly.");
            return;
        }

        // 1. Deposit 0.1 ether
        guard.deposit{value: 0.1 ether}(accountId);

        // 2. Owner adds agent with limit 0.05 ether
        uint64 nonce = guard.nonceOf(accountId);
        bytes memory addAgentParams = abi.encode(agent, uint128(0.05 ether), false);
        bytes32 digest1 = guard.actionHash(accountId, nonce, guard.addAgent.selector, addAgentParams);
        vm.prank(relayer);
        guard.addAgent(accountId, agent, 0.05 ether, false, _signAction(OWNER_KEY, digest1));

        // 3. Owner sets demoRecipient as allowed target
        nonce = guard.nonceOf(accountId);
        bytes memory setTargetParams = abi.encode(agent, demoRecipient, true);
        bytes32 digest2 = guard.actionHash(accountId, nonce, guard.setTargetAllowed.selector, setTargetParams);
        vm.prank(relayer);
        guard.setTargetAllowed(accountId, agent, demoRecipient, true, _signAction(OWNER_KEY, digest2));

        // 4. Agent tryPay 0.02 ether -> ok
        vm.prank(agent);
        (bool ok1, ISpendingGuard.PaymentBlockReason r1) =
            guard.tryPay(accountId, payable(demoRecipient), 0.02 ether);
        assertTrue(ok1, "First tryPay should succeed");
        assertEq(uint8(r1), uint8(ISpendingGuard.PaymentBlockReason.NONE));

        // 5. Agent tryPay 0.06 ether -> blocked OVER_DAILY_LIMIT
        vm.prank(agent);
        (bool ok2, ISpendingGuard.PaymentBlockReason r2) =
            guard.tryPay(accountId, payable(demoRecipient), 0.06 ether);
        assertFalse(ok2, "Second tryPay should be blocked");
        assertEq(uint8(r2), uint8(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));

        // 6. Agent tryPay 0.02 ether -> ok (spentTotal = 0.04 ether)
        vm.prank(agent);
        (bool ok3, ISpendingGuard.PaymentBlockReason r3) =
            guard.tryPay(accountId, payable(demoRecipient), 0.02 ether);
        assertTrue(ok3, "Third tryPay should succeed");
        assertEq(uint8(r3), uint8(ISpendingGuard.PaymentBlockReason.NONE));

        // 7. Agent tryPay 0.02 ether -> blocked OVER_DAILY_LIMIT (0.04 + 0.02 = 0.06 > 0.05)
        vm.prank(agent);
        (bool ok4, ISpendingGuard.PaymentBlockReason r4) =
            guard.tryPay(accountId, payable(demoRecipient), 0.02 ether);
        assertFalse(ok4, "Fourth tryPay should be blocked");
        assertEq(uint8(r4), uint8(ISpendingGuard.PaymentBlockReason.OVER_DAILY_LIMIT));

        // 8. Assert balances and remaining capacity
        (,, uint256 vaultBal,,) = guard.accountOf(accountId);
        assertEq(vaultBal, 0.06 ether, "Vault balance should be 0.06 ether");
        assertEq(demoRecipient.balance, 0.04 ether, "Recipient balance should be 0.04 ether");
        assertEq(guard.remainingToday(accountId, agent), 0.01 ether, "Remaining today should be 0.01 ether");
    }
}
