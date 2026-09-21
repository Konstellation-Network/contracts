// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {RevocableVestingWallet} from "../../src/vesting/RevocableVestingWallet.sol";

/// @dev Random walk over a revocable wallet: time passes, anyone donates, anyone releases, the
/// revoker revokes once. From the adversarial review of PR #2.
contract RevocableWalletHandler is Test {
    RevocableVestingWallet public wallet;
    address public beneficiary = makeAddr("beneficiary");
    address public treasury = makeAddr("treasury");
    uint256 public funded;
    uint256 public vestedAtRevoke;
    uint256 public donatedAfterRevoke;
    bool public revoked;

    uint64 internal constant START = 1_800_000_000;
    uint64 internal constant DURATION = 3 * 365 days;

    constructor() {
        wallet = new RevocableVestingWallet(beneficiary, START, 0, DURATION, treasury, treasury);
        vm.warp(START - 365 days);
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + uint256(dt) % 30 days);
    }

    function donate(uint96 amount) external {
        vm.deal(address(this), amount);
        (bool ok,) = address(wallet).call{value: amount}("");
        require(ok);
        funded += amount;
        if (revoked) donatedAfterRevoke += amount;
    }

    function release() external {
        wallet.release();
    }

    function revoke() external {
        if (revoked) return;
        vestedAtRevoke = wallet.vestedAmount(uint64(block.timestamp));
        vm.prank(treasury);
        wallet.revoke();
        revoked = true;
    }
}

contract RevocableVestingWalletInvariantTest is Test {
    RevocableWalletHandler internal h;

    function setUp() public {
        h = new RevocableWalletHandler();
        targetContract(address(h));
    }

    /// @dev Nothing is created or lost: every wei ever funded is with the beneficiary, the
    /// treasury or still in the wallet.
    function invariant_Conservation() public view {
        assertEq(
            h.beneficiary().balance + h.treasury().balance + address(h.wallet()).balance, h.funded()
        );
    }

    /// @dev Releasable never exceeds what the wallet holds; released never exceeds vested.
    function invariant_ReleasableWithinBalance() public view {
        assertLe(h.wallet().releasable(), address(h.wallet()).balance);
        assertLe(h.wallet().released(), h.wallet().vestedAmount(uint64(block.timestamp)));
    }

    /// @dev The treasury gets exactly the unvested part at revoke time and nothing else, ever.
    function invariant_TreasuryGetsExactlyTheUnvestedPart() public view {
        if (!h.revoked()) {
            assertEq(h.treasury().balance, 0);
            return;
        }
        uint256 fundedAtRevoke = h.funded() - h.donatedAfterRevoke();
        assertEq(h.treasury().balance, fundedAtRevoke - h.vestedAtRevoke());
    }

    /// @dev After a revoke everything the wallet holds is the beneficiary's.
    function invariant_AfterRevokeAllToBeneficiary() public view {
        if (h.revoked()) assertEq(h.wallet().releasable(), address(h.wallet()).balance);
    }
}
