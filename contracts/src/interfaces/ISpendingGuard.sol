// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ISpendingGuard
 * @notice Interface for SpendingGuard, a reusable spending-limit and identity vault
 *         for autonomous AI agents on Monad.
 * @dev Enforces daily velocity caps, target contract allowlists, and passkey-authorized
 *      management via Monad's native P-256 precompile at 0x0100.
 */
interface ISpendingGuard {
    /// @notice Reasons why an agent payment may be blocked by tryPay.
    enum PaymentBlockReason {
        NONE,
        PAUSED,
        AGENT_NOT_ACTIVE,
        TARGET_NOT_ALLOWED,
        OVER_DAILY_LIMIT,
        INSUFFICIENT_VAULT_BALANCE,
        ZERO_AMOUNT
    }

    /// @notice WebAuthn signature parameters for passkey owner authentication.
    /// @param authenticatorData Raw authenticator data returned by navigator.credentials.get().
    /// @param clientDataJSON UTF-8 JSON client data containing the challenge and origin.
    /// @param challengeIndex Index of the challenge parameter within clientDataJSON.
    /// @param typeIndex Index of the type string ("webauthn.get") within clientDataJSON.
    /// @param r ECDSA r component of the P-256 signature.
    /// @param s ECDSA s component of the P-256 signature.
    struct WebAuthnAuth {
        bytes authenticatorData;
        string clientDataJSON;
        uint256 challengeIndex;
        uint256 typeIndex;
        uint256 r;
        uint256 s;
    }

    /// @notice Account state stored for a passkey owner.
    /// @param qx Public key x-coordinate on secp256r1 curve.
    /// @param qy Public key y-coordinate on secp256r1 curve.
    /// @param balance Deposited native MON vault balance.
    /// @param nonce Monotonically increasing replay protection nonce for owner actions.
    /// @param paused Emergency freeze status of the account.
    struct Account {
        bytes32 qx;
        bytes32 qy;
        uint256 balance;
        uint64 nonce;
        bool paused;
    }

    /// @notice Policy and spending metrics assigned to an AI agent.
    /// @param active Authorization status of the agent.
    /// @param dailyLimit Maximum native MON allowable per 24-hour UTC window.
    /// @param spentToday Cumulative native MON spent during the current day window.
    /// @param dayIndex Day index timestamp calculated as block.timestamp / 1 days.
    /// @param anyTarget If true, the agent may transact with any destination address.
    struct Agent {
        bool active;
        uint128 dailyLimit;
        uint128 spentToday;
        uint64 dayIndex;
        bool anyTarget;
    }

    // ==========================================
    // EVENTS
    // ==========================================

    /// @notice Emitted when a new passkey owner account is registered.
    /// @param accountId Unique hash identifying the account: keccak256(abi.encode(qx, qy)).
    /// @param qx Public key x-coordinate.
    /// @param qy Public key y-coordinate.
    event AccountCreated(bytes32 indexed accountId, bytes32 qx, bytes32 qy);

    /// @notice Emitted when native MON is deposited into an account vault.
    /// @param accountId Account receiving the funds.
    /// @param sender Address that deposited the MON.
    /// @param amount Amount of native MON deposited in wei.
    event Deposited(bytes32 indexed accountId, address indexed sender, uint256 amount);

    /// @notice Emitted when an agent is added or re-activated for an account.
    /// @param accountId Account delegating authority.
    /// @param agent Address of the autonomous agent EOA.
    /// @param dailyLimit Daily spending velocity limit in wei.
    /// @param anyTarget True if unrestricted destination targeting is permitted.
    event AgentAdded(bytes32 indexed accountId, address indexed agent, uint128 dailyLimit, bool anyTarget);

    /// @notice Emitted when an agent's daily limit is modified.
    /// @param accountId Account owning the agent.
    /// @param agent Address of the agent.
    /// @param oldLimit Previous daily limit in wei.
    /// @param newLimit Updated daily limit in wei.
    event DailyLimitUpdated(bytes32 indexed accountId, address indexed agent, uint128 oldLimit, uint128 newLimit);

    /// @notice Emitted when a target contract allowlist permission is modified.
    /// @param accountId Account owning the agent.
    /// @param agent Address of the agent.
    /// @param target Target destination address.
    /// @param allowed True if calls to target are permitted, false otherwise.
    event TargetAllowedSet(bytes32 indexed accountId, address indexed agent, address indexed target, bool allowed);

    /// @notice Emitted when an agent is revoked.
    /// @param accountId Account owning the agent.
    /// @param agent Address of the revoked agent.
    event AgentRevoked(bytes32 indexed accountId, address indexed agent);

    /// @notice Emitted when an account paused status is changed.
    /// @param accountId Account whose pause status was toggled.
    /// @param paused New pause status.
    event PausedSet(bytes32 indexed accountId, bool paused);

