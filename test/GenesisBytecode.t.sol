// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {WKASH} from "../src/WKASH.sol";

/// @notice Guards the JSON blobs in preinstalls/ against silent drift or corruption.
/// Each file's `code` is the bytecode konstellation's genesis wiring embeds at `address`
/// (ENGINEERING.md §6.3); `codeHash` is keccak256(code) as recorded the day the bytecode was
/// pinned from the contract's canonical deployment.
///
/// This is a self-consistency check only -- it catches a hand-edit that corrupts `code` without
/// updating `codeHash` alongside it, but a `code`/`codeHash` pair that was wrong from the start
/// (or has drifted from the real on-chain deployment since) will pass it silently. The only
/// check against reality is script/VerifyPreinstalls.s.sol, which needs a live RPC and so isn't
/// run on every commit -- run it by hand whenever a preinstalls/*.json file is added or edited.
contract GenesisBytecodeTest is Test {
    string internal constant PREINSTALLS_DIR = "preinstalls";

    function test_PreinstallBytecodeMatchesPinnedHash() public view {
        VmSafe.DirEntry[] memory entries = vm.readDir(PREINSTALLS_DIR);

        uint256 checked;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir || !_hasSuffix(entries[i].path, ".json")) continue;
            _checkPreinstall(entries[i].path);
            checked++;
        }

        // Guards against a typo'd PREINSTALLS_DIR or an accidentally emptied directory making
        // this loop -- and the whole test -- pass vacuously.
        assertGt(checked, 0, "no preinstalls/*.json files found");
    }

    function _checkPreinstall(string memory path) internal view {
        string memory json = vm.readFile(path);

        address addr = vm.parseJsonAddress(json, ".address");
        bytes memory code = vm.parseJsonBytes(json, ".code");
        bytes32 expectedHash = vm.parseJsonBytes32(json, ".codeHash");

        assertTrue(code.length > 0, string.concat(path, ": code is empty"));
        assertLe(code.length, 24576, string.concat(path, ": code exceeds EIP-170 size limit"));
        assertEq(
            keccak256(code),
            expectedHash,
            string.concat(path, ": codeHash does not match pinned code")
        );
        assertTrue(addr != address(0), string.concat(path, ": address is zero"));
    }

    function _hasSuffix(string memory str, string memory suffix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory suf = bytes(suffix);
        if (suf.length > s.length) return false;
        for (uint256 i = 0; i < suf.length; i++) {
            if (s[s.length - suf.length + i] != suf[i]) return false;
        }
        return true;
    }

    function test_WKASHDeploysWithNonEmptyRuntimeCode() public {
        WKASH w = new WKASH();
        assertGt(address(w).code.length, 0);
        assertEq(w.decimals(), 18);
        assertEq(w.totalSupply(), 0);
    }
}
