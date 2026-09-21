// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title TOKENOMICS.md §7 vesting schedules, as wallet parameters
/// @notice Pure functions mapping the genesis-allocation buckets of TOKENOMICS.md §7 (as decided
/// 2026-09-20) onto `KonstellationVestingWallet` constructor parameters `(start, cliff, duration)`
/// and amounts, given the genesis (TGE) timestamp. Not deployed; used by
/// `script/DeployVesting.s.sol` and its tests so that the numbers live in exactly one place. A
/// vesting year is 365 days; a "month" is 1/12 of that.
///
/// | Bucket    | §7 wording                                                    | Here                                    |
/// |-----------|---------------------------------------------------------------|-----------------------------------------|
/// | Team      | 10 % liquid at genesis; 90 %: 12-month cliff, linear 36 months | liquid = plain genesis balance to the member; locked 90 %: start = TGE + 1y, cliff 0, duration 3y |
/// | Treasury  | 20 % liquid at genesis, remainder linear over 48 months        | start = TGE, cliff 0, duration 4y       |
/// | Community | grants 180 M + incentives 100 M, 30/25/20/15/10 % per year     | per sub-bucket, 5 wallets, year k linear over year k |
///
/// The team's locked part is "nothing at the cliff, then linear from zero" — §7's year table
/// reads 22 / 22 / 88 / 154 / 220 / 220 M (genesis, then ends of years 1–5) — so the wallet's
/// `start` is the cliff date and its own `cliff` parameter is 0. (`start = TGE, cliff = 1y,
/// duration = 4y` would instead unlock a quarter at the cliff, which is not what §7 says.)
///
/// The community schedule is piecewise linear with a decreasing slope, which one linear wallet
/// cannot express; five non-revocable wallets, one per year, express it exactly. What never
/// enters a wallet: the team's liquid 10 %, the treasury's liquid 50 M, and the 50 M community
/// pool seed (a Cosmos module account, written straight into genesis `distribution` state).
library VestingSchedules {
    /// @notice One vesting year.
    uint64 internal constant YEAR = 365 days;

    /// @notice Team: cliff length before anything vests.
    uint64 internal constant TEAM_CLIFF = YEAR;
    /// @notice Team: linear period after the cliff.
    uint64 internal constant TEAM_LINEAR = 3 * YEAR;
    /// @notice Team: share of each grant paid out liquid at genesis, in basis points.
    uint256 internal constant TEAM_LIQUID_BPS = 1000;
    /// @notice Treasury: linear period from genesis.
    uint64 internal constant TREASURY_LINEAR = 4 * YEAR;
    /// @notice Community: number of yearly tranches.
    uint256 internal constant COMMUNITY_TRANCHES = 5;
    uint256 internal constant BPS = 10_000;

    /// @notice Tranche k's share of the locked community amount, in basis points.
    error InvalidTranche(uint256 index);

    /// @notice Team grant parameters for the locked 90 % (revocable wallet).
    /// @param tge genesis timestamp.
    /// @return start schedule start (the cliff date).
    /// @return cliff always 0 — see library NatSpec.
    /// @return duration linear period.
    function team(uint64 tge) internal pure returns (uint64 start, uint64 cliff, uint64 duration) {
        return (tge + TEAM_CLIFF, 0, TEAM_LINEAR);
    }

    /// @notice Splits a whole team grant into its liquid genesis balance and the amount that
    /// goes into the member's vesting wallet. `liquid + locked == grant` exactly.
    /// @param grant the member's whole allocation, in esp (wei).
    function teamSplit(uint256 grant) internal pure returns (uint256 liquid, uint256 locked) {
        liquid = grant * TEAM_LIQUID_BPS / BPS;
        locked = grant - liquid;
    }

    /// @notice Treasury locked-tranche parameters (non-revocable wallet).
    /// @param tge genesis timestamp.
    function treasury(uint64 tge)
        internal
        pure
        returns (uint64 start, uint64 cliff, uint64 duration)
    {
        return (tge, 0, TREASURY_LINEAR);
    }

    /// @notice Community tranche `index`'s share of the locked amount, in basis points.
    /// @dev 30 / 25 / 20 / 15 / 10 % — front-loaded, TOKENOMICS.md §7.
    function communityTrancheBps(uint256 index) internal pure returns (uint256) {
        if (index >= COMMUNITY_TRANCHES) revert InvalidTranche(index);
        return 3000 - 500 * index;
    }

    /// @notice Community tranche `index` (0-based year) parameters (non-revocable wallet).
    /// @param tge genesis timestamp.
    /// @param lockedAmount the whole locked community amount, in esp (wei).
    /// @param index 0..4.
    /// @return start start of year `index`.
    /// @return cliff always 0.
    /// @return duration one year.
    /// @return amount this tranche's funding; the last tranche absorbs rounding so that the
    ///         five amounts sum to `lockedAmount` exactly.
    function communityTranche(uint64 tge, uint256 lockedAmount, uint256 index)
        internal
        pure
        returns (uint64 start, uint64 cliff, uint64 duration, uint256 amount)
    {
        if (index >= COMMUNITY_TRANCHES) revert InvalidTranche(index);
        // index < COMMUNITY_TRANCHES (5) was checked above, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        start = tge + uint64(index) * YEAR;
        cliff = 0;
        duration = YEAR;
        if (index == COMMUNITY_TRANCHES - 1) {
            uint256 earlier;
            for (uint256 i = 0; i < index; i++) {
                earlier += lockedAmount * communityTrancheBps(i) / BPS;
            }
            amount = lockedAmount - earlier;
        } else {
            amount = lockedAmount * communityTrancheBps(index) / BPS;
        }
    }
}
