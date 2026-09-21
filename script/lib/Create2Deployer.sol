// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {VmSafe} from "forge-std/Vm.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @notice The subset of the preinstalled `Create2Deployer` (pcaversaccio's, pinned in
/// preinstalls/Create2Deployer.json at 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2) that the
/// deploy scripts use. `deploy` is permissionless; the preinstall never ran its constructor, so
/// its `owner()` is `address(0)` and `pause()` / `killCreate2Deployer()` can never be called.
interface ICreate2Deployer {
    /// @dev CREATE2 `code` with `salt`, forwarding `value` from the deployer's own balance.
    function deploy(uint256 value, bytes32 salt, bytes memory code) external;
    /// @dev Address `deploy(_, salt, code)` produces, for `codeHash = keccak256(code)`.
    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address);
}

/// @notice Helpers shared by the deploy scripts and their tests: the canonical Create2Deployer
/// address and bytecode, read from preinstalls/Create2Deployer.json (the source of truth for
/// what genesis embeds), and the CREATE2 address formula for it.
library Create2DeployerLib {
    string internal constant PREINSTALL_JSON = "preinstalls/Create2Deployer.json";

    /// @dev The address the chain preinstalls the deployer at.
    function addr(VmSafe vm) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(PREINSTALL_JSON), ".address");
    }

    /// @dev The pinned runtime bytecode, for `vm.etch` in tests.
    function code(VmSafe vm) internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(PREINSTALL_JSON), ".code");
    }

    /// @dev Address `Create2Deployer.deploy(_, salt, initCode)` produces, computed locally:
    /// `keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(initCode))[12:]`.
    function predict(address deployer, bytes32 salt, bytes memory initCode)
        internal
        pure
        returns (address)
    {
        return Create2.computeAddress(salt, keccak256(initCode), deployer);
    }
}
