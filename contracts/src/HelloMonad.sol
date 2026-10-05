// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title HelloMonad
 * @notice A minimal pipeline-verification contract for AgentPass on Monad testnet.
 * @dev Emits an event upon greeting change and restricts updates to owner.
 */
contract HelloMonad {
    /// @notice Address of the contract owner.
    address public owner;

    /// @notice Current greeting message.
    string public greeting;

    /// @notice Custom error thrown when a non-owner attempts an owner-restricted action.
    error NotOwner();

    /// @notice Emitted when the greeting is updated.
    /// @param by The address that changed the greeting.
    /// @param newGreeting The newly set greeting.
    event GreetingChanged(address indexed by, string newGreeting);

    /**
     * @notice Initializes the contract with an initial greeting and sets the deployer as owner.
     * @param initialGreeting The initial greeting string.
     */
    constructor(string memory initialGreeting) {
        owner = msg.sender;
        greeting = initialGreeting;
    }

    /**
     * @notice Updates the greeting string. Callable only by the owner.
     * @param g The new greeting string.
     */
    function setGreeting(string calldata g) external {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        greeting = g;
        emit GreetingChanged(msg.sender, g);
    }
}
