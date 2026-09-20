// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {WKASH} from "../src/WKASH.sol";
import {Create2DeployerLib, ICreate2Deployer} from "./lib/Create2Deployer.sol";

/// @notice Deploys WKASH post-genesis through the preinstalled Create2Deployer with a fixed salt,
/// so its address is the same on every Konstellation network (testnet-1, konstellation-1, local
/// dev) and can be hard-coded by chain-config, docs and integrations (ENGINEERING.md §6.3,
/// STATUS.md §1). Anyone may run it; whoever does, the result is identical.
///
/// The address depends only on (Create2Deployer address, SALT, WKASH init code). Init code is a
/// pure function of src/WKASH.sol and foundry.toml's solc / optimizer / evm_version settings
/// (metadata is stripped, see foundry.toml). test/DeployWKASH.t.sol pins the resulting address;
/// change any input and that test — and README — must be updated deliberately.
///
/// Usage:
///   forge script script/DeployWKASH.s.sol --sig "predict()"                 # print the address
///   forge script script/DeployWKASH.s.sol --rpc-url ... --broadcast ...     # deploy
contract DeployWKASHScript is Script {
    /// @notice Fixed CREATE2 salt. Preimage: the string "konstellation-network/contracts:WKASH:v1".
    bytes32 public constant SALT = keccak256("konstellation-network/contracts:WKASH:v1");

    /// @notice The WKASH creation bytecode this script deploys.
    function initCode() public pure returns (bytes memory) {
        return type(WKASH).creationCode;
    }

    /// @notice The address WKASH will be (or is) deployed at.
    function predict() public view returns (address predicted) {
        predicted = Create2DeployerLib.predict(Create2DeployerLib.addr(vm), SALT, initCode());
        console.log("Create2Deployer:", Create2DeployerLib.addr(vm));
        console.log("WKASH salt:     ", vm.toString(SALT));
        console.log("WKASH address:  ", predicted);
    }

    /// @notice Deploys WKASH if it is not already at its predicted address. Idempotent.
    function run() external returns (address wkash) {
        address deployer = Create2DeployerLib.addr(vm);
        require(deployer.code.length > 0, "DeployWKASH: Create2Deployer is not preinstalled here");

        wkash = predict();
        if (wkash.code.length > 0) {
            console.log("WKASH already deployed; nothing to do.");
            return wkash;
        }

        vm.startBroadcast();
        ICreate2Deployer(deployer).deploy(0, SALT, initCode());
        vm.stopBroadcast();

        require(wkash.code.length > 0, "DeployWKASH: no code at the predicted address");
        require(WKASH(payable(wkash)).decimals() == 18, "DeployWKASH: unexpected contract");
        console.log("WKASH deployed at", wkash);
    }
}
