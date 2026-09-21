// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {KonstellationVestingWallet} from "./KonstellationVestingWallet.sol";

/// @title Konstellation vesting wallet, revocable
/// @notice `KonstellationVestingWallet` plus a one-shot `revoke()` for team grants (D12,
/// decided 2026-09-15: the foundation multisig may revoke a departing member's grant; unvested
/// KASH returns to the treasury, vested KASH stays with the beneficiary).
///
/// `revoke()` freezes the schedule at the call's timestamp: everything vested by then remains
/// releasable to the beneficiary exactly as before (including anything already released), and
/// the unvested remainder is sent to `treasury` immediately. After a revoke, everything the
/// wallet holds — including any KASH sent to it later — belongs to the beneficiary, so no funds
/// can get stuck.
///
/// `revoker` and `treasury` are immutable: both are expected to be multisigs whose address is
/// stable across signer rotation. `treasury` must accept plain native transfers.
contract RevocableVestingWallet is KonstellationVestingWallet {
    /// @notice The only address allowed to call `revoke()` (the foundation multisig).
    address public immutable revoker;
    /// @notice Where the unvested remainder goes on revoke.
    address public immutable treasury;

    uint64 private _revokedAt;

    /// @notice Emitted once, on revoke.
    /// @param vested amount that stays with the beneficiary (released + still releasable).
    /// @param returned amount sent to `treasury`.
    event Revoked(uint256 vested, uint256 returned);

    /// @notice `revoke()` was called by an address other than `revoker`.
    error NotRevoker(address caller);
    /// @notice `revoke()` was already called.
    error AlreadyRevoked();
    /// @notice A required address was `address(0)`.
    error ZeroAddress();

    /// @param beneficiary receives every release; becomes `owner()`. Must be non-zero.
    /// @param startTimestamp unix time the linear schedule starts from.
    /// @param cliffSeconds seconds after `startTimestamp` before anything is releasable.
    /// @param durationSeconds length of the linear schedule.
    /// @param revoker_ the only address that may revoke. Must be non-zero.
    /// @param treasury_ receives the unvested remainder on revoke. Must be non-zero.
    constructor(
        address beneficiary,
        uint64 startTimestamp,
        uint64 cliffSeconds,
        uint64 durationSeconds,
        address revoker_,
        address treasury_
    )
        payable
        KonstellationVestingWallet(beneficiary, startTimestamp, cliffSeconds, durationSeconds)
    {
        if (revoker_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        revoker = revoker_;
        treasury = treasury_;
    }

    /// @notice Timestamp of the revoke, or `0` if the grant has not been revoked.
    function revokedAt() public view returns (uint64) {
        return _revokedAt;
    }

    /// @notice Whether `revoke()` has been called.
    function revoked() public view returns (bool) {
        return _revokedAt != 0;
    }

    /// @notice Stop vesting now. Only `revoker`; only once. The amount vested at this moment
    /// stays releasable to the beneficiary; the rest is transferred to `treasury`.
    /// @dev Effects before interaction: the revoke is recorded before the treasury transfer, and
    /// `vestedAmount` is computed against the pre-revoke schedule in the same call.
    function revoke() external {
        if (msg.sender != revoker) revert NotRevoker(msg.sender);
        if (_revokedAt != 0) revert AlreadyRevoked();

        uint256 total = address(this).balance + released();
        uint256 vested = vestedAmount(uint64(block.timestamp));
        uint256 unvested = total - vested;

        _revokedAt = uint64(block.timestamp);
        emit Revoked(vested, unvested);

        if (unvested > 0) Address.sendValue(payable(treasury), unvested);
    }

    /// @notice Vested native KASH at `timestamp`. Once revoked, the schedule is frozen: every
    /// unit the wallet has ever held after the revoke transfer counts as vested, whatever
    /// `timestamp` says.
    function vestedAmount(uint64 timestamp) public view override returns (uint256) {
        if (_revokedAt != 0) return address(this).balance + released();
        return super.vestedAmount(timestamp);
    }
}
