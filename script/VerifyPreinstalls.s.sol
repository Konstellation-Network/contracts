// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Live check: confirms each preinstalls/*.json still matches what is actually deployed
/// today at its canonical address. Deployed bytecode cannot change post-deploy, so this mainly
/// catches a wrong address or a copy/paste error at pin time -- run it once when adding or
/// updating an entry, and periodically thereafter as a regression guard.
///
/// Usage:
///   MAINNET_RPC_URL=https://... forge script script/VerifyPreinstalls.s.sol
contract VerifyPreinstallsScript is Script {
    string internal constant PREINSTALLS_DIR = "preinstalls";

    function run() external {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        VmSafe.DirEntry[] memory entries = vm.readDir(PREINSTALLS_DIR);

        bool allOk = true;
        uint256 checked;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir || !_hasSuffix(entries[i].path, ".json")) continue;
            allOk = _verify(entries[i].path) && allOk;
            checked++;
        }

        require(checked > 0, "VerifyPreinstalls: no preinstalls/*.json files found");
        require(
            allOk, "VerifyPreinstalls: one or more preinstalls drifted from their live deployment"
        );
        console.log(
            string.concat("All ", vm.toString(checked), " preinstalls match their live deployment.")
        );
    }

    function _verify(string memory path) internal view returns (bool) {
        string memory json = vm.readFile(path);

        address addr = vm.parseJsonAddress(json, ".address");
        bytes memory pinnedCode = vm.parseJsonBytes(json, ".code");
        bytes memory liveCode = addr.code;

        string memory label = _basename(path);
        if (keccak256(liveCode) == keccak256(pinnedCode)) {
            console.log(string.concat(unicode"OK   ", label));
            return true;
        }

        console.log(string.concat(unicode"FAIL ", label, " -- drifted from live deployment"));
        console.log("  address:", addr);
        console.log("  pinned code length:", pinnedCode.length);
        console.log("  live code length:  ", liveCode.length);
        return false;
    }

    function _basename(string memory path) internal pure returns (string memory) {
        bytes memory p = bytes(path);
        uint256 lastSlash = 0;
        for (uint256 i = 0; i < p.length; i++) {
            if (p[i] == "/") lastSlash = i + 1;
        }
        bytes memory out = new bytes(p.length - lastSlash);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = p[lastSlash + i];
        }
        return string(out);
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
}
