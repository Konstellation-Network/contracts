// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {WKASH} from "../../src/WKASH.sol";
import {KonstellationVestingWallet} from "../../src/vesting/KonstellationVestingWallet.sol";
import {RevocableVestingWallet} from "../../src/vesting/RevocableVestingWallet.sol";

/// @notice The canonical creation-code hashes of every CREATE2-deployed contract, and the
/// checks that refuse to plan, predict, check or deploy from a build that does not match them.
///
/// A CREATE2 address is a function of the init code, and the init code is a function of the
/// compiler settings: `FOUNDRY_OPTIMIZER_RUNS=1`, `--via-ir`, a stray project-root `.env`
/// (forge auto-loads it) or a bumped OpenZeppelin all move every address while the scripts stay
/// perfectly self-consistent. Genesis funds addresses the canonical build would then never
/// reach. So every entry point calls these first: a drifted build cannot emit an address.
///
/// Moving a pin is a deliberate act -- README's tables, chain-config, docs and any published
/// allocation list move with it -- and `test/vesting/InitCodePins.t.sol` fails until the
/// constant here is updated.
library InitCodePins {
    bytes32 internal constant WKASH_INIT =
        0x0802161d14ce9ad706732c67cb2c77690bd95b8bf26e10353c746b3e3d768e64;
    bytes32 internal constant KONSTELLATION_WALLET_INIT =
        0xb3500e085d7b62e11effa65bee747ae5ea54eedeeef3e97a1ec88368485747e0;
    bytes32 internal constant REVOCABLE_WALLET_INIT =
        0x58a1dce05f84504570335ee131f82397a6d370932acfe6d8cfd465d4c1b6f59e;

    /// @dev Reverts unless this build's WKASH creation code matches the pin.
    function requireCanonicalWKASH() internal pure {
        requireMatch(keccak256(type(WKASH).creationCode), WKASH_INIT, "WKASH");
    }

    /// @dev Reverts unless this build's vesting wallet creation codes match the pins.
    function requireCanonicalVesting() internal pure {
        requireMatch(
            keccak256(type(KonstellationVestingWallet).creationCode),
            KONSTELLATION_WALLET_INIT,
            "KonstellationVestingWallet"
        );
        requireMatch(
            keccak256(type(RevocableVestingWallet).creationCode),
            REVOCABLE_WALLET_INIT,
            "RevocableVestingWallet"
        );
    }

    /// @dev The comparison, exposed for tests.
    function requireMatch(bytes32 actual, bytes32 pinned, string memory name) internal pure {
        if (actual != pinned) {
            revert(
                string.concat(
                    "drifted build: ",
                    name,
                    " creation code hash does not match script/lib/InitCodePins.sol ",
                    "(compiler settings, .env, --via-ir or a dependency changed)"
                )
            );
        }
    }
}
