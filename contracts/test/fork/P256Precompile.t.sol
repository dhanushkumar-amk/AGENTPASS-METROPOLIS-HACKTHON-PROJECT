// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

contract P256PrecompileTest is Test {
    address constant P256_PRECOMPILE = address(0x0000000000000000000000000000000000000100);

    // Verified P-256 test vector (160 bytes: hash[32] || r[32] || s[32] || x[32] || y[32])
    bytes constant VALID_INPUT = hex"d972c2ac02cc918c29fc1819476a6eed6671118fb0359a9b7a0c4f5fc4b25dd173299ebdbbcdae49e05f8e0ce305ac0b24988c6fc284ee6569a21dd17beb72f608202481988e78f2d1047867912416ac2c9ae3a554ee3eca59f02ea0c5f17f90ba3f24fb7b03f2e0720d70984fe1dbeafdc0133b371f6490fe02138b96a4250de99f23cb34ae6bdb48d2cd43aa8ae67d4271fa16b98fb6501bf41d2ebd0f7116";

    // Tampered test vector (first byte altered from d9 to 00)
    bytes constant TAMPERED_INPUT = hex"0072c2ac02cc918c29fc1819476a6eed6671118fb0359a9b7a0c4f5fc4b25dd173299ebdbbcdae49e05f8e0ce305ac0b24988c6fc284ee6569a21dd17beb72f608202481988e78f2d1047867912416ac2c9ae3a554ee3eca59f02ea0c5f17f90ba3f24fb7b03f2e0720d70984fe1dbeafdc0133b371f6490fe02138b96a4250de99f23cb34ae6bdb48d2cd43aa8ae67d4271fa16b98fb6501bf41d2ebd0f7116";

    function setUp() public {
        try vm.createSelectFork("monad_testnet") {} catch {}
    }

    function test_P256Precompile_ValidSignature() public view {
        assertEq(VALID_INPUT.length, 160, "Input length must be 160 bytes");

        uint256 gasBefore = gasleft();
        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(VALID_INPUT);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for valid P256 verification:", gasUsed);
        assertTrue(success, "Staticcall to P256 precompile should succeed");
        assertEq(ret.length, 32, "Return data must be 32 bytes");
        assertEq(abi.decode(ret, (uint256)), 1, "Return value must be 1 for valid signature");
    }

    function test_P256Precompile_TamperedHash() public view {
        assertEq(TAMPERED_INPUT.length, 160, "Input length must be 160 bytes");

        uint256 gasBefore = gasleft();
        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(TAMPERED_INPUT);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for tampered P256 verification:", gasUsed);
        if (success) {
            if (ret.length == 32) {
                assertEq(abi.decode(ret, (uint256)), 0, "Return value must be 0 or empty for tampered input");
            } else {
                assertEq(ret.length, 0, "Return data must be empty for invalid signature");
            }
        } else {
            assertTrue(!success, "Staticcall failed as expected for invalid signature");
        }
    }
}
