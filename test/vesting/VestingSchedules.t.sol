// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

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

    function test_TeamSplit() public pure {
        (uint256 liquid, uint256 locked) = VestingSchedules.teamSplit(110_000_000 ether);
        assertEq(liquid, 11_000_000 ether, "10 % liquid at genesis");
        assertEq(locked, 99_000_000 ether, "90 % into the revocable wallet");
        assertEq(VestingSchedules.TEAM_LIQUID_BPS, 1000);
    }

    function testFuzz_TeamSplitIsExact(uint128 grant) public pure {
        (uint256 liquid, uint256 locked) = VestingSchedules.teamSplit(grant);
        assertEq(liquid + locked, grant);
        assertEq(liquid, uint256(grant) / 10);
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

    KonstellationVestingWallet internal teamWallet;
    KonstellationVestingWallet internal treasuryWallet;
    KonstellationVestingWallet[5] internal grantWallets;
    KonstellationVestingWallet[5] internal incentiveWallets;

    /// @dev Deploys the whole §7 schedule as real wallets: 198 M team (locked 90 %), 200 M
    /// treasury, 180 M grants + 100 M incentives in 5 yearly tranches each.
    function _deploySchedule() internal {
        (, uint256 teamLocked) = VestingSchedules.teamSplit(220_000_000 ether);
        (uint64 ts, uint64 tc, uint64 td) = VestingSchedules.team(TGE);
        teamWallet = new KonstellationVestingWallet{value: teamLocked}(beneficiary, ts, tc, td);
        (uint64 rs, uint64 rc, uint64 rd) = VestingSchedules.treasury(TGE);
        treasuryWallet =
            new KonstellationVestingWallet{value: 200_000_000 ether}(beneficiary, rs, rc, rd);
        for (uint256 k = 0; k < 5; k++) {
            (uint64 s, uint64 c, uint64 d, uint256 a) =
                VestingSchedules.communityTranche(TGE, 180_000_000 ether, k);
            grantWallets[k] = new KonstellationVestingWallet{value: a}(beneficiary, s, c, d);
            (s, c, d, a) = VestingSchedules.communityTranche(TGE, 100_000_000 ether, k);
            incentiveWallets[k] = new KonstellationVestingWallet{value: a}(beneficiary, s, c, d);
        }
    }

    /// @dev Circulating community supply at `t`: the 50 M pool seed (genesis `distribution`
    /// state, outside any contract) plus everything vested in the ten tranche wallets.
    function _communityAt(uint64 t) internal view returns (uint256 c) {
        c = 50_000_000 ether;
        for (uint256 k = 0; k < 5; k++) {
            c += grantWallets[k].vestedAmount(t) + incentiveWallets[k].vestedAmount(t);
        }
    }

    /// @dev The §7 year-end table (issuance excluded), driven through real wallets:
    /// team 22 / 22 / 88 / 154 / 220 / 220 M (22 M liquid + 198 M in wallets), treasury
    /// 50 / 100 / 150 / 200 / 250 / 250 M (incl. 50 M liquid), community 50 / 134 / 204 / 260 /
    /// 302 / 330 M (50 M pool seed + grants 180 M + incentives 100 M).
    function test_YearEndTableMatchesTokenomics() public {
        _deploySchedule();
        (uint256 teamLiquid,) = VestingSchedules.teamSplit(220_000_000 ether);
        assertEq(teamLiquid, 22_000_000 ether);

        uint256[6] memory teamTable = [
            uint256(22_000_000 ether),
            22_000_000 ether,
            88_000_000 ether,
            154_000_000 ether,
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
            uint256(50_000_000 ether),
            134_000_000 ether,
            204_000_000 ether,
            260_000_000 ether,
            302_000_000 ether,
            330_000_000 ether
        ];

        for (uint64 y = 0; y <= 5; y++) {
            uint64 t = TGE + y * YEAR;
            string memory year = string.concat(", year ", vm.toString(y));
            assertEq(
                teamLiquid + teamWallet.vestedAmount(t), teamTable[y], string.concat("team", year)
            );
            assertEq(
                50_000_000 ether + treasuryWallet.vestedAmount(t),
                treasuryTable[y],
                string.concat("treasury", year)
            );
            assertEq(_communityAt(t), communityTable[y], string.concat("community", year));
        }
    }
}
