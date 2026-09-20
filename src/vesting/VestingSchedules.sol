// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TOKENOMICS.md §7 vesting schedules, as wallet parameters
/// @notice Pure functions mapping the genesis-allocation buckets of TOKENOMICS.md §7 onto
/// `KonstellationVestingWallet` constructor parameters `(start, cliff, duration)`, given the
/// genesis (TGE) timestamp. Not deployed; used by `script/DeployVesting.s.sol` and its tests so
/// that the numbers live in exactly one place. A "month" is 1/12 of a 365-day year.
///
/// | Bucket    | §7 wording                                          | Here                                     |
/// |-----------|-----------------------------------------------------|------------------------------------------|
/// | Team      | 12-month cliff, then linear over 36 months (4 years) | start = TGE + 1y, cliff 0, duration 3y  |
/// | Treasury  | 20 % liquid at genesis, remainder linear over 48 mo  | start = TGE, cliff 0, duration 4y       |
/// | Community | 300 M locked, released 30/25/20/15/10 % per year     | 5 wallets, year k linear over year k    |
///
/// The team shape is "nothing at the cliff, then linear from zero" — §7's year table reads
/// 0 / 73 M / 147 M / 220 M at the ends of years 1–4 — so the wallet's `start` is the cliff date
/// and its own `cliff` parameter is 0. (`start = TGE, cliff = 1y, duration = 4y` would instead
/// unlock 25 % at the cliff, which is not what §7 says.)
///
/// The community schedule is piecewise linear with a decreasing slope, which one linear wallet
/// cannot express; five non-revocable wallets, one per year, express it exactly. The liquid
/// parts of §7 (30 M community, 50 M treasury) never enter a wallet.
library VestingSchedules {
    /// @notice One vesting year.
    uint64 internal constant YEAR = 365 days;

    /// @notice Team: cliff length before anything vests.
    uint64 internal constant TEAM_CLIFF = YEAR;
    /// @notice Team: linear period after the cliff.
    uint64 internal constant TEAM_LINEAR = 3 * YEAR;
    /// @notice Treasury: linear period from genesis.
    uint64 internal constant TREASURY_LINEAR = 4 * YEAR;
    /// @notice Community: number of yearly tranches.
    uint256 internal constant COMMUNITY_TRANCHES = 5;
    uint256 internal constant BPS = 10_000;

    /// @notice Tranche k's share of the locked community amount, in basis points.
    error InvalidTranche(uint256 index);

    /// @notice Team grant parameters (revocable wallet).
    /// @param tge genesis timestamp.
    /// @return start schedule start (the cliff date).
    /// @return cliff always 0 — see library NatSpec.
    /// @return duration linear period.
    function team(uint64 tge) internal pure returns (uint64 start, uint64 cliff, uint64 duration) {
        return (tge + TEAM_CLIFF, 0, TEAM_LINEAR);
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
