// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RevocableVestingWallet} from "../../src/vesting/RevocableVestingWallet.sol";

/// @dev A treasury that re-enters `revoke()` when paid.
contract ReenteringTreasury {
    RevocableVestingWallet public target;
    bytes public lastRevert;

    function setTarget(RevocableVestingWallet t) external {
        target = t;
    }

    receive() external payable {
        try target.revoke() {}
        catch (bytes memory reason) {
            lastRevert = reason;
        }
    }
}

/// @dev A beneficiary that re-enters `release()` when paid.
contract ReenteringBeneficiary {
    RevocableVestingWallet public target;
    uint256 public depth;

    function setTarget(RevocableVestingWallet t) external {
        target = t;
    }

    receive() external payable {
        if (depth < 3) {
            depth++;
            target.release();
        }
    }
}

contract RejectingTreasury {
    receive() external payable {
        revert("treasury closed");
    }
}

/// @notice Revocable wallet: the team shape of TOKENOMICS.md §7 (12-month cliff, then linear
/// over 36 months) with the D12 revoke: unvested back to the treasury, vested to the member.
contract RevocableVestingWalletTest is Test {
    uint64 internal constant YEAR = 365 days;
    uint256 internal constant GRANT = 1_000_000 ether;

    address internal member = makeAddr("member");
    address internal foundation = makeAddr("foundation-multisig");
    address internal treasury = makeAddr("treasury");
    uint64 internal tge;
    uint64 internal start; // cliff date = tge + 1y
    RevocableVestingWallet internal wallet;

    function setUp() public {
        tge = uint64(block.timestamp) + 1 days;
        start = tge + YEAR;
        wallet = new RevocableVestingWallet{value: GRANT}(
            member, start, 0, 3 * YEAR, foundation, treasury
        );
    }

    function _revoke() internal {
        vm.prank(foundation);
        wallet.revoke();
    }

    // --- construction -------------------------------------------------------------------------

    function test_Constructor() public view {
        assertEq(wallet.owner(), member);
        assertEq(wallet.revoker(), foundation);
        assertEq(wallet.treasury(), treasury);
        assertEq(wallet.start(), start);
        assertEq(wallet.end(), start + 3 * YEAR);
        assertFalse(wallet.revoked());
        assertEq(wallet.revokedAt(), 0);
    }

    function test_RevertWhen_RevokerIsZero() public {
        vm.expectRevert(RevocableVestingWallet.ZeroAddress.selector);
        new RevocableVestingWallet(member, start, 0, YEAR, address(0), treasury);
    }

    function test_RevertWhen_TreasuryIsZero() public {
        vm.expectRevert(RevocableVestingWallet.ZeroAddress.selector);
        new RevocableVestingWallet(member, start, 0, YEAR, foundation, address(0));
    }

    // --- access -------------------------------------------------------------------------------

    function test_RevertWhen_NotRevoker() public {
        address[3] memory callers = [member, treasury, makeAddr("stranger")];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(RevocableVestingWallet.NotRevoker.selector, callers[i])
            );
            wallet.revoke();
        }
        assertFalse(wallet.revoked());
    }

    function test_RevertWhen_RevokedTwice() public {
        _revoke();
        vm.prank(foundation);
        vm.expectRevert(RevocableVestingWallet.AlreadyRevoked.selector);
        wallet.revoke();
    }

    // --- revoke at each point of the schedule -------------------------------------------------

    function test_RevokeBeforeCliff_EverythingToTreasury() public {
        vm.warp(start - 1);
        vm.expectEmit(address(wallet));
        emit RevocableVestingWallet.Revoked(0, GRANT);
        _revoke();

        assertTrue(wallet.revoked());
        assertEq(wallet.revokedAt(), start - 1);
        assertEq(treasury.balance, GRANT);
        assertEq(address(wallet).balance, 0);
        assertEq(wallet.releasable(), 0);

        // Time does not bring anything back.
        vm.warp(start + 3 * YEAR);
        assertEq(wallet.releasable(), 0);
        wallet.release();
        assertEq(member.balance, 0);
    }

    function test_RevokeMidSchedule_SplitsVestedAndUnvested() public {
        vm.warp(start + YEAR); // 1/3 vested
        uint256 vested = GRANT / 3;

        vm.expectEmit(address(wallet));
        emit RevocableVestingWallet.Revoked(vested, GRANT - vested);
        _revoke();

        assertEq(treasury.balance, GRANT - vested);
        assertEq(address(wallet).balance, vested);
        assertEq(wallet.releasable(), vested);

        // The frozen vested amount is releasable now and stays exactly that later.
        vm.warp(start + 2 * YEAR);
        assertEq(wallet.releasable(), vested);
        wallet.release();
        assertEq(member.balance, vested);
        assertEq(address(wallet).balance, 0);
        assertEq(member.balance + treasury.balance, GRANT);
    }

    function test_RevokeMidSchedule_AfterPartialRelease() public {
        vm.warp(start + YEAR);
        wallet.release(); // member takes 1/3
        assertEq(member.balance, GRANT / 3);

        vm.warp(start + 2 * YEAR); // 2/3 vested, 1/3 already out
        uint256 vested = GRANT * 2 / 3;
        vm.expectEmit(address(wallet));
        emit RevocableVestingWallet.Revoked(vested, GRANT - vested);
        _revoke();

        assertEq(treasury.balance, GRANT - vested);
        assertEq(wallet.releasable(), vested - GRANT / 3);
        wallet.release();
        assertEq(member.balance, vested);
        assertEq(member.balance + treasury.balance, GRANT);
    }

    function test_RevokeAfterFullVest_NothingToTreasury() public {
        vm.warp(start + 3 * YEAR + 1);
        vm.expectEmit(address(wallet));
        emit RevocableVestingWallet.Revoked(GRANT, 0);
        _revoke();

        assertTrue(wallet.revoked());
        assertEq(treasury.balance, 0);
        assertEq(wallet.releasable(), GRANT);
        wallet.release();
        assertEq(member.balance, GRANT);
    }

    function test_RevokeAfterEverythingReleased() public {
        vm.warp(start + 3 * YEAR);
        wallet.release();
        _revoke();
        assertEq(treasury.balance, 0);
        assertEq(member.balance, GRANT);
        assertEq(wallet.releasable(), 0);
    }

    function test_FundsSentAfterRevokeBelongToBeneficiary() public {
        vm.warp(start - 1);
        _revoke();
        (bool ok,) = address(wallet).call{value: 7 ether}("");
        assertTrue(ok);
        assertEq(wallet.releasable(), 7 ether);
        wallet.release();
        assertEq(member.balance, 7 ether);
    }

    function test_RevokeSurvivesOwnershipTransfer() public {
        address buyer = makeAddr("buyer");
        vm.prank(member);
        wallet.transferOwnership(buyer);
        vm.warp(start + YEAR);
        _revoke();
        wallet.release();
        assertEq(buyer.balance, GRANT / 3);
        assertEq(treasury.balance, GRANT - GRANT / 3);
    }

    function test_RevokeWithNoFunds() public {
        RevocableVestingWallet empty =
            new RevocableVestingWallet(member, start, 0, YEAR, foundation, treasury);
        vm.prank(foundation);
        empty.revoke();
        assertTrue(empty.revoked());
        assertEq(treasury.balance, 0);
    }

    // --- failure and re-entrancy paths --------------------------------------------------------

    function test_RevertWhen_TreasuryRejectsFunds() public {
        RejectingTreasury rejecting = new RejectingTreasury();
        RevocableVestingWallet w = new RevocableVestingWallet{value: GRANT}(
            member, start, 0, YEAR, foundation, address(rejecting)
        );
        vm.warp(start - 1);
        vm.prank(foundation);
        vm.expectRevert(bytes("treasury closed"));
        w.revoke();
        assertFalse(w.revoked());
        assertEq(address(w).balance, GRANT);
    }

    function test_ReenteringTreasuryCannotRevokeTwice() public {
        ReenteringTreasury evil = new ReenteringTreasury();
        RevocableVestingWallet w = new RevocableVestingWallet{value: GRANT}(
            member, start, 0, YEAR, address(evil), address(evil)
        );
        evil.setTarget(w);
        vm.warp(start + YEAR / 2);
        vm.prank(address(evil));
        w.revoke();
        assertEq(
            evil.lastRevert(),
            abi.encodeWithSelector(RevocableVestingWallet.AlreadyRevoked.selector)
        );
        assertEq(address(evil).balance, GRANT / 2);
        assertEq(address(w).balance, GRANT / 2);
        assertEq(w.releasable(), GRANT / 2);
    }

    function test_ReenteringBeneficiaryGetsNothingExtra() public {
        ReenteringBeneficiary evil = new ReenteringBeneficiary();
        RevocableVestingWallet w = new RevocableVestingWallet{value: GRANT}(
            address(evil), start, 0, YEAR, foundation, treasury
        );
        evil.setTarget(w);
        vm.warp(start + YEAR / 2);
        w.release();
        assertEq(evil.depth(), 3, "re-entered");
        assertEq(address(evil).balance, GRANT / 2);
        assertEq(w.released(), GRANT / 2);
    }

    // --- fuzz ---------------------------------------------------------------------------------

    /// @dev Whenever the revoke happens, the member ends with exactly what had vested at that
    /// moment and the treasury with the rest; nothing is created or lost.
    function testFuzz_RevokeConservesFunds(uint64 releaseAt, uint64 revokeAt, uint64 laterAt)
        public
    {
        releaseAt = uint64(bound(releaseAt, tge, start + 4 * YEAR));
        revokeAt = uint64(bound(revokeAt, releaseAt, start + 4 * YEAR));
        laterAt = uint64(bound(laterAt, revokeAt, start + 40 * YEAR));

        vm.warp(releaseAt);
        wallet.release();
        uint256 releasedEarly = member.balance;

        vm.warp(revokeAt);
        uint256 vestedAtRevoke = wallet.vestedAmount(revokeAt);
        assertGe(vestedAtRevoke, releasedEarly);
        _revoke();
        assertEq(treasury.balance, GRANT - vestedAtRevoke);

        vm.warp(laterAt);
        assertEq(wallet.vestedAmount(laterAt), vestedAtRevoke);
        wallet.release();
        assertEq(member.balance, vestedAtRevoke);
        assertEq(member.balance + treasury.balance, GRANT);
        assertEq(address(wallet).balance, 0);
    }

    /// @dev Arbitrary schedules and amounts: the revoke split is always exact.
    function testFuzz_RevokeSplitMatchesSchedule(
        uint64 startAt,
        uint64 cliff,
        uint64 duration,
        uint128 amount,
        uint64 revokeAt
    ) public {
        startAt = uint64(bound(startAt, 1, type(uint64).max / 4));
        duration = uint64(bound(duration, 0, type(uint64).max / 4));
        cliff = uint64(bound(cliff, 0, duration));
        amount = uint128(bound(amount, 0, 1_000_000_000 ether));
        revokeAt = uint64(bound(revokeAt, 1, type(uint64).max / 2));

        address t = makeAddr("fuzz-treasury");
        RevocableVestingWallet w = new RevocableVestingWallet{value: amount}(
            member, startAt, cliff, duration, foundation, t
        );

        vm.warp(revokeAt);
        uint256 expectedVested;
        if (revokeAt < startAt + cliff) expectedVested = 0;
        else if (revokeAt >= startAt + duration) expectedVested = amount;
        else expectedVested = uint256(amount) * (revokeAt - startAt) / duration;

        vm.prank(foundation);
        w.revoke();
        assertEq(t.balance, uint256(amount) - expectedVested);
        assertEq(w.releasable(), expectedVested);
        w.release();
        assertEq(member.balance, expectedVested);
    }
}
