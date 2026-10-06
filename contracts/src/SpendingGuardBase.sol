// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpendingGuard} from "./interfaces/ISpendingGuard.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SpendingGuardBase
 * @notice Abstract base implementation of the AgentPass SpendingGuard protocol on Monad.
 * @dev Enforces account registration, deposit accounting, agent policy initialization,
 *      EIP-712 typed owner-action hashing, replay protection nonces, daily velocity limits,
 *      and non-reverting tryPay telemetry.
 */
abstract contract SpendingGuardBase is ISpendingGuard, ReentrancyGuard {
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

    /// @dev Mapping from accountId => agent address => target address => permission flag.
    mapping(bytes32 => mapping(address => mapping(address => bool))) internal _targetAllowlist;

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

    /// @dev Internal helper to revert with the custom error matching the block reason.
    /// @param accountId Account funding the payment.
    /// @param agent Calling agent address.
    /// @param target Destination recipient address.
    /// @param amount Payment amount in wei.
    /// @param reason Failing block reason.
    function _handlePayRevert(
        bytes32 accountId,
        address agent,
        address payable target,
        uint256 amount,
        PaymentBlockReason reason
    ) internal view {
        if (reason == PaymentBlockReason.ZERO_AMOUNT) {
            revert ZeroAmount();
        } else if (reason == PaymentBlockReason.AGENT_NOT_ACTIVE) {
            revert UnauthorizedAgent(accountId, agent);
        } else if (reason == PaymentBlockReason.PAUSED) {
            revert AccountPaused(accountId);
        } else if (reason == PaymentBlockReason.TARGET_NOT_ALLOWED) {
            revert TargetNotAllowed(accountId, agent, target);
        } else if (reason == PaymentBlockReason.OVER_DAILY_LIMIT) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 req = amount > type(uint128).max ? type(uint128).max : uint128(amount);
            // forge-lint: disable-next-line(unsafe-typecast)
            revert DailyLimitExceeded(accountId, agent, req, uint128(remainingToday(accountId, agent)));
        } else if (reason == PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE) {
            revert InsufficientBalance(accountId, amount, uint256(_accounts[accountId].balance));
        }
    }

    /// @notice Strict payment execution with calldata. Reverts on any policy violation.
    /// @dev Only callable by authorized agent (msg.sender). Protected by nonReentrant.
    /// @param accountId Account funding the payment.
    /// @param target Destination recipient address.
    /// @param amount Native MON amount in wei.
    /// @param data Optional calldata for smart contract call.
    /// @return result Call returndata.
    function pay(bytes32 accountId, address payable target, uint256 amount, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory result)
    {
        PaymentBlockReason reason = _checkPay(accountId, msg.sender, target, amount);
        if (reason != PaymentBlockReason.NONE) {
            _handlePayRevert(accountId, msg.sender, target, amount, reason);
        }

        return _executePay(accountId, msg.sender, target, amount, data);
    }

    /// @notice Convenience overload for pay without calldata.
    /// @param accountId Account funding the payment.
    /// @param target Destination recipient address.
    /// @param amount Native MON amount in wei.
    /// @return result Call returndata.
    function pay(bytes32 accountId, address payable target, uint256 amount)
        external
        nonReentrant
        returns (bytes memory result)
    {
        PaymentBlockReason reason = _checkPay(accountId, msg.sender, target, amount);
        if (reason != PaymentBlockReason.NONE) {
            _handlePayRevert(accountId, msg.sender, target, amount, reason);
        }

        return _executePay(accountId, msg.sender, target, amount, "");
    }

    /// @notice Non-reverting policy-guarded payment execution with calldata.
    /// @dev Catches policy violations gracefully, emits PaymentBlocked, and returns (false, reason, "").
    ///      Reverts only for reentrancy or low-level transfer failure.
    /// @param accountId Account funding the payment.
    /// @param target Destination recipient address.
    /// @param amount Native MON amount in wei.
    /// @param data Optional calldata for smart contract call.
    /// @return success True if payment executed, false if blocked by policy.
    /// @return reason Block reason enum (NONE if successful).
    /// @return result Call returndata.
    function tryPay(bytes32 accountId, address payable target, uint256 amount, bytes calldata data)
        external
        nonReentrant
        returns (bool success, PaymentBlockReason reason, bytes memory result)
    {
        reason = _checkPay(accountId, msg.sender, target, amount);
        if (reason != PaymentBlockReason.NONE) {
            emit PaymentBlocked(accountId, msg.sender, target, amount, reason);
            return (false, reason, "");
        }

        result = _executePay(accountId, msg.sender, target, amount, data);
        return (true, PaymentBlockReason.NONE, result);
    }

    /// @notice Convenience overload for tryPay without calldata.
    /// @param accountId Account funding the payment.
    /// @param target Destination recipient address.
    /// @param amount Native MON amount in wei.
    /// @return ok True if payment executed, false if blocked.
    /// @return reason Block reason code.
    function tryPay(bytes32 accountId, address payable target, uint256 amount)
        external
        nonReentrant
        returns (bool ok, PaymentBlockReason reason)
    {
        reason = _checkPay(accountId, msg.sender, target, amount);
        if (reason != PaymentBlockReason.NONE) {
            emit PaymentBlocked(accountId, msg.sender, target, amount, reason);
            return (false, reason);
        }

        _executePay(accountId, msg.sender, target, amount, "");
        return (true, PaymentBlockReason.NONE);
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

    /// @notice Returns the remaining spending capacity for an agent in the current day window.
    /// @dev Evaluates dynamic 24-hour rollover and floors at 0 to avoid underflow if limit was lowered.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @return remaining Available daily allowance in wei (0 if agent is inactive).
    function remainingToday(bytes32 accountId, address agent) public view returns (uint256 remaining) {
        AgentStorage storage ag = _agents[accountId][agent];
        if (!ag.active) {
            return 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 today = uint64(block.timestamp / 1 days);
        uint256 effectiveSpent = (ag.dayIndex == today) ? uint256(ag.spentToday) : 0;
        uint256 limit = uint256(ag.dailyLimit);
        if (effectiveSpent >= limit) {
            return 0;
        }
        return limit - effectiveSpent;
    }

    /// @notice Checks if a target destination is approved for an agent.
    /// @dev address(0) is always disallowed. Returns true if agent has anyTarget or target is allowlisted.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @param target Destination address to evaluate.
    /// @return allowed True if calls to target are permitted.
    function isTargetAllowed(bytes32 accountId, address agent, address target) public view returns (bool allowed) {
        if (target == address(0)) {
            return false;
        }
        AgentStorage storage ag = _agents[accountId][agent];
        if (!ag.active) {
            return false;
        }
        return ag.anyTarget || _targetAllowlist[accountId][agent][target];
    }

    // ==========================================
    // INTERNAL POLICY & EXECUTION FUNCTIONS
    // ==========================================

    /// @notice Evaluates policy rules for a payment attempt in strict authoritative check order.
    /// @param accountId Account funding the payment.
    /// @param agent Address of calling agent.
    /// @param to Destination address.
    /// @param amount Transfer amount in wei.
    /// @return PaymentBlockReason NONE if allowed, or specific denial reason code.
    function _checkPay(bytes32 accountId, address agent, address to, uint256 amount)
        internal
        view
        returns (PaymentBlockReason)
    {
        // 1. amount == 0 -> ZERO_AMOUNT
        if (amount == 0) {
            return PaymentBlockReason.ZERO_AMOUNT;
        }

        // 2. agent not active for account -> AGENT_NOT_ACTIVE (covers unknown account)
        if (!_agents[accountId][agent].active) {
            return PaymentBlockReason.AGENT_NOT_ACTIVE;
        }

        // 3. account paused -> PAUSED
        if (_accounts[accountId].paused) {
            return PaymentBlockReason.PAUSED;
        }

        // 4. target not allowed -> TARGET_NOT_ALLOWED
        // to == address(0) is ALWAYS not allowed, even with anyTarget.
        if (to == address(0)) {
            return PaymentBlockReason.TARGET_NOT_ALLOWED;
        }
        if (!_agents[accountId][agent].anyTarget && !_targetAllowlist[accountId][agent][to]) {
            return PaymentBlockReason.TARGET_NOT_ALLOWED;
        }

        // 5. effectiveSpent + amount > dailyLimit -> OVER_DAILY_LIMIT
        // Safe math in uint256 avoids arithmetic overflow on huge amounts.
        AgentStorage storage ag = _agents[accountId][agent];
        uint256 limit = uint256(ag.dailyLimit);
        if (amount > limit) {
            return PaymentBlockReason.OVER_DAILY_LIMIT;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 today = uint64(block.timestamp / 1 days);
        uint256 effectiveSpent = (ag.dayIndex == today) ? uint256(ag.spentToday) : 0;
        if (effectiveSpent + amount > limit) {
            return PaymentBlockReason.OVER_DAILY_LIMIT;
        }

        // 6. amount > account balance -> INSUFFICIENT_VAULT_BALANCE
        if (amount > uint256(_accounts[accountId].balance)) {
            return PaymentBlockReason.INSUFFICIENT_VAULT_BALANCE;
        }

        return PaymentBlockReason.NONE;
    }

    /// @notice Executes state updates and external native MON transfer following CEI.
    /// @param accountId Account funding the payment.
    /// @param agent Calling agent address.
    /// @param to Destination address.
    /// @param amount Amount of native MON in wei.
    /// @param data Optional calldata.
    /// @return result Returndata from destination call.
    function _executePay(bytes32 accountId, address agent, address payable to, uint256 amount, bytes memory data)
        internal
        returns (bytes memory result)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 today = uint64(block.timestamp / 1 days);
        AgentStorage storage ag = _agents[accountId][agent];

        if (ag.dayIndex != today) {
            ag.dayIndex = today;
            ag.spentToday = 0;
        }

        // Effects
        // forge-lint: disable-next-line(unsafe-typecast)
        ag.spentToday += uint128(amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        _accounts[accountId].balance -= uint128(amount);

        emit PaymentExecuted(accountId, agent, to, amount);

        // Interaction
        bool sent;
        (sent, result) = to.call{value: amount}(data);
        if (!sent) {
            revert PaymentTransferFailed();
        }
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
