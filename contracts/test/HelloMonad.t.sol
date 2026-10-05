// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HelloMonad} from "../src/HelloMonad.sol";

contract HelloMonadTest is Test {
    HelloMonad public hello;
    address public owner;
    address public nonOwner;

    event GreetingChanged(address indexed by, string newGreeting);

    function setUp() public {
        owner = address(this);
        nonOwner = address(0xCAFE);
        hello = new HelloMonad("Hello, Monad!");
    }

    function test_InitialState() public view {
        assertEq(hello.owner(), owner);
        assertEq(hello.greeting(), "Hello, Monad!");
    }

    function test_OwnerCanSetGreetingAndEmitEvent() public {
        vm.expectEmit(true, false, false, true);
        emit GreetingChanged(owner, "Hello, Hackathon!");

        hello.setGreeting("Hello, Hackathon!");
        assertEq(hello.greeting(), "Hello, Hackathon!");
    }

    function test_RevertWhen_NonOwnerSetsGreeting() public {
        vm.prank(nonOwner);
        vm.expectRevert(HelloMonad.NotOwner.selector);
        hello.setGreeting("Unauthorized");
    }

    function testFuzz_OwnerCanSetAnyGreeting(string calldata newGreeting) public {
        hello.setGreeting(newGreeting);
        assertEq(hello.greeting(), newGreeting);
    }
}
