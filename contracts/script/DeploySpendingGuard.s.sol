// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SpendingGuard} from "../src/SpendingGuard.sol";

/// @title DeploySpendingGuard
/// @notice Deployment script for SpendingGuard on Monad testnet.
contract DeploySpendingGuard is Script {
    function run() external returns (SpendingGuard guard) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        guard = new SpendingGuard();
        vm.stopBroadcast();

        console.log("Deployed SpendingGuard at:", address(guard));
    }
}
