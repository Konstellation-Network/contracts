// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {KonstellationVestingWallet} from "../src/vesting/KonstellationVestingWallet.sol";
import {RevocableVestingWallet} from "../src/vesting/RevocableVestingWallet.sol";
import {VestingSchedules} from "../src/vesting/VestingSchedules.sol";
import {Create2DeployerLib, ICreate2Deployer} from "./lib/Create2Deployer.sol";

/// @notice Deploys the TOKENOMICS.md §7 vesting schedule from a JSON config (see
/// script/config/vesting.example.json) through the preinstalled Create2Deployer, so every
/// wallet's address is known before genesis and can be funded in `genesis.json` directly: the
/// allocation sits at the address from block 0 with no key able to move it, and the permissionless
/// CREATE2 deploy later puts the (deterministic) vesting code on top. Anyone can run the deploy;
/// the result is identical whoever does.
///
/// Config → wallets (`VestingSchedules` holds the numbers):
/// - `team`      → one `RevocableVestingWallet` (revoker / treasury from the config header)
/// - `treasury`  → one `KonstellationVestingWallet`
/// - `community` → five `KonstellationVestingWallet`s, `<label>-y1` … `-y5`
///
/// Usage (VESTING_CONFIG defaults to script/config/vesting.example.json):
///   forge script script/DeployVesting.s.sol --sig "predict()"                   # plan + addresses
///   forge script script/DeployVesting.s.sol --rpc-url ... --broadcast           # deploy
///   forge script script/DeployVesting.s.sol --sig "fund()" --rpc-url ... --broadcast
///     # testnets only: top each wallet up to its amount from the broadcaster
contract DeployVestingScript is Script {
    string internal constant DEFAULT_CONFIG = "script/config/vesting.example.json";
    string internal constant SALT_PREFIX = "konstellation-network/contracts:vesting:v1:";

    /// @dev One `grants[]` entry. Field order is alphabetical: forge's JSON decoder requires it.
    struct GrantConfig {
        uint256 amountKash;
        address beneficiary;
        string kind;
        string label;
    }

    /// @dev One wallet to deploy.
    struct Wallet {
        string label;
        bytes32 salt;
        address addr;
        bytes initCode;
        uint256 amount; // esp (wei)
        bool revocable;
    }

    /// @notice The config file in use.
    function configPath() public view returns (string memory) {
        return vm.envOr("VESTING_CONFIG", string(DEFAULT_CONFIG));
    }

    /// @notice CREATE2 salt for a wallet label.
    function salt(string memory label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_PREFIX, label));
    }

    /// @dev The config header plus the deployer, passed around to keep stack depth down.
    struct Header {
        uint64 tge;
        address revoker;
        address treasury;
        address deployer;
    }

    /// @notice Expands the config into the concrete list of wallets, with predicted addresses.
    function plan(string memory path) public view returns (Wallet[] memory wallets) {
        string memory json = vm.readFile(path);
        Header memory h = Header({
            tge: uint64(vm.parseJsonUint(json, ".tge")),
            revoker: vm.parseJsonAddress(json, ".revoker"),
            treasury: vm.parseJsonAddress(json, ".treasury"),
            deployer: Create2DeployerLib.addr(vm)
        });
        GrantConfig[] memory grants = abi.decode(vm.parseJson(json, ".grants"), (GrantConfig[]));

        uint256 n;
        for (uint256 i = 0; i < grants.length; i++) {
            n += _isKind(grants[i], "community") ? VestingSchedules.COMMUNITY_TRANCHES : 1;
        }
        wallets = new Wallet[](n);

        uint256 w;
        for (uint256 i = 0; i < grants.length; i++) {
            GrantConfig memory g = grants[i];
            require(g.beneficiary != address(0), string.concat(g.label, ": zero beneficiary"));
            require(g.amountKash > 0, string.concat(g.label, ": zero amount"));

            if (_isKind(g, "team")) {
                wallets[w++] = _team(h, g);
            } else if (_isKind(g, "treasury")) {
                wallets[w++] = _treasury(h, g);
            } else if (_isKind(g, "community")) {
                for (uint256 k = 0; k < VestingSchedules.COMMUNITY_TRANCHES; k++) {
                    wallets[w++] = _communityTranche(h, g, k);
                }
            } else {
                revert(string.concat(g.label, ": unknown kind '", g.kind, "'"));
            }
        }

        for (uint256 i = 0; i < wallets.length; i++) {
            for (uint256 j = i + 1; j < wallets.length; j++) {
                require(
                    wallets[i].salt != wallets[j].salt,
                    string.concat("duplicate label: ", wallets[i].label)
                );
            }
        }
    }

    function _team(Header memory h, GrantConfig memory g) internal pure returns (Wallet memory) {
        (uint64 start, uint64 cliff, uint64 duration) = VestingSchedules.team(h.tge);
        bytes memory args = abi.encode(g.beneficiary, start, cliff, duration, h.revoker, h.treasury);
        bytes memory initCode = abi.encodePacked(type(RevocableVestingWallet).creationCode, args);
        return _wallet(h.deployer, g.label, initCode, g.amountKash * 1 ether, true);
    }

    function _treasury(Header memory h, GrantConfig memory g)
        internal
        pure
        returns (Wallet memory)
    {
        (uint64 start, uint64 cliff, uint64 duration) = VestingSchedules.treasury(h.tge);
        bytes memory args = abi.encode(g.beneficiary, start, cliff, duration);
        bytes memory initCode =
            abi.encodePacked(type(KonstellationVestingWallet).creationCode, args);
        return _wallet(h.deployer, g.label, initCode, g.amountKash * 1 ether, false);
    }

    function _communityTranche(Header memory h, GrantConfig memory g, uint256 k)
        internal
        pure
        returns (Wallet memory)
    {
        (uint64 start, uint64 cliff, uint64 duration, uint256 amount) =
            VestingSchedules.communityTranche(h.tge, g.amountKash * 1 ether, k);
        bytes memory args = abi.encode(g.beneficiary, start, cliff, duration);
        bytes memory initCode =
            abi.encodePacked(type(KonstellationVestingWallet).creationCode, args);
        string memory label = string.concat(g.label, "-y", vm.toString(k + 1));
        return _wallet(h.deployer, label, initCode, amount, false);
    }

    /// @notice Prints the plan: one line per wallet, `label address amountKash revocable`, then
    /// the total. The address/amount pairs are what a genesis allocation file needs.
    function predict() external view returns (Wallet[] memory wallets) {
        wallets = plan(configPath());
        uint256 total;
        console.log("config:", configPath());
        console.log("Create2Deployer:", Create2DeployerLib.addr(vm));
        for (uint256 i = 0; i < wallets.length; i++) {
            Wallet memory x = wallets[i];
            console.log(
                string.concat(
                    x.label,
                    " ",
                    vm.toString(x.addr),
                    " ",
                    vm.toString(x.amount / 1 ether),
                    x.revocable ? " revocable" : " non-revocable"
                )
            );
            total += x.amount;
        }
        console.log("total KASH in vesting:", total / 1 ether);
    }

    /// @notice Deploys every wallet in the plan that does not exist yet, then checks each one
    /// against its config and reports its funding. Idempotent.
    function run() external returns (Wallet[] memory wallets) {
        address deployer = Create2DeployerLib.addr(vm);
        require(deployer.code.length > 0, "DeployVesting: Create2Deployer is not preinstalled here");
        wallets = plan(configPath());

        vm.startBroadcast();
        for (uint256 i = 0; i < wallets.length; i++) {
            Wallet memory x = wallets[i];
            if (x.addr.code.length == 0) {
                ICreate2Deployer(deployer).deploy(0, x.salt, x.initCode);
                console.log("deployed", x.label, x.addr);
            } else {
                console.log("exists  ", x.label, x.addr);
            }
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < wallets.length; i++) {
            Wallet memory x = wallets[i];
            require(x.addr.code.length > 0, string.concat(x.label, ": no code after deploy"));
            require(
                RevocableVestingWallet(payable(x.addr)).owner() != address(0),
                string.concat(x.label, ": unexpected contract")
            );
            uint256 bal = x.addr.balance;
            if (bal != x.amount) {
                console.log(
                    string.concat(
                        "WARNING ",
                        x.label,
                        " holds ",
                        vm.toString(bal / 1 ether),
                        " KASH, config says ",
                        vm.toString(x.amount / 1 ether),
                        " (genesis allocation missing? use fund() on testnets)"
                    )
                );
            }
        }
    }

    /// @notice Sends each wallet the difference between its config amount and its balance,
    /// from the broadcaster. For testnets / dev chains where genesis did not pre-fund the
    /// addresses; on mainnet the allocation is in genesis.json and this is a no-op.
    function fund() external {
        Wallet[] memory wallets = plan(configPath());
        vm.startBroadcast();
        for (uint256 i = 0; i < wallets.length; i++) {
            Wallet memory x = wallets[i];
            uint256 bal = x.addr.balance;
            if (bal >= x.amount) continue;
            (bool ok,) = x.addr.call{value: x.amount - bal}("");
            require(ok, string.concat(x.label, ": funding transfer failed"));
            console.log("funded  ", x.label, (x.amount - bal) / 1 ether);
        }
        vm.stopBroadcast();
    }

    function _wallet(
        address deployer,
        string memory label,
        bytes memory initCode,
        uint256 amount,
        bool revocable
    ) internal pure returns (Wallet memory) {
        bytes32 s = salt(label);
        return Wallet({
            label: label,
            salt: s,
            addr: Create2DeployerLib.predict(deployer, s, initCode),
            initCode: initCode,
            amount: amount,
            revocable: revocable
        });
    }

    function _isKind(GrantConfig memory g, string memory kind) internal pure returns (bool) {
        return keccak256(bytes(g.kind)) == keccak256(bytes(kind));
    }
}
