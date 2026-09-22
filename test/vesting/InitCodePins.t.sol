// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {WKASH} from "../../src/WKASH.sol";
import {KonstellationVestingWallet} from "../../src/vesting/KonstellationVestingWallet.sol";
import {RevocableVestingWallet} from "../../src/vesting/RevocableVestingWallet.sol";
import {InitCodePins} from "../../script/lib/InitCodePins.sol";

/// @notice Pins the creation-code hash of every CREATE2-deployed contract. A vesting wallet's
/// address is `keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(creationCode ‖ args))`, so any
/// change to the compiled code -- including one inside OpenZeppelin, which WKASH does not
/// import and so the WKASH pin would not notice -- moves every wallet address. If one of these
/// fails, the change is deliberate or it is not; either way every published allocation list
/// built on the old hash is now wrong, and README's table must move with the new value.
///
/// The pins themselves live in script/lib/InitCodePins.sol, where every deploy-script entry
/// point checks them; this test pins those constants to literal values so that a drift cannot
/// be "fixed" by silently moving the library constant along with it.
contract InitCodePinsTest is Test {
    bytes32 internal constant WKASH_INIT =
        0x0802161d14ce9ad706732c67cb2c77690bd95b8bf26e10353c746b3e3d768e64;
    bytes32 internal constant KONSTELLATION_WALLET_INIT =
        0xb3500e085d7b62e11effa65bee747ae5ea54eedeeef3e97a1ec88368485747e0;
    bytes32 internal constant REVOCABLE_WALLET_INIT =
        0x58a1dce05f84504570335ee131f82397a6d370932acfe6d8cfd465d4c1b6f59e;

    function test_LibraryPinsMatchTheseLiterals() public pure {
        assertEq(InitCodePins.WKASH_INIT, WKASH_INIT);
        assertEq(InitCodePins.KONSTELLATION_WALLET_INIT, KONSTELLATION_WALLET_INIT);
        assertEq(InitCodePins.REVOCABLE_WALLET_INIT, REVOCABLE_WALLET_INIT);
    }

    function test_CanonicalBuildPassesTheLibraryChecks() public pure {
        InitCodePins.requireCanonicalWKASH();
        InitCodePins.requireCanonicalVesting();
    }

    function test_RequireMatchRevertsOnDrift() public {
        vm.expectRevert(
            bytes(
                "drifted build: X creation code hash does not match script/lib/InitCodePins.sol (compiler settings, .env, --via-ir or a dependency changed)"
            )
        );
        this.drift();
    }

    function drift() external pure {
        InitCodePins.requireMatch(bytes32(uint256(1)), bytes32(uint256(2)), "X");
    }

    function test_WKASHInitCodeIsPinned() public pure {
        assertEq(keccak256(type(WKASH).creationCode), WKASH_INIT, "WKASH init code changed");
    }

    function test_KonstellationVestingWalletInitCodeIsPinned() public pure {
        bytes32 h = keccak256(type(KonstellationVestingWallet).creationCode);
        console.log("KonstellationVestingWallet creation code hash:", vm.toString(h));
        assertEq(h, KONSTELLATION_WALLET_INIT, "KonstellationVestingWallet init code changed");
    }

    function test_RevocableVestingWalletInitCodeIsPinned() public pure {
        bytes32 h = keccak256(type(RevocableVestingWallet).creationCode);
        console.log("RevocableVestingWallet creation code hash:", vm.toString(h));
        assertEq(h, REVOCABLE_WALLET_INIT, "RevocableVestingWallet init code changed");
    }
}
