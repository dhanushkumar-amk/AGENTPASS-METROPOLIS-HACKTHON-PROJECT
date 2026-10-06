// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpendingGuard} from "./interfaces/ISpendingGuard.sol";

/**
 * @title SpendingGuardBase
 * @notice Abstract base implementation of the AgentPass SpendingGuard protocol on Monad.
 * @dev Enforces account registration, deposit accounting, agent policy initialization,
 *      EIP-712 typed owner-action hashing, and replay protection nonces.
 *      Out-of-scope payment logic (pay/tryPay/daily limits/allowlists) is deferred to subsequent phases.
 */
// forge-lint: disable-next-line(locked-ether)
abstract contract SpendingGuardBase is ISpendingGuard {
    // ==========================================
    // STORAGE STRUCTS & PACKING
    // ==========================================

    /// @notice Storage struct for a passkey owner account.
    /// @dev Tightly packed into 3 storage slots:
    ///      Slot 0: qx (32 bytes)
    ///      Slot 1: qy (32 bytes)
    ///      Slot 2: balance (16 bytes, offset 0..15) | nonce (8 bytes, offset 16..23) | paused (1 byte, offset 24)
    struct AccountStorage {
        bytes32 qx;
        bytes32 qy;
        uint128 balance;
        uint64 nonce;
        bool paused;
    }

    /// @notice Storage struct for an autonomous agent policy.
    /// @dev Tightly packed into 2 storage slots:
    ///      Slot 0: dailyLimit (16 bytes, offset 0..15) | spentToday (16 bytes, offset 16..31)
    ///      Slot 1: dayIndex (8 bytes, offset 0..7) | active (1 byte, offset 8) | anyTarget (1 byte, offset 9)
    struct AgentStorage {
        uint128 dailyLimit;
        uint128 spentToday;
        uint64 dayIndex;
        bool active;
        bool anyTarget;
    }

    /// @dev Mapping from accountId to AccountStorage record.
    mapping(bytes32 => AccountStorage) internal _accounts;

    /// @dev Mapping from accountId => agent address => AgentStorage policy.
    mapping(bytes32 => mapping(address => AgentStorage)) internal _agents;

    // ==========================================
    // EIP-712 CONSTANTS
    // ==========================================

    /// @notice EIP-712 Action struct typehash.
    bytes32 public constant ACTION_TYPEHASH =
        keccak256("SpendingGuardAction(bytes32 accountId,uint64 nonce,bytes4 actionSelector,bytes params)");

    /// @dev EIP-712 domain separator typehash.
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Hashed protocol domain name.
    bytes32 private constant DOMAIN_NAME_HASH = keccak256(bytes("AgentPass SpendingGuard"));

    /// @dev Hashed protocol domain version.
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));

    // ==========================================
    // EXTERNAL STATE-MODIFYING FUNCTIONS
    // ==========================================

    /// @notice Creates a new account bound to the owner's P-256 passkey coordinates.
    /// @dev Permissionless. accountId = keccak256(abi.encode(qx, qy)).
    /// @param qx Public key x-coordinate on secp256r1 curve.
    /// @param qy Public key y-coordinate on secp256r1 curve.
    /// @return accountId Unique identifier of the created account.
    function createAccount(bytes32 qx, bytes32 qy) external returns (bytes32 accountId) {
        if (qx == bytes32(0) || qy == bytes32(0)) {
            revert ZeroAmount();
        }

        accountId = keccak256(abi.encode(qx, qy));
        if (_accounts[accountId].qx != bytes32(0)) {
            revert AccountAlreadyExists(accountId);
        }

        _accounts[accountId] = AccountStorage({qx: qx, qy: qy, balance: 0, nonce: 0, paused: false});

        emit AccountCreated(accountId, qx, qy);
    }

    /// @notice Deposits native MON into an account's vault balance.
    /// @dev Permissionless. msg.value must be strictly positive.
    /// @param accountId Account identifier to credit.
    function deposit(bytes32 accountId) external payable {
        if (_accounts[accountId].qx == bytes32(0)) {
            revert AccountNotFound(accountId);
        }
        if (msg.value == 0) {
            revert ZeroAmount();
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        _accounts[accountId].balance += uint128(msg.value);

        emit Deposited(accountId, msg.sender, msg.value);
    }

    /// @notice Adds or activates an agent with spending policy parameters.
    /// @dev Requires a valid WebAuthn signature signed by the account's passkey owner.
    ///      Follows checks-effects-interactions: verifies owner signature, bumps nonce, then writes state.
    /// @param accountId Account authorizing the agent.
    /// @param agent Address of the autonomous agent EOA.
    /// @param dailyLimit Daily spending velocity limit in wei.
    /// @param anyTarget If true, grants permission to call any destination address.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function addAgent(bytes32 accountId, address agent, uint128 dailyLimit, bool anyTarget, WebAuthnAuth calldata auth)
        external
    {
        if (_accounts[accountId].qx == bytes32(0)) {
            revert AccountNotFound(accountId);
        }
        if (_accounts[accountId].paused) {
            revert AccountPaused(accountId);
        }
        if (agent == address(0)) {
            revert UnauthorizedAgent(accountId, agent);
        }
        if (_agents[accountId][agent].active) {
            revert UnauthorizedAgent(accountId, agent);
        }
        if (dailyLimit == 0) {
            revert ZeroAmount();
        }

        uint64 currentNonce = _accounts[accountId].nonce;
        bytes memory params = abi.encode(agent, dailyLimit, anyTarget);
        bytes32 digest = actionHash(accountId, currentNonce, this.addAgent.selector, params);

        _verifyOwner(accountId, digest, auth);

        _accounts[accountId].nonce = currentNonce + 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 today = uint64(block.timestamp / 1 days);
        _agents[accountId][agent] =
            AgentStorage({dailyLimit: dailyLimit, spentToday: 0, dayIndex: today, active: true, anyTarget: anyTarget});

        emit AgentAdded(accountId, agent, dailyLimit, anyTarget);
    }

    /// @notice Rejects plain native transfers without function data to prevent stranded funds.
    receive() external payable {
        revert ZeroAmount();
    }

    /// @notice Rejects unknown calldata invocations.
    fallback() external payable {
        revert ZeroAmount();
    }

    // ==========================================
    // VIEW / PURE FUNCTIONS
    // ==========================================

    /// @notice Returns the account parameters for a given account identifier.
    /// @param accountId Account identifier.
    /// @return qx Passkey public key x-coordinate.
    /// @return qy Passkey public key y-coordinate.
    /// @return balance Available native MON deposited balance in wei.
    /// @return nonce Current replay protection nonce for owner actions.
    /// @return paused Current pause status of the account.
    function accountOf(bytes32 accountId)
        external
        view
        returns (bytes32 qx, bytes32 qy, uint256 balance, uint64 nonce, bool paused)
    {
        AccountStorage storage acc = _accounts[accountId];
        return (acc.qx, acc.qy, uint256(acc.balance), acc.nonce, acc.paused);
    }

    /// @notice Returns the policy details and state for an agent under an account.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @return active Whether the agent is active.
    /// @return dailyLimit Daily limit in wei.
    /// @return spentToday Amount spent in the current 24-hour day window in wei.
    /// @return dayIndex Day index of the last recorded payment (block.timestamp / 1 days).
    /// @return anyTarget Whether the agent can call any destination address.
    function agentOf(bytes32 accountId, address agent)
        external
        view
        returns (bool active, uint128 dailyLimit, uint128 spentToday, uint64 dayIndex, bool anyTarget)
    {
        AgentStorage storage ag = _agents[accountId][agent];
        return (ag.active, ag.dailyLimit, ag.spentToday, ag.dayIndex, ag.anyTarget);
    }

    /// @notice Returns the current replay protection nonce for an account.
    /// @param accountId Account identifier.
    /// @return currentNonce Current nonce.
    function nonceOf(bytes32 accountId) external view returns (uint64 currentNonce) {
        return _accounts[accountId].nonce;
    }

    /// @notice Computes the EIP-712 / typed action digest that the passkey owner must sign.
    /// @param accountId Account identifier.
    /// @param nonce Current nonce expected for the action.
    /// @param actionSelector Function selector of the owner action.
    /// @param params ABI-encoded parameters specific to the action selector.
    /// @return digest 32-byte digest binding chainId, contract, accountId, nonce, selector, params.
    function actionHash(bytes32 accountId, uint64 nonce, bytes4 actionSelector, bytes memory params)
        public
        view
        returns (bytes32 digest)
    {
        bytes32 structHash = keccak256(abi.encode(ACTION_TYPEHASH, accountId, nonce, actionSelector, keccak256(params)));
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this))
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @notice Returns the remaining spending capacity for an agent.
    /// @dev In Phase 7, returns full dailyLimit. Phase 8 will refine dynamic day rollover
    ///      and cumulative daily spending deduction.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @return remaining Available daily allowance in wei.
    function remainingToday(bytes32 accountId, address agent) external view returns (uint256 remaining) {
        return uint256(_agents[accountId][agent].dailyLimit);
    }

    /// @notice Checks if a target destination is approved for an agent.
    /// @dev In Phase 7, returns false as target allowlist management is implemented in Phase 9.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @param target Destination address.
    /// @return allowed False in Phase 7 baseline.
    function isTargetAllowed(bytes32 accountId, address agent, address target) external pure returns (bool allowed) {
        accountId;
        agent;
        target;
        return false;
    }

    // ==========================================
    // INTERNAL VIRTUAL HOOKS
    // ==========================================

    /// @notice Internal virtual hook to verify passkey owner signatures.
    /// @dev Declared abstract in this base contract. Phase 14 will implement P-256 precompile verification.
    /// @param accountId Unique identifier of the account.
    /// @param digest 32-byte EIP-712 typed action digest.
    /// @param auth WebAuthn signature parameters.
    function _verifyOwner(bytes32 accountId, bytes32 digest, WebAuthnAuth calldata auth) internal virtual;
}
