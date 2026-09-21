// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console} from "forge-std/Test.sol";
import {WKASH} from "../../src/WKASH.sol";
import {KonstellationVestingWallet} from "../../src/vesting/KonstellationVestingWallet.sol";
import {RevocableVestingWallet} from "../../src/vesting/RevocableVestingWallet.sol";

/// @notice Pins the creation-code hash of every CREATE2-deployed contract. A vesting wallet's
/// address is `keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(creationCode ‖ args))`, so any
/// change to the compiled code -- including one inside OpenZeppelin, which WKASH does not
/// import and so the WKASH pin would not notice -- moves every wallet address. If one of these
/// fails, the change is deliberate or it is not; either way every published allocation list
/// built on the old hash is now wrong, and README's table must move with the new value.
contract InitCodePinsTest is Test {
    bytes32 internal constant WKASH_INIT =
        0x0802161d14ce9ad706732c67cb2c77690bd95b8bf26e10353c746b3e3d768e64;
    bytes32 internal constant KONSTELLATION_WALLET_INIT =
        0xb3500e085d7b62e11effa65bee747ae5ea54eedeeef3e97a1ec88368485747e0;
    bytes32 internal constant REVOCABLE_WALLET_INIT =
        0x58a1dce05f84504570335ee131f82397a6d370932acfe6d8cfd465d4c1b6f59e;

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
