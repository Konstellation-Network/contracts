// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VestingSchedules} from "../../src/vesting/VestingSchedules.sol";
import {KonstellationVestingWallet} from "../../src/vesting/KonstellationVestingWallet.sol";

/// @notice Pins `VestingSchedules` to the TOKENOMICS.md §7 numbers and its year-end table.
contract VestingSchedulesTest is Test {
    uint64 internal constant YEAR = 365 days;
    uint64 internal constant TGE = 1_800_000_000;
    address internal beneficiary = makeAddr("beneficiary");

    function test_TeamParameters() public pure {
        (uint64 start, uint64 cliff, uint64 duration) = VestingSchedules.team(TGE);
        assertEq(start, TGE + YEAR, "linear part starts at the 12-month cliff");
        assertEq(cliff, 0);
        assertEq(duration, 3 * YEAR, "linear over 36 months");
        assertEq(start + duration, TGE + 4 * YEAR, "4 years total");
    }

    function test_TreasuryParameters() public pure {
        (uint64 start, uint64 cliff, uint64 duration) = VestingSchedules.treasury(TGE);
        assertEq(start, TGE);
        assertEq(cliff, 0);
        assertEq(duration, 4 * YEAR, "linear over 48 months");
    }

    function test_CommunityTranches() public pure {
        uint256 locked = 300_000_000 ether;
        uint256[5] memory expected = [
            uint256(90_000_000 ether),
            75_000_000 ether,
            60_000_000 ether,
            45_000_000 ether,
            30_000_000 ether
        ];
        uint256 sum;
        for (uint64 k = 0; k < 5; k++) {
            (uint64 start, uint64 cliff, uint64 duration, uint256 amount) =
                VestingSchedules.communityTranche(TGE, locked, k);
            assertEq(start, TGE + k * YEAR);
            assertEq(cliff, 0);
            assertEq(duration, YEAR);
            assertEq(amount, expected[k]);
            assertEq(VestingSchedules.communityTrancheBps(k), 3000 - 500 * k);
            sum += amount;
        }
        assertEq(sum, locked);
    }

    function test_RevertWhen_TrancheOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(VestingSchedules.InvalidTranche.selector, 5));
        this.tranche(5);
        vm.expectRevert(abi.encodeWithSelector(VestingSchedules.InvalidTranche.selector, 5));
        this.bps(5);
    }

    function tranche(uint256 k) external pure {
        VestingSchedules.communityTranche(TGE, 1 ether, k);
    }

    function bps(uint256 k) external pure {
        VestingSchedules.communityTrancheBps(k);
    }

    function testFuzz_CommunityTranchesSumExactly(uint128 locked) public pure {
        uint256 sum;
        for (uint256 k = 0; k < 5; k++) {
            (,,, uint256 amount) = VestingSchedules.communityTranche(TGE, locked, k);
            sum += amount;
        }
        assertEq(sum, locked);
    }

    /// @dev The §7 year-end table (issuance excluded): team 0 / 73 / 147 / 220 M, treasury
    /// 100 / 150 / 200 / 250 M (incl. 50 M liquid), community 120 / 195 / 255 / 300 / 330 M
    /// (incl. 30 M liquid), driven through real wallets.
    function test_YearEndTableMatchesTokenomics() public {
        (uint64 ts, uint64 tc, uint64 td) = VestingSchedules.team(TGE);
        KonstellationVestingWallet team =
            new KonstellationVestingWallet{value: 220_000_000 ether}(beneficiary, ts, tc, td);
        (uint64 rs, uint64 rc, uint64 rd) = VestingSchedules.treasury(TGE);
        KonstellationVestingWallet treasury =
            new KonstellationVestingWallet{value: 200_000_000 ether}(beneficiary, rs, rc, rd);
        KonstellationVestingWallet[5] memory community;
        for (uint256 k = 0; k < 5; k++) {
            (uint64 s, uint64 c, uint64 d, uint256 a) =
                VestingSchedules.communityTranche(TGE, 300_000_000 ether, k);
            community[k] = new KonstellationVestingWallet{value: a}(beneficiary, s, c, d);
        }

        uint256[6] memory teamTable = [
            uint256(0),
            0,
            73_333_333_333333333333333333,
            146_666_666_666666666666666666,
            220_000_000 ether,
            220_000_000 ether
        ];
        uint256[6] memory treasuryTable = [
            uint256(50_000_000 ether),
            100_000_000 ether,
            150_000_000 ether,
            200_000_000 ether,
            250_000_000 ether,
            250_000_000 ether
        ];
        uint256[6] memory communityTable = [
            uint256(30_000_000 ether),
            120_000_000 ether,
            195_000_000 ether,
            255_000_000 ether,
            300_000_000 ether,
            330_000_000 ether
        ];

        for (uint64 y = 0; y <= 5; y++) {
            uint64 t = TGE + y * YEAR;
            assertEq(
                team.vestedAmount(t), teamTable[y], string.concat("team, year ", vm.toString(y))
            );
            assertEq(
                50_000_000 ether + treasury.vestedAmount(t),
                treasuryTable[y],
                string.concat("treasury, year ", vm.toString(y))
            );
            uint256 c = 30_000_000 ether;
            for (uint256 k = 0; k < 5; k++) {
                c += community[k].vestedAmount(t);
            }
            assertEq(c, communityTable[y], string.concat("community, year ", vm.toString(y)));
        }
    }
}
