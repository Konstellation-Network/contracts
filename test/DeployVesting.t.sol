// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployVestingScript} from "../script/DeployVesting.s.sol";
import {Create2DeployerLib} from "../script/lib/Create2Deployer.sol";
import {KonstellationVestingWallet} from "../src/vesting/KonstellationVestingWallet.sol";
import {RevocableVestingWallet} from "../src/vesting/RevocableVestingWallet.sol";
import {VestingSchedules} from "../src/vesting/VestingSchedules.sol";

/// @notice Runs script/DeployVesting.s.sol against the example config with the real
/// Create2Deployer bytecode etched at its canonical address, and checks that what comes out is
/// the TOKENOMICS.md §7 schedule: right contract per bucket, right parameters, right amounts,
/// deterministic addresses, and both funding paths (genesis pre-funding and `fund()`).
contract DeployVestingTest is Test {
    string internal constant CONFIG = "script/config/vesting.example.json";
    uint64 internal constant YEAR = 365 days;
    uint64 internal constant TGE = 1_800_000_000; // from the example config
    address internal constant REVOKER = 0x1000000000000000000000000000000000000001;
    address internal constant TREASURY = 0x1000000000000000000000000000000000000002;

    DeployVestingScript internal script;

    function setUp() public {
        vm.etch(Create2DeployerLib.addr(vm), Create2DeployerLib.code(vm));
        script = new DeployVestingScript();
    }

    function test_PlanExpandsExampleConfig() public view {
        DeployVestingScript.Wallet[] memory w = script.plan(CONFIG);
        // 1 treasury + 3 community x 5 tranches + 2 team
        assertEq(w.length, 1 + 3 * 5 + 2);

        uint256 total;
        uint256 revocable;
        for (uint256 i = 0; i < w.length; i++) {
            total += w[i].amount;
            if (w[i].revocable) revocable++;
            assertEq(w[i].salt, script.salt(w[i].label));
            assertEq(w[i].addr.code.length, 0, "nothing deployed yet");
            for (uint256 j = i + 1; j < w.length; j++) {
                assertTrue(w[i].addr != w[j].addr, "address collision");
            }
        }
        assertEq(total, 720_000_000 ether, "220 M team + 200 M treasury + 300 M community");
        assertEq(revocable, 2, "only team grants are revocable");
    }

    function test_PlanIsDeterministic() public view {
        DeployVestingScript.Wallet[] memory a = script.plan(CONFIG);
        DeployVestingScript.Wallet[] memory b = script.plan(CONFIG);
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i].addr, b[i].addr);
            assertEq(
                a[i].addr,
                Create2DeployerLib.predict(
                    Create2DeployerLib.addr(vm), script.salt(a[i].label), a[i].initCode
                )
            );
        }
    }

    function test_RunDeploysTheScheduleAtPredictedAddresses() public {
        DeployVestingScript.Wallet[] memory planned = script.plan(CONFIG);
        DeployVestingScript.Wallet[] memory deployed = script.run();
        assertEq(deployed.length, planned.length);

        for (uint256 i = 0; i < planned.length; i++) {
            DeployVestingScript.Wallet memory x = planned[i];
            assertEq(deployed[i].addr, x.addr);
            assertGt(x.addr.code.length, 0, x.label);

            // runtimeCode is unavailable for contracts with immutables; the constructor
            // parameters read back below identify the contract instead.
            if (x.revocable) {
                RevocableVestingWallet t = RevocableVestingWallet(payable(x.addr));
                (uint64 s, uint64 c, uint64 d) = VestingSchedules.team(TGE);
                assertEq(t.start(), s);
                assertEq(t.cliff(), s + c);
                assertEq(t.duration(), d);
                assertEq(t.revoker(), REVOKER);
                assertEq(t.treasury(), TREASURY);
                assertFalse(t.revoked());
                assertEq(x.amount, 110_000_000 ether);
            } else {
                KonstellationVestingWallet t = KonstellationVestingWallet(payable(x.addr));
                assertTrue(t.owner() != address(0));
                assertEq(t.cliff(), t.start(), "no cliff on non-revocable wallets");
                // Not a RevocableVestingWallet: no `revoker()`.
                (bool ok,) = x.addr.staticcall(abi.encodeWithSignature("revoker()"));
                assertFalse(ok, x.label);
            }
        }

        // The named wallets carry the §7 parameters.
        KonstellationVestingWallet treasury = KonstellationVestingWallet(payable(planned[0].addr));
        assertEq(planned[0].label, "treasury-locked");
        assertEq(treasury.owner(), TREASURY);
        assertEq(treasury.start(), TGE);
        assertEq(treasury.duration(), 4 * YEAR);
        assertEq(planned[0].amount, 200_000_000 ether);

        // community-grants: 180 M over 5 tranches, 30/25/20/15/10 %.
        uint256[5] memory tranche = [
            uint256(54_000_000 ether),
            45_000_000 ether,
            36_000_000 ether,
            27_000_000 ether,
            18_000_000 ether
        ];
        for (uint64 k = 0; k < 5; k++) {
            DeployVestingScript.Wallet memory x = planned[1 + k];
            assertEq(x.label, string.concat("community-grants-y", vm.toString(k + 1)));
            KonstellationVestingWallet w = KonstellationVestingWallet(payable(x.addr));
            assertEq(w.start(), TGE + k * YEAR);
            assertEq(w.duration(), YEAR);
            assertEq(x.amount, tranche[k]);
        }

        // Idempotent: a second run deploys nothing and returns the same plan.
        DeployVestingScript.Wallet[] memory again = script.run();
        assertEq(again[0].addr, planned[0].addr);
    }

    /// @dev Mainnet path: genesis.json holds each allocation at the predicted address; the code
    /// lands later and the pre-existing balance vests on the schedule.
    function test_GenesisPrefundedAddressesVestAfterDeploy() public {
        DeployVestingScript.Wallet[] memory planned = script.plan(CONFIG);
        for (uint256 i = 0; i < planned.length; i++) {
            vm.deal(planned[i].addr, planned[i].amount);
        }
        script.run();

        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.balance, planned[i].amount, planned[i].label);
        }

        // Team wallet: 0 at the cliff, 1/3 a year later.
        RevocableVestingWallet team = RevocableVestingWallet(payable(planned[16].addr));
        assertEq(planned[16].label, "team-founder-1");
        vm.warp(TGE + YEAR);
        assertEq(team.releasable(), 0);
        vm.warp(TGE + 2 * YEAR);
        assertEq(team.releasable(), uint256(110_000_000 ether) / 3);

        // And the D12 revoke works on the deployed instance.
        vm.prank(REVOKER);
        team.revoke();
        assertEq(TREASURY.balance, 110_000_000 ether - uint256(110_000_000 ether) / 3);
    }

    /// @dev Testnet path: nothing in genesis, `fund()` tops every wallet up from the broadcaster.
    function test_FundTopsUpToConfiguredAmounts() public {
        DeployVestingScript.Wallet[] memory planned = script.run();
        vm.deal(address(script), 720_000_000 ether);
        // One wallet already partly funded: only the shortfall is sent.
        vm.deal(planned[0].addr, 1 ether);

        script.fund();

        // Exactly the configured amount everywhere: the pre-funded wallet got the shortfall,
        // not the full amount on top.
        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.balance, planned[i].amount, planned[i].label);
        }

        // Nothing more to send on a second pass.
        script.fund();
        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.balance, planned[i].amount, planned[i].label);
        }
    }

    function test_RevertWhen_UnknownKind() public {
        vm.expectRevert(bytes("advisor-1: unknown kind 'advisor'"));
        script.plan("test/fixtures/vesting.bad-kind.json");
    }

    function test_RevertWhen_DuplicateLabel() public {
        vm.expectRevert(bytes("duplicate label: team-a"));
        script.plan("test/fixtures/vesting.dup-label.json");
    }

    function test_RevertWhen_Create2DeployerMissing() public {
        vm.etch(Create2DeployerLib.addr(vm), "");
        vm.expectRevert(bytes("DeployVesting: Create2Deployer is not preinstalled here"));
        script.run();
    }
}
