// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {KonstellationVestingWallet} from "../../src/vesting/KonstellationVestingWallet.sol";
import {WKASH} from "../../src/WKASH.sol";

/// @dev A payee that refuses native transfers, to exercise the failure path of `release()`.
contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @notice Non-revocable wallet: the treasury / community shape of TOKENOMICS.md §7.
contract KonstellationVestingWalletTest is Test {
    uint64 internal constant YEAR = 365 days;
    uint256 internal constant TOTAL = 200_000_000 ether; // treasury locked tranche, in esp

    address internal beneficiary = makeAddr("beneficiary");
    uint64 internal tge;
    KonstellationVestingWallet internal wallet;

    function setUp() public {
        tge = uint64(block.timestamp) + 1 days;
        wallet = new KonstellationVestingWallet{value: TOTAL}(beneficiary, tge, 0, 4 * YEAR);
    }

    function _deploy(uint64 start, uint64 cliff, uint64 duration, uint256 amount)
        internal
        returns (KonstellationVestingWallet w)
    {
        w = new KonstellationVestingWallet{value: amount}(beneficiary, start, cliff, duration);
    }

    // --- construction -------------------------------------------------------------------------

    function test_ConstructorSetsSchedule() public view {
        assertEq(wallet.owner(), beneficiary);
        assertEq(wallet.start(), tge);
        assertEq(wallet.cliff(), tge);
        assertEq(wallet.duration(), 4 * YEAR);
        assertEq(wallet.end(), tge + 4 * YEAR);
        assertEq(address(wallet).balance, TOTAL);
        assertEq(wallet.released(), 0);
    }

    function test_RevertWhen_BeneficiaryIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new KonstellationVestingWallet(address(0), tge, 0, YEAR);
    }

    function test_RevertWhen_CliffExceedsDuration() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VestingWalletCliff.InvalidCliffDuration.selector, uint64(YEAR + 1), uint64(YEAR)
            )
        );
        new KonstellationVestingWallet(beneficiary, tge, YEAR + 1, YEAR);
    }

    function test_CanBeFundedAfterDeployByPlainTransfer() public {
        KonstellationVestingWallet w = _deploy(tge, 0, YEAR, 0);
        (bool ok,) = address(w).call{value: 10 ether}("");
        assertTrue(ok);
        vm.warp(tge + YEAR / 2);
        assertEq(w.releasable(), 5 ether);
    }

    // --- schedule -----------------------------------------------------------------------------

    function test_NothingBeforeStart() public {
        vm.warp(tge - 1);
        assertEq(wallet.vestedAmount(uint64(block.timestamp)), 0);
        assertEq(wallet.releasable(), 0);
        wallet.release();
        assertEq(beneficiary.balance, 0);
        assertEq(wallet.released(), 0);
    }

    function test_LinearRelease() public {
        vm.warp(tge + YEAR);
        assertEq(wallet.releasable(), TOTAL / 4);
        wallet.release();
        assertEq(beneficiary.balance, TOTAL / 4);
        assertEq(wallet.released(), TOTAL / 4);

        vm.warp(tge + 3 * YEAR);
        assertEq(wallet.releasable(), TOTAL / 2);
        wallet.release();
        assertEq(beneficiary.balance, 3 * TOTAL / 4);
    }

    function test_ReleaseAfterFullDuration() public {
        vm.warp(tge + 4 * YEAR);
        assertEq(wallet.releasable(), TOTAL);
        wallet.release();
        assertEq(beneficiary.balance, TOTAL);
        assertEq(address(wallet).balance, 0);

        vm.warp(tge + 40 * YEAR);
        assertEq(wallet.releasable(), 0);
        wallet.release(); // no-op, does not revert
        assertEq(beneficiary.balance, TOTAL);
    }

    function test_ReleaseIsPermissionlessAndPaysTheOwner() public {
        vm.warp(tge + 2 * YEAR);
        vm.prank(makeAddr("anyone"));
        wallet.release();
        assertEq(beneficiary.balance, TOTAL / 2);
    }

    function test_CliffGatesThenUnlocksAccruedPortion() public {
        // OZ cliff semantics: nothing before start + cliff, then the amount accrued since start.
        KonstellationVestingWallet w = _deploy(tge, YEAR, 4 * YEAR, 100 ether);
        assertEq(w.cliff(), tge + YEAR);
        vm.warp(tge + YEAR - 1);
        assertEq(w.releasable(), 0);
        vm.warp(tge + YEAR);
        assertEq(w.releasable(), 25 ether);
    }

    function test_TeamShapeViaDelayedStart() public {
        // TOKENOMICS §7 team: 12-month cliff then linear over 36 months, nothing at the cliff.
        KonstellationVestingWallet w = _deploy(tge + YEAR, 0, 3 * YEAR, 220_000_000 ether);
        vm.warp(tge + YEAR);
        assertEq(w.releasable(), 0, "end of year 1");
        vm.warp(tge + 2 * YEAR);
        assertEq(w.releasable(), uint256(220_000_000 ether) / 3, "end of year 2");
        vm.warp(tge + 3 * YEAR);
        assertEq(w.releasable(), uint256(220_000_000 ether) * 2 / 3, "end of year 3");
        vm.warp(tge + 4 * YEAR);
        assertEq(w.releasable(), uint256(220_000_000 ether), "end of year 4");
    }

    function test_ZeroDurationIsATimelock() public {
        KonstellationVestingWallet w = _deploy(tge, 0, 0, 1 ether);
        vm.warp(tge - 1);
        assertEq(w.releasable(), 0);
        vm.warp(tge);
        assertEq(w.releasable(), 1 ether);
    }

    // --- ownership ----------------------------------------------------------------------------

    function test_TransferOwnershipMovesTheBeneficiary() public {
        address newBeneficiary = makeAddr("new");
        vm.prank(beneficiary);
        wallet.transferOwnership(newBeneficiary);
        vm.warp(tge + YEAR);
        wallet.release();
        assertEq(newBeneficiary.balance, TOTAL / 4);
        assertEq(beneficiary.balance, 0);
    }

    function test_RevertWhen_RenounceOwnership() public {
        vm.prank(beneficiary);
        vm.expectRevert(KonstellationVestingWallet.RenounceDisabled.selector);
        wallet.renounceOwnership();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")
            )
        );
        wallet.renounceOwnership();
    }

    function test_RevertWhen_BeneficiaryRejectsFunds() public {
        RejectingReceiver r = new RejectingReceiver();
        KonstellationVestingWallet w =
            new KonstellationVestingWallet{value: 1 ether}(address(r), tge, 0, YEAR);
        vm.warp(tge + YEAR);
        vm.expectRevert();
        w.release();
        // Nothing was accounted as released.
        assertEq(w.released(), 0);
        assertEq(address(w).balance, 1 ether);
    }

    // --- ERC-20 path is off -------------------------------------------------------------------

    function test_ERC20ReleaseIsDisabled() public {
        WKASH token = new WKASH();
        token.deposit{value: 5 ether}();
        assertTrue(token.transfer(address(wallet), 5 ether));
        vm.warp(tge + 4 * YEAR);

        assertEq(wallet.vestedAmount(address(token), uint64(block.timestamp)), 0);
        assertEq(wallet.releasable(address(token)), 0);
        assertEq(wallet.released(address(token)), 0);
        vm.expectRevert(KonstellationVestingWallet.ERC20ReleaseDisabled.selector);
        wallet.release(address(token));
        assertEq(token.balanceOf(address(wallet)), 5 ether);
    }

    // --- fuzz ---------------------------------------------------------------------------------

    /// @dev Vested amount is monotone, bounded by the allocation, 0 before the cliff, exact at the
    /// end, and the sum of piecewise releases equals a single release at the same time.
    function testFuzz_Schedule(
        uint64 start,
        uint64 cliff,
        uint64 duration,
        uint128 amount,
        uint64 t
    ) public {
        start = uint64(bound(start, 1, type(uint64).max / 4));
        duration = uint64(bound(duration, 0, type(uint64).max / 4));
        cliff = uint64(bound(cliff, 0, duration));
        amount = uint128(bound(amount, 1, 1_000_000_000 ether));
        t = uint64(bound(t, 0, type(uint64).max / 2));

        KonstellationVestingWallet w = _deploy(start, cliff, duration, amount);

        uint256 v = w.vestedAmount(t);
        assertLe(v, amount);
        if (t < start + cliff) assertEq(v, 0);
        if (t >= start + duration) assertEq(v, amount);
        if (t + 1 <= type(uint64).max) assertLe(v, w.vestedAmount(t + 1));
        if (t >= start + cliff && duration > 0 && t < start + duration) {
            assertEq(v, uint256(amount) * (t - start) / duration);
        }
    }

    function testFuzz_PiecewiseReleasesSumToSchedule(uint64 t1, uint64 t2) public {
        t1 = uint64(bound(t1, tge, tge + 5 * YEAR));
        t2 = uint64(bound(t2, t1, tge + 5 * YEAR));
        vm.warp(t1);
        wallet.release();
        vm.warp(t2);
        wallet.release();
        assertEq(beneficiary.balance, wallet.vestedAmount(t2));
        assertEq(beneficiary.balance + address(wallet).balance, TOTAL);
    }
}