    /// @notice Emitted when the account owner withdraws funds from the vault.
    /// @param accountId Account originating the withdrawal.
    /// @param recipient Address receiving the withdrawn MON.
    /// @param amount Amount of native MON withdrawn in wei.
    event Withdrawn(bytes32 indexed accountId, address indexed recipient, uint256 amount);

    /// @notice Emitted when an agent successfully executes a payment.
    /// @param accountId Account funding the payment.
    /// @param agent Agent executing the payment.
    /// @param target Destination address.
    /// @param amount Amount of native MON transferred in wei.
    event PaymentExecuted(bytes32 indexed accountId, address indexed agent, address indexed target, uint256 amount);

    /// @notice Emitted when tryPay catches a policy violation instead of reverting.
    /// @param accountId Account funding the payment attempt.
    /// @param agent Agent that initiated the payment attempt.
    /// @param target Destination address.
    /// @param amount Amount of native MON requested in wei.
    /// @param reason Categorized reason explaining why the payment was blocked.
    event PaymentBlocked(
        bytes32 indexed accountId,
        address indexed agent,
        address indexed target,
        uint256 amount,
        PaymentBlockReason reason
    );

    // ==========================================
    // CUSTOM ERRORS
    // ==========================================

    /// @notice Thrown when attempting to initialize an account that already exists.
    /// @param accountId Computed account identifier.
    error AccountAlreadyExists(bytes32 accountId);

    /// @notice Thrown when operating on an account that has not been initialized.
    /// @param accountId Computed account identifier.
    error AccountNotFound(bytes32 accountId);

    /// @notice Thrown when an action is attempted while the account is paused.
    /// @param accountId Account identifier.
    error AccountPaused(bytes32 accountId);

    /// @notice Thrown when an owner WebAuthn passkey signature fails verification.
    error InvalidSignature();

    /// @notice Thrown when an action digest specifies an invalid replay nonce.
    /// @param expected Expected current nonce.
    /// @param provided Provided nonce in action digest.
    error InvalidNonce(uint64 expected, uint64 provided);

    /// @notice Thrown when msg.sender is not an authorized, active agent for the account.
    /// @param accountId Account identifier.
    /// @param agent Caller address.
    error UnauthorizedAgent(bytes32 accountId, address agent);

    /// @notice Thrown when an agent attempts to transact with an unapproved target.
    /// @param accountId Account identifier.
    /// @param agent Calling agent address.
    /// @param target Disallowed destination address.
    error TargetNotAllowed(bytes32 accountId, address agent, address target);

    /// @notice Thrown when a payment exceeds the remaining daily spending velocity cap.
    /// @param accountId Account identifier.
    /// @param agent Calling agent address.
    /// @param requested Requested payment amount in wei.
    /// @param available Remaining allowance available today in wei.
    error DailyLimitExceeded(bytes32 accountId, address agent, uint128 requested, uint128 available);

    /// @notice Thrown when a payment or withdrawal exceeds the account's deposited balance.
    /// @param accountId Account identifier.
    /// @param requested Requested transfer amount in wei.
    /// @param available Deposited balance available in wei.
    error InsufficientBalance(bytes32 accountId, uint256 requested, uint256 available);

    /// @notice Thrown when attempting to execute a payment of zero amount.
    error ZeroAmount();

    /// @notice Thrown when native MON transfer to recipient/target reverts.
    error PaymentTransferFailed();

    // Note: ReentrancyGuardReentrantCall is inherited from OpenZeppelin's ReentrancyGuard contract.

    // ==========================================
    // STATE MODIFYING FUNCTIONS
    // ==========================================

    /// @notice Creates a new account bound to the owner's P-256 passkey coordinates.
    /// @dev accountId is deterministically computed as keccak256(abi.encode(qx, qy)).
    ///      Safe against front-running as only the owner's passkey can control the account.
    /// @param qx Public key x-coordinate on secp256r1 curve.
    /// @param qy Public key y-coordinate on secp256r1 curve.
    /// @return accountId Unique identifier of the created account.
    function createAccount(bytes32 qx, bytes32 qy) external returns (bytes32 accountId);

    /// @notice Deposits native MON into an account's vault balance.
    /// @dev Permissionless; anyone (or relayer/faucet) can fund an account.
    /// @param accountId Account identifier to credit.
    function deposit(bytes32 accountId) external payable;

    /// @notice Adds or activates an agent with spending policy parameters.
    /// @dev Requires a valid WebAuthn signature signed by the account's passkey owner.
    /// @param accountId Account authorizing the agent.
    /// @param agent Address of the autonomous agent EOA.
    /// @param dailyLimit Daily spending velocity limit in wei.
    /// @param anyTarget If true, grants permission to call any destination address.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function addAgent(bytes32 accountId, address agent, uint128 dailyLimit, bool anyTarget, WebAuthnAuth calldata auth)
        external;

