// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KonstellationVestingWallet} from "../src/vesting/KonstellationVestingWallet.sol";
import {Create2DeployerLib, ICreate2Deployer} from "../script/lib/Create2Deployer.sol";

interface ICreate2DeployerAdmin {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function pause() external;
}

/// @notice What the deploy scripts assume about the preinstalled Create2Deployer, checked
/// against its pinned bytecode in genesis state (no constructor ever ran): unowned, unpaused,
/// permissionless `deploy`, a second deploy at the same address reverts, and a different init
/// code lands elsewhere -- so nobody can squat a predicted address with other code.
contract Create2DeployerPreinstallTest is Test {
    address internal deployer;

    function setUp() public {
        deployer = Create2DeployerLib.addr(vm);
        vm.etch(deployer, Create2DeployerLib.code(vm));
    }

    function test_GenesisStateIsUnownedAndUnpaused() public {
        assertEq(ICreate2DeployerAdmin(deployer).owner(), address(0));
        assertFalse(ICreate2DeployerAdmin(deployer).paused());
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(); // onlyOwner, and there is no owner
        ICreate2DeployerAdmin(deployer).pause();
    }

    function test_PermissionlessDeployOntoPrefundedAddress() public {
        address member = makeAddr("member");
        uint64 start = uint64(block.timestamp) + 1;
        bytes memory init = abi.encodePacked(
            type(KonstellationVestingWallet).creationCode,
            abi.encode(member, start, uint64(0), uint64(365 days))
        );
        bytes32 salt = bytes32(uint256(1));
        address p = Create2DeployerLib.predict(deployer, salt, init);
        vm.deal(p, 5 ether); // genesis-style pre-funding

        vm.prank(makeAddr("anyone"));
        ICreate2Deployer(deployer).deploy(0, salt, init);
        assertGt(p.code.length, 0);
        assertEq(p.balance, 5 ether);
        assertEq(KonstellationVestingWallet(payable(p)).owner(), member);

        // Same salt + init code again: CREATE2 collision, reverts.
        vm.expectRevert();
        ICreate2Deployer(deployer).deploy(0, salt, init);

        // Same salt, different beneficiary: a different address, so the pre-funded one cannot
        // be taken over with other code.
        bytes memory init2 = abi.encodePacked(
            type(KonstellationVestingWallet).creationCode,
            abi.encode(makeAddr("x"), start, uint64(0), uint64(365 days))
        );
        assertTrue(Create2DeployerLib.predict(deployer, salt, init2) != p);
    }
}
