// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {WKASH} from "../src/WKASH.sol";
import {DeployWKASHScript} from "../script/DeployWKASH.s.sol";
import {Create2DeployerLib, ICreate2Deployer} from "../script/lib/Create2Deployer.sol";
import {InitCodePins} from "../script/lib/InitCodePins.sol";

/// @notice Pins the WKASH deployment address. The preinstalled Create2Deployer's real bytecode
/// (from preinstalls/Create2Deployer.json) is etched at its canonical address, the deploy script
/// is run against it, and the resulting address must equal the constant below -- which is what
/// README, chain-config and docs publish. If this test fails, either the WKASH bytecode, the
/// salt, foundry.toml's compiler settings, or the Create2Deployer pin changed; each of those is a
/// deliberate decision that must update EXPECTED_WKASH and README together.
contract DeployWKASHTest is Test {
    /// @dev Independently reproducible: keccak256(0xff ++ 0x13b0D85C...beF2 ++ SALT ++
    /// keccak256(type(WKASH).creationCode))[12:], e.g. with `cast create2`.
    address internal constant EXPECTED_WKASH = 0x34Ab8285C63b876717C2c56151700D02623559bE;
    bytes32 internal constant EXPECTED_SALT =
        0x8f7bc75b1a2b0d0c1a3bcf6671fe700cea605f21ec5e30f5085debf329795ea5;

    DeployWKASHScript internal script;
    address internal deployer;

    function setUp() public {
        deployer = Create2DeployerLib.addr(vm);
        vm.etch(deployer, Create2DeployerLib.code(vm));
        script = new DeployWKASHScript();
    }

    function test_ScriptChecksThePinBeforeEmittingAnAddress() public pure {
        // initCode() is what predict()/run() hash; it reverts on a drifted build.
        assertEq(
            keccak256(InitCodePins.WKASH_INIT == bytes32(0) ? bytes("") : type(WKASH).creationCode),
            InitCodePins.WKASH_INIT
        );
    }

    function test_SaltIsTheDocumentedPreimage() public view {
        assertEq(script.SALT(), keccak256("konstellation-network/contracts:WKASH:v1"));
        assertEq(script.SALT(), EXPECTED_SALT);
    }

    function test_PredictedAddressIsPinned() public view {
        assertEq(deployer, 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2, "Create2Deployer address");
        address predicted = script.predict();
        assertEq(predicted, EXPECTED_WKASH, "WKASH address drifted -- see test NatSpec");
        // The preinstall's own formula agrees with the local one.
        assertEq(
            ICreate2Deployer(deployer).computeAddress(script.SALT(), keccak256(script.initCode())),
            EXPECTED_WKASH
        );
        console.log("WKASH predicted address:", predicted);
    }

    function test_DeploysAtPredictedAddressAndIsIdempotent() public {
        address wkash = script.run();
        assertEq(wkash, EXPECTED_WKASH);
        assertGt(wkash.code.length, 0);
        assertEq(WKASH(payable(wkash)).decimals(), 18);
        assertEq(keccak256(bytes(WKASH(payable(wkash)).symbol())), keccak256("WKASH"));

        // Deployed code is the compiler's runtime code for WKASH, byte for byte.
        assertEq(wkash.code, type(WKASH).runtimeCode);

        // A second run finds the code and does nothing.
        assertEq(script.run(), EXPECTED_WKASH);

        // And the deployed contract works: 1 KASH in, 1 WKASH out, 1 KASH back.
        address user = makeAddr("user");
        vm.deal(user, 1 ether);
        vm.prank(user);
        WKASH(payable(wkash)).deposit{value: 1 ether}();
        assertEq(WKASH(payable(wkash)).balanceOf(user), 1 ether);
        vm.prank(user);
        WKASH(payable(wkash)).withdraw(1 ether);
        assertEq(user.balance, 1 ether);
    }

    function test_BytecodeCarriesNoMetadata() public pure {
        // foundry.toml strips CBOR metadata so comment-only edits do not move the address. Solc
        // appends metadata as `... 0xa2 0x64 'ipfs' ... 0x00 <len>`; with it stripped the init
        // code must not end with a 2-byte CBOR length trailer that points inside itself.
        bytes memory code = type(WKASH).creationCode;
        uint256 n = code.length;
        uint256 trailer = (uint256(uint8(code[n - 2])) << 8) | uint256(uint8(code[n - 1]));
        bool looksLikeCbor = trailer > 0 && trailer + 2 <= n && code[n - 2 - trailer] == 0xa2;
        assertFalse(looksLikeCbor, "CBOR metadata present: set cbor_metadata = false");
    }

    function test_RevertsWhereCreate2DeployerIsMissing() public {
        vm.etch(deployer, "");
        vm.expectRevert(bytes("DeployWKASH: Create2Deployer is not preinstalled here"));
        script.run();
    }
}