    /// @notice Updates the daily spending limit for an existing agent.
    /// @dev Requires a valid WebAuthn signature from the account's passkey owner.
    /// @param accountId Account owning the agent.
    /// @param agent Address of the agent.
    /// @param newDailyLimit New daily spending velocity limit in wei.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function setDailyLimit(bytes32 accountId, address agent, uint128 newDailyLimit, WebAuthnAuth calldata auth) external;

    /// @notice Grants or revokes permission for an agent to call a specific target address.
    /// @dev Requires a valid WebAuthn signature from the account's passkey owner.
    /// @param accountId Account owning the agent.
    /// @param agent Address of the agent.
    /// @param target Target destination address.
    /// @param allowed True to whitelist target, false to revoke.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function setTargetAllowed(
        bytes32 accountId,
        address agent,
        address target,
        bool allowed,
        WebAuthnAuth calldata auth
    ) external;

    /// @notice Revokes an agent's authorization immediately.
    /// @dev Requires a valid WebAuthn signature from the account's passkey owner.
    /// @param accountId Account owning the agent.
    /// @param agent Address of the agent to revoke.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function revokeAgent(bytes32 accountId, address agent, WebAuthnAuth calldata auth) external;

    /// @notice Freezes or unfreezes all outgoing agent payments for an account.
    /// @dev Requires a valid WebAuthn signature from the account's passkey owner.
    /// @param accountId Account to pause or unpause.
    /// @param paused True to pause account operations, false to unpause.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function setPaused(bytes32 accountId, bool paused, WebAuthnAuth calldata auth) external;

    /// @notice Withdraws deposited native MON from the vault to a designated recipient.
    /// @dev Requires a valid WebAuthn signature from the account's passkey owner.
    /// @param accountId Account to withdraw funds from.
    /// @param recipient Address receiving the native MON.
    /// @param amount Amount of native MON to withdraw in wei.
    /// @param auth WebAuthn signature payload verifying owner intent.
    function withdraw(bytes32 accountId, address payable recipient, uint256 amount, WebAuthnAuth calldata auth) external;

    /// @notice Executes a payment on behalf of an account. Reverts if any policy rule fails.
    /// @dev Only callable by an active agent (msg.sender == agent). Reverts on violation.
    /// @param accountId Account funding the payment.
    /// @param target Recipient or destination contract address.
    /// @param amount Native MON amount to transfer in wei.
    /// @param data Optional calldata for smart contract execution.
    /// @return result Returndata from the target call if calldata was provided.
    function pay(bytes32 accountId, address payable target, uint256 amount, bytes calldata data)
        external
        returns (bytes memory result);

    /// @notice Non-reverting payment execution for autonomous agents.
    /// @dev Emits PaymentBlocked and returns (false, reason, "") on policy failure.
    ///      Reverts only for reentrancy or transfer failure.
    /// @param accountId Account funding the payment.
    /// @param target Recipient or destination contract address.
    /// @param amount Native MON amount to transfer in wei.
    /// @param data Optional calldata for smart contract execution.
    /// @return success True if payment executed successfully, false if blocked by policy.
    /// @return reason Reason code explaining why payment was blocked (NONE if successful).
    /// @return result Returndata from the target call if successful.
    function tryPay(bytes32 accountId, address payable target, uint256 amount, bytes calldata data)
        external
        returns (bool success, PaymentBlockReason reason, bytes memory result);

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
        returns (bytes32 qx, bytes32 qy, uint256 balance, uint64 nonce, bool paused);

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
        returns (bool active, uint128 dailyLimit, uint128 spentToday, uint64 dayIndex, bool anyTarget);

    /// @notice Returns the remaining spending capacity for an agent in the current day window.
    /// @dev Accounts for 24-hour day rollover dynamically: if block.timestamp / 1 days > dayIndex,
    ///      the returned remaining capacity is the full dailyLimit.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @return remaining Native MON amount available to spend today in wei.
    function remainingToday(bytes32 accountId, address agent) external view returns (uint256 remaining);

    /// @notice Checks if a target destination is approved for an agent.
    /// @param accountId Account identifier.
    /// @param agent Address of the agent.
    /// @param target Destination address to evaluate.
    /// @return allowed True if the agent is authorized to call target.
    function isTargetAllowed(bytes32 accountId, address agent, address target) external view returns (bool allowed);

    /// @notice Returns the current replay protection nonce for an account.
    /// @param accountId Account identifier.
    /// @return currentNonce Current nonce.
    function nonceOf(bytes32 accountId) external view returns (uint64 currentNonce);

    /// @notice Computes the EIP-712 / typed action digest that the passkey owner must sign.
    /// @param accountId Account identifier.
    /// @param nonce Current nonce expected for the action.
    /// @param actionSelector Function selector of the owner action.
    /// @param params ABI-encoded parameters specific to the action selector.
    /// @return digest 32-byte digest binding chainId, contract, accountId, nonce, selector, params.
    function actionHash(bytes32 accountId, uint64 nonce, bytes4 actionSelector, bytes memory params)
        external
        view
        returns (bytes32 digest);
}
