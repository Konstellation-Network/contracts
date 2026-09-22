// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

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
        // Env vars are process-wide and tests run in parallel, so every test here uses the
        // explicit-path entry points; only test_EnvVarsSelectConfigAndFundingPolicy reads env.
    }

    function test_PlanExpandsExampleConfig() public view {
        DeployVestingScript.Wallet[] memory w = script.plan(CONFIG);
        // 1 treasury + 2 community x 5 tranches + 2 team
        assertEq(w.length, 1 + 2 * 5 + 2);

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
        assertEq(total, 678_000_000 ether, "198 M team locked + 200 M treasury + 280 M community");
        assertEq(revocable, 2, "only team grants are revocable");
    }

    function test_AllocationsListWalletsThenTeamLiquid() public view {
        DeployVestingScript.Wallet[] memory w = script.plan(CONFIG);
        DeployVestingScript.Allocation[] memory a = script.allocations(CONFIG);
        assertEq(a.length, w.length + 2, "one liquid entry per team grant");

        uint256 locked;
        uint256 liquid;
        for (uint256 i = 0; i < a.length; i++) {
            if (i < w.length) {
                assertTrue(a[i].isWallet);
                assertEq(a[i].addr, w[i].addr);
                assertEq(a[i].amount, w[i].amount);
                assertEq(a[i].label, w[i].label);
                locked += a[i].amount;
            } else {
                assertFalse(a[i].isWallet);
                liquid += a[i].amount;
            }
        }
        assertEq(locked, 678_000_000 ether);
        assertEq(liquid, 22_000_000 ether, "10 % of the 220 M team bucket");
        assertEq(locked + liquid, 700_000_000 ether, "team 220 + treasury 200 + community 280");

        // The liquid 10 % goes to the member's own address, not to a contract.
        assertEq(a[w.length].label, "team-founder-1-liquid");
        assertEq(a[w.length].addr, 0x2000000000000000000000000000000000000001);
        assertEq(a[w.length].amount, 11_000_000 ether);
        assertEq(a[w.length + 1].label, "team-founder-2-liquid");
        assertEq(a[w.length + 1].addr, 0x2000000000000000000000000000000000000002);
        assertEq(a[w.length + 1].amount, 11_000_000 ether);
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
        DeployVestingScript.Wallet[] memory deployed = script.run(CONFIG, true, false);
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
                assertEq(x.amount, 99_000_000 ether, "90 % of the 110 M grant");
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
        DeployVestingScript.Wallet[] memory again = script.run(CONFIG, true, false);
        assertEq(again[0].addr, planned[0].addr);
    }

    /// @dev Mainnet path: genesis.json holds each allocation at the predicted address; the code
    /// lands later and the pre-existing balance vests on the schedule.
    function test_GenesisPrefundedAddressesVestAfterDeploy() public {
        DeployVestingScript.Wallet[] memory planned = script.plan(CONFIG);
        for (uint256 i = 0; i < planned.length; i++) {
            vm.deal(planned[i].addr, planned[i].amount);
        }
        script.run(CONFIG, false, false); // fully funded: strict mode passes

        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.balance, planned[i].amount, planned[i].label);
        }

        // Team wallet: 0 at the cliff, 1/3 a year later.
        RevocableVestingWallet team = RevocableVestingWallet(payable(planned[11].addr));
        assertEq(planned[11].label, "team-founder-1");
        vm.warp(TGE + YEAR);
        assertEq(team.releasable(), 0);
        vm.warp(TGE + 2 * YEAR);
        assertEq(team.releasable(), uint256(99_000_000 ether) / 3);

        // And the D12 revoke works on the deployed instance.
        vm.prank(REVOKER);
        team.revoke();
        assertEq(TREASURY.balance, 99_000_000 ether - uint256(99_000_000 ether) / 3);
    }

    /// @dev Testnet path: nothing in genesis, `fund()` tops every wallet up from the broadcaster.
    function test_FundTopsUpToConfiguredAmounts() public {
        DeployVestingScript.Wallet[] memory planned = script.run(CONFIG, true, false);
        vm.deal(address(script), 678_000_000 ether);
        // One wallet already partly funded: only the shortfall is sent.
        vm.deal(planned[0].addr, 1 ether);

        script.fund(CONFIG);

        // Exactly the configured amount everywhere: the pre-funded wallet got the shortfall,
        // not the full amount on top.
        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.balance, planned[i].amount, planned[i].label);
        }

        // Nothing more to send on a second pass.
        script.fund(CONFIG);
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
        script.run(CONFIG, true, false);
    }

    // --- review round (PR #2): config validation ------------------------------------------------

    /// @dev H1: a zero revoker/treasury would give addresses whose init code can never succeed
    /// (the constructor reverts), so genesis funds sent there would be lost. Rejected up front.
    function test_RevertWhen_ZeroRevoker() public {
        vm.expectRevert(bytes("config: zero revoker"));
        script.plan("test/fixtures/vesting.zero-revoker.json");
    }

    function test_RevertWhen_ZeroTreasury() public {
        vm.expectRevert(bytes("config: zero treasury"));
        script.plan("test/fixtures/vesting.zero-treasury.json");
    }

    /// @dev M3: quoted decimal and quoted hex amounts parse to the same value as a plain number
    /// (the old struct decode read a string's ABI head word, 128, instead).
    function test_QuotedAmountsParseExactly() public view {
        DeployVestingScript.Wallet[] memory plain = script.plan(CONFIG);
        DeployVestingScript.Wallet[] memory quoted =
            script.plan("test/fixtures/vesting.string-amount.json");
        DeployVestingScript.Wallet[] memory hex_ =
            script.plan("test/fixtures/vesting.hex-amount.json");
        assertEq(quoted.length, plain.length);
        for (uint256 i = 0; i < plain.length; i++) {
            assertEq(quoted[i].amount, plain[i].amount, plain[i].label);
            assertEq(hex_[i].amount, plain[i].amount, plain[i].label);
            assertEq(quoted[i].addr, plain[i].addr, plain[i].label);
            assertEq(hex_[i].addr, plain[i].addr, plain[i].label);
        }
        assertEq(quoted[11].amount, 99_000_000 ether, "not 128 KASH x 0.9");
    }

    /// @dev M3: keys outside the schema are refused wherever they sort.
    function test_RevertWhen_UnknownGrantKey() public {
        vm.expectRevert(bytes(".grants[3]: unknown key 'note'"));
        script.plan("test/fixtures/vesting.extra-key.json");
        vm.expectRevert(bytes(".grants[3]: unknown key 'aaa'"));
        script.plan("test/fixtures/vesting.leading-key.json");
    }

    function test_RevertWhen_MissingHeaderKey() public {
        vm.expectRevert(bytes("config: missing key 'revoker'"));
        script.plan("test/fixtures/vesting.missing-key.json");
    }

    /// @dev L2: tge is range-checked before the uint64 cast.
    function test_RevertWhen_TgeOutOfRange() public {
        vm.expectRevert(bytes("config: tge out of range (unix seconds)"));
        script.plan("test/fixtures/vesting.tge-overflow.json");
    }

    /// @dev A team label that collides with a generated community tranche label is a duplicate.
    function test_RevertWhen_CrossKindDuplicateLabel() public {
        vm.expectRevert(bytes("duplicate label: community-grants-y1"));
        script.plan("test/fixtures/vesting.crosskind.json");
    }

    /// @dev M2: VESTING_CONFIG selects the config (inside script/config or test/fixtures, the
    /// only paths fs_permissions allows). The only test that touches env, and the only one
    /// calling the env-reading entry points. Nothing else is read from the environment: run()
    /// is strict unless the explicit overload says otherwise.
    function test_EnvVarSelectsConfigAndNothingRelaxesRun() public {
        assertEq(script.configPath(), CONFIG, "default");
        vm.setEnv("VESTING_CONFIG", "test/fixtures/vesting.string-amount.json");
        assertEq(script.configPath(), "test/fixtures/vesting.string-amount.json");
        DeployVestingScript.Allocation[] memory a = script.predict();
        assertEq(a[11].label, "team-founder-1");
        assertEq(a[11].amount, 99_000_000 ether);

        // run() unfunded: refused, and ALLOW_UNFUNDED in the environment changes nothing.
        vm.setEnv("ALLOW_UNFUNDED", "true");
        vm.expectRevert();
        script.run();
        DeployVestingScript.Wallet[] memory w =
            script.plan("test/fixtures/vesting.string-amount.json");
        assertEq(w[0].addr.code.length, 0, "nothing deployed");
    }

    /// @dev M4 + L1: amounts that would produce fractional wallets are refused (genesis
    /// allocations are whole KASH): community buckets must be multiples of 20 KASH, team grants
    /// of 10 KASH.
    function test_RevertWhen_AmountsNotOnTheSection7Grid() public {
        vm.expectRevert(bytes("community-grants: community bucket must be a multiple of 20 KASH"));
        script.plan("test/fixtures/vesting.fractional.json");
        vm.expectRevert(bytes("team-founder-1: team grant must be a multiple of 10 KASH"));
        script.plan("test/fixtures/vesting.team-not-multiple-of-10.json");
    }

    function test_FormatKash() public view {
        assertEq(script.formatKash(0), "0");
        assertEq(script.formatKash(1), "0.000000000000000001");
        assertEq(script.formatKash(1 ether), "1");
        assertEq(script.formatKash(1.5 ether), "1.5");
        assertEq(script.formatKash(200_000_000 ether), "200000000");
        assertEq(script.formatKash(123.000000000000000456 ether), "123.000000000000000456");
    }

    // --- review round (PR #2): check(), strict run(), fund() on a revoked wallet ---------------

    /// @dev H1: check() executes every init code locally and proves each predicted address.
    function test_CheckDeploysEveryWalletLocally() public {
        DeployVestingScript.Wallet[] memory planned = script.plan(CONFIG);
        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.code.length, 0);
        }
        DeployVestingScript.Wallet[] memory checked = script.check(CONFIG);
        assertEq(checked.length, planned.length);
        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(checked[i].addr, planned[i].addr);
            assertGt(planned[i].addr.code.length, 0, planned[i].label);
        }
        // A second check() on the same EVM finds the code already there.
        vm.expectRevert(bytes("treasury-locked: address already has code"));
        script.check(CONFIG);
    }

    function test_CheckEtchesTheDeployerWhenAbsent() public {
        vm.etch(Create2DeployerLib.addr(vm), "");
        DeployVestingScript.Wallet[] memory checked = script.check(CONFIG);
        assertGt(checked[0].addr.code.length, 0);
    }

    /// @dev M3: run() reverts on a shortfall, only warns on a surplus (dust is not a veto), and
    /// counts released KASH as received so it stays idempotent after the first release().
    function test_RunShortfallRevertsSurplusWarnsReleasedCounts() public {
        DeployVestingScript.Wallet[] memory planned = script.plan(CONFIG);
        for (uint256 i = 0; i < planned.length; i++) {
            vm.deal(planned[i].addr, planned[i].amount);
        }
        vm.deal(planned[0].addr, planned[0].amount - 1); // one wei short
        vm.expectRevert(
            bytes(
                "shortfall: treasury-locked received 199999999.999999999999999999 KASH (balance + released), config says 200000000"
            )
        );
        script.run(CONFIG, false, false);

        vm.deal(planned[0].addr, planned[0].amount + 1); // attacker dust: surplus, warns only
        script.run(CONFIG, false, false);
        assertGt(planned[0].addr.code.length, 0);

        // Year 1: community-grants-y1 fully vested and released; run() must still pass.
        vm.warp(TGE + YEAR);
        KonstellationVestingWallet y1 = KonstellationVestingWallet(payable(planned[1].addr));
        y1.release();
        assertEq(y1.released(), planned[1].amount);
        assertEq(planned[1].addr.balance, 0);
        script.run(CONFIG, false, false);

        // And fund() sends nothing to it: it has received its amount already.
        uint256 before = y1.owner().balance;
        vm.deal(address(script), 1e9 ether);
        script.fund(CONFIG);
        assertEq(planned[1].addr.balance, 0, "not re-funded");
        y1.release();
        assertEq(y1.owner().balance, before, "beneficiary not paid twice");
    }

    /// @dev M3: a wallet at zero is a shortfall even with allowShortfall (warned, not hidden),
    /// and fund() then sends exactly the shortfall.
    function test_AllowShortfallStillReportsAndFundSendsShortfallOnly() public {
        DeployVestingScript.Wallet[] memory planned = script.run(CONFIG, true, false);
        vm.deal(planned[0].addr, 1 ether);
        vm.deal(address(script), 678_000_000 ether);
        script.fund(CONFIG);
        // The pre-funded wallet ends at exactly its amount (1 ether was already there), so
        // only the shortfall was sent.
        for (uint256 i = 0; i < planned.length; i++) {
            assertEq(planned[i].addr.balance, planned[i].amount, planned[i].label);
        }
    }

    /// @dev L1: a tge more than 30 days before the chain's clock is refused by run()/fund()
    /// unless allowStaleTge; a dev chain replaying a past schedule passes it explicitly.
    function test_RevertWhen_TgeIsStaleOnChain() public {
        vm.warp(1_000_000_000 + 31 days);
        vm.expectRevert();
        script.run("test/fixtures/vesting.stale-tge.json", true, false);
        DeployVestingScript.Wallet[] memory w =
            script.run("test/fixtures/vesting.stale-tge.json", true, true);
        assertGt(w[0].addr.code.length, 0);
        // Once deployed, re-running later is idempotent whatever the clock says.
        vm.warp(1_000_000_000 + 5 * YEAR);
        script.run("test/fixtures/vesting.stale-tge.json", true, false);
    }

    function test_FreshTgeWithinToleranceDeploys() public {
        vm.warp(1_000_000_000 + 29 days);
        DeployVestingScript.Wallet[] memory w =
            script.run("test/fixtures/vesting.stale-tge.json", true, false);
        assertGt(w[0].addr.code.length, 0);
    }

    /// @dev fund() must not top up a revoked wallet: everything it holds after a revoke belongs
    /// to the beneficiary, so a top-up would hand them what the treasury took back.
    function test_RevertWhen_FundingARevokedWallet() public {
        DeployVestingScript.Wallet[] memory planned = script.run(CONFIG, true, false);
        vm.deal(address(script), 678_000_000 ether);
        script.fund(CONFIG);

        RevocableVestingWallet team = RevocableVestingWallet(payable(planned[11].addr));
        vm.warp(TGE + 2 * YEAR);
        vm.prank(REVOKER);
        team.revoke();
        uint256 after_ = planned[11].addr.balance;
        assertLt(after_, planned[11].amount);

        vm.expectRevert(bytes("team-founder-1: revoked, refusing to fund"));
        script.fund(CONFIG);
        assertEq(planned[11].addr.balance, after_);
    }

    function test_RevertWhen_FundingBeforeDeploy() public {
        vm.expectRevert(bytes("treasury-locked: not deployed, run() first"));
        script.fund(CONFIG);
    }

    // --- adversarial review (8ac5a7d): config semantics -------------------------------------

    /// @dev M2: forge keeps the last of two duplicate keys; the raw file is counted instead.
    function test_RevertWhen_DuplicateJsonKey() public {
        vm.expectRevert(bytes("config: key 'amountKash' must occur exactly once per grant"));
        script.plan("test/fixtures/vesting.dupkey.json");
        vm.expectRevert(bytes("config: key 'tge' must occur exactly once"));
        script.plan("test/fixtures/vesting.duptge.json");
    }

    /// @dev An escaped `\"tge\":` inside _comment is a value, not a key.
    function test_EscapedKeyInCommentIsNotAKey() public view {
        DeployVestingScript.Wallet[] memory w =
            script.plan("test/fixtures/vesting.comment-with-key.json");
        assertEq(w.length, 13);
    }

    /// @dev L1: the treasury/revoker must not be a planned wallet (revoked KASH would flow to
    /// that wallet's beneficiary) nor a team beneficiary (a member could revoke their own grant).
    function test_RevertWhen_TreasuryIsAPlannedWallet() public {
        vm.expectRevert(bytes("config: treasury/revoker is the treasury-locked wallet"));
        script.plan("test/fixtures/vesting.treasury-is-wallet.json");
    }

    function test_RevertWhen_RevokerIsATeamBeneficiary() public {
        vm.expectRevert(bytes("team-founder-1: beneficiary is the revoker"));
        script.plan("test/fixtures/vesting.revoker-is-beneficiary.json");
    }

    function test_RevertWhen_BeneficiaryUsedTwice() public {
        vm.expectRevert(bytes("community-incentives: beneficiary already used by community-grants"));
        script.plan("test/fixtures/vesting.dup-beneficiary.json");
    }

    /// @dev L1: labels are [a-z0-9-]+, non-empty, never ending in -liquid. The lookalike fixture
    /// has a U+2010 hyphen in "team‐a": refused before anything else about it matters.
    function test_RevertWhen_LabelInvalid() public {
        vm.expectRevert(bytes("config: empty label"));
        script.plan("test/fixtures/vesting.emptylabel.json");
        vm.expectRevert(bytes(unicode"team‐a: label must match [a-z0-9-]+"));
        script.plan("test/fixtures/vesting.lookalike.json");
        vm.expectRevert(bytes("team-founder-1-liquid: label must not end in -liquid"));
        script.plan("test/fixtures/vesting.liquid-suffix.json");
        vm.expectRevert(bytes("Team-Founder-1: label must match [a-z0-9-]+"));
        script.plan("test/fixtures/vesting.uppercase-label.json");
    }

    /// @dev Number forms forge accepts or refuses: exponent forms and hex parse exactly; a
    /// float with a fraction, a sign, whitespace or underscores are parser errors.
    function test_NumberForms() public {
        assertEq(script.plan("test/fixtures/vesting.probe-float-1e8.json")[0].amount, 1e8 ether);
        assertEq(script.plan("test/fixtures/vesting.probe-str-1e8.json")[0].amount, 1e8 ether);
        assertEq(script.plan("test/fixtures/vesting.probe-hex.json")[0].amount, 2e8 ether);
        string[5] memory bad = ["float0", "neg", "plus", "space", "underscore"];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert();
            script.plan(string.concat("test/fixtures/vesting.probe-", bad[i], ".json"));
        }
    }
}
