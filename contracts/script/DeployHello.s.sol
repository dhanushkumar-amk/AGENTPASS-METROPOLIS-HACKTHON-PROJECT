// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HelloMonad} from "../src/HelloMonad.sol";

contract DeployHello is Script {
    function run() external returns (HelloMonad hello) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        hello = new HelloMonad("Hello, Monad!");
        vm.stopBroadcast();

        console.log("Deployed HelloMonad at:", address(hello));
    }
}
