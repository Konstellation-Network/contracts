// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/// @title Konstellation vesting wallet (non-revocable)
/// @notice Linear vesting of native KASH with an optional cliff, built on OpenZeppelin's
/// `VestingWallet` + `VestingWalletCliff` (D12, ENGINEERING.md §11: Solidity vesting contracts,
/// not `x/auth` vesting accounts). Used for the treasury and community schedules of
/// TOKENOMICS.md §7, which are NOT revocable; team grants use `RevocableVestingWallet`.
///
/// Schedule: nothing is releasable before `start() + cliff`; from the cliff onwards the amount
/// vested is `total × (t − start) / duration`, i.e. linear from `start` (so a non-zero cliff
/// unlocks the portion accrued since `start` in one step). To express "cliff, then linear from
/// zero" (the TOKENOMICS §7 team shape) set `start` to the cliff date and `cliff = 0` — see
/// `VestingSchedules`.
///
/// The beneficiary is the OZ `owner()`; `release()` is permissionless and always pays the
/// owner. `total` is whatever the wallet has ever held (`balance + released`), so the wallet can
/// be funded at genesis (allocation to its CREATE2 address before the code exists), at deploy
/// time (`payable` constructor), or later by a plain transfer. Every funding follows the same
/// schedule.
///
/// The beneficiary MUST be an EOA or a contract that accepts plain native transfers (e.g. a
/// Safe). Anything else -- a contract without a payable receive path, or a Cosmos module account,
/// which the chain's balance guard (ENGINEERING.md §4.1.1) refuses EVM value into -- makes
/// `release()` revert forever, and since only the owner can move ownership, the grant is then
/// unrecoverable. Ownership moves in two steps (`Ownable2Step`): the new beneficiary must
/// `acceptOwnership()`, so a grant cannot be sent to a typo'd address or to the wallet itself.
///
/// Deviations from OpenZeppelin, all deliberate:
/// - ERC-20 release is disabled. cosmos/evm's `werc20` precompile presents the native balance
///   as an ERC-20 (`balanceOf` == native balance), so OZ's `release(token)` path would let the
///   beneficiary withdraw the same KASH twice — once as native, once "as ERC-20" (the caveat in
///   OZ's own NatSpec). The vesting asset is native KASH only; ERC-20s sent here are not
///   recoverable.
/// - `renounceOwnership` is disabled: with no owner, `release()` would send vested KASH to
///   `address(0)`.
/// - `transferOwnership` is two-step and refuses the wallet's own address: a wallet owning
///   itself would count its own balance as "released" and corrupt the accounting.
contract KonstellationVestingWallet is VestingWalletCliff, Ownable2Step {
    /// @notice ERC-20 release is not supported on this wallet (see contract NatSpec).
    error ERC20ReleaseDisabled();
    /// @notice Ownership cannot be renounced: the owner is the payee of every release.
    error RenounceDisabled();
    /// @notice The proposed beneficiary is not allowed (the wallet itself).
    error InvalidBeneficiary(address proposed);

    /// @param beneficiary receives every release; becomes `owner()`. Must be non-zero.
    /// @param startTimestamp unix time the linear schedule starts from.
    /// @param cliffSeconds seconds after `startTimestamp` before anything is releasable
    ///        (`0` for none; must not exceed `durationSeconds`).
    /// @param durationSeconds length of the linear schedule; fully vested at
    ///        `startTimestamp + durationSeconds`. `0` makes the wallet a timelock.
    constructor(
        address beneficiary,
        uint64 startTimestamp,
        uint64 cliffSeconds,
        uint64 durationSeconds
    )
        payable
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
        VestingWalletCliff(cliffSeconds)
    {}

    /// @notice Disabled — always reverts. See contract NatSpec for why.
    function release(address) public pure override {
        revert ERC20ReleaseDisabled();
    }

    /// @notice Always `0`: no ERC-20 vests through this wallet.
    function vestedAmount(address, uint64) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Disabled — always reverts. Use `transferOwnership` to change the beneficiary.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Propose a new beneficiary; it takes effect when they call `acceptOwnership()`.
    /// `address(0)` cancels a pending proposal. The wallet itself is refused.
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        if (newOwner == address(this)) revert InvalidBeneficiary(newOwner);
        Ownable2Step.transferOwnership(newOwner);
    }

    /// @dev Both bases override this; Ownable2Step's clears the pending owner.
    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}
