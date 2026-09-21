// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

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
/// Config → wallets (`VestingSchedules` holds the numbers; amounts in whole KASH):
/// - `team`      → the whole grant: 10 % is a plain genesis balance to the beneficiary (no
///                 contract), 90 % goes into one `RevocableVestingWallet` (revoker / treasury
///                 from the config header)
/// - `treasury`  → the locked part, one `KonstellationVestingWallet`
/// - `community` → the locked part, five `KonstellationVestingWallet`s, `<label>-y1` … `-y5`
///
/// The config is parsed field by field with typed accessors and every key is checked against
/// the schema, so a quoted number, a typo'd key or a missing field is an error, never a silently
/// wrong amount. `revoker`, `treasury` and every `beneficiary` must be non-zero; a wallet whose
/// constructor would revert must never reach `predict()`, because a genesis allocation at an
/// address no init code can ever succeed at is lost. Those addresses must also be EOAs or
/// contracts that accept plain native transfers and are address-stable for the life of the
/// grant (a Safe is; a Cosmos `x/auth` multisig and a module account are not) -- the script
/// cannot check that, so the operator must.
///
/// `check()` executes every planned init code on a local EVM (the pinned Create2Deployer is
/// etched if absent) and asserts code at each predicted address with the configured parameters:
/// run it, and CI does, before an allocation list is published. `predict()` prints the genesis
/// allocation list: every wallet (locked amounts) and every team beneficiary (liquid amounts),
/// exact to the wei. The 50 M community-pool seed is genesis `distribution` state and is not
/// modelled here.
///
/// Configs live in script/config/ (`fs_permissions` in foundry.toml allows nothing else): a real
/// network's is `script/config/vesting.<net>.json`, checked in, and `VESTING_CONFIG` selects it.
///
/// Usage (VESTING_CONFIG defaults to script/config/vesting.example.json):
///   forge script script/DeployVesting.s.sol --sig "check()"                     # local dry run
///   forge script script/DeployVesting.s.sol --sig "predict()"                   # allocations
///   forge script script/DeployVesting.s.sol --rpc-url ... --broadcast           # deploy
///     # requires every wallet to hold exactly its amount (genesis funded it), unless
///     # ALLOW_UNFUNDED=true (testnets / dev, before fund())
///   forge script script/DeployVesting.s.sol --sig "fund()" --rpc-url ... --broadcast
///     # testnets only: top each wallet up to its amount from the broadcaster
contract DeployVestingScript is Script {
    string internal constant DEFAULT_CONFIG = "script/config/vesting.example.json";
    string internal constant SALT_PREFIX = "konstellation-network/contracts:vesting:v1:";

    /// @dev Sanity range for `tge`: 2001-09-09 .. 2096-10-02. Outside it is a units mistake
    /// (milliseconds, a block number) or an overflow, never a launch date.
    uint256 internal constant TGE_MIN = 1_000_000_000;
    uint256 internal constant TGE_MAX = 4_000_000_000;

    /// @dev One `grants[]` entry, exactly these keys.
    struct GrantConfig {
        uint256 amountKash;
        address beneficiary;
        string kind;
        string label;
    }

    /// @dev One genesis allocation: a vesting wallet's locked amount, or a team member's liquid
    /// 10 % paid straight to their address.
    struct Allocation {
        string label;
        address addr;
        uint256 amount; // esp (wei)
        bool isWallet;
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

    /// @dev The config header plus the deployer, passed around to keep stack depth down.
    struct Header {
        uint64 tge;
        address revoker;
        address treasury;
        address deployer;
    }

    // --- config ---------------------------------------------------------------------------------

    /// @notice The config file in use.
    function configPath() public view returns (string memory) {
        return vm.envOr("VESTING_CONFIG", string(DEFAULT_CONFIG));
    }

    /// @notice CREATE2 salt for a wallet label.
    function salt(string memory label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_PREFIX, label));
    }

    /// @notice Parses and validates a config file. Reverts on any key outside the schema, any
    /// missing key, a `tge` outside `TGE_MIN..TGE_MAX`, or a zero `revoker` / `treasury`.
    function readConfig(string memory path)
        public
        view
        returns (Header memory h, GrantConfig[] memory grants)
    {
        string memory json = vm.readFile(path);
        _requireKeys(json, "", _headerKeys(), _headerOptionalKeys());

        uint256 tge = vm.parseJsonUint(json, ".tge");
        require(tge >= TGE_MIN && tge <= TGE_MAX, "config: tge out of range (unix seconds)");
        h = Header({
            // tge <= TGE_MAX (4e9) < 2^64, checked above.
            // forge-lint: disable-next-line(unsafe-typecast)
            tge: uint64(tge),
            revoker: vm.parseJsonAddress(json, ".revoker"),
            treasury: vm.parseJsonAddress(json, ".treasury"),
            deployer: Create2DeployerLib.addr(vm)
        });
        require(h.revoker != address(0), "config: zero revoker");
        require(h.treasury != address(0), "config: zero treasury");

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".grants[", vm.toString(n), "]"))) {
            n++;
        }
        require(n > 0, "config: no grants");
        grants = new GrantConfig[](n);
        string[] memory none;
        for (uint256 i = 0; i < n; i++) {
            string memory g = string.concat(".grants[", vm.toString(i), "]");
            _requireKeys(json, g, _grantKeys(), none);
            grants[i] = GrantConfig({
                amountKash: vm.parseJsonUint(json, string.concat(g, ".amountKash")),
                beneficiary: vm.parseJsonAddress(json, string.concat(g, ".beneficiary")),
                kind: vm.parseJsonString(json, string.concat(g, ".kind")),
                label: vm.parseJsonString(json, string.concat(g, ".label"))
            });
            require(
                grants[i].beneficiary != address(0),
                string.concat(grants[i].label, ": zero beneficiary")
            );
            require(grants[i].amountKash > 0, string.concat(grants[i].label, ": zero amount"));
        }
    }

    // --- plan -----------------------------------------------------------------------------------

    /// @notice Expands the config into the concrete list of wallets, with predicted addresses.
    function plan(string memory path) public view returns (Wallet[] memory wallets) {
        (Header memory h, GrantConfig[] memory grants) = readConfig(path);

        uint256 n;
        for (uint256 i = 0; i < grants.length; i++) {
            n += _isKind(grants[i], "community") ? VestingSchedules.COMMUNITY_TRANCHES : 1;
        }
        wallets = new Wallet[](n);

        uint256 w;
        for (uint256 i = 0; i < grants.length; i++) {
            GrantConfig memory g = grants[i];
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

    /// @notice The genesis allocation list for a config: one entry per wallet (its locked amount,
    /// `isWallet = true`) followed by one entry per team grant's liquid 10 % at the beneficiary
    /// (`<label>-liquid`, `isWallet = false`). The sum is every KASH the config accounts for.
    function allocations(string memory path) public view returns (Allocation[] memory list) {
        Wallet[] memory wallets = plan(path);
        (, GrantConfig[] memory grants) = readConfig(path);

        uint256 liquidCount;
        for (uint256 i = 0; i < grants.length; i++) {
            if (_isKind(grants[i], "team")) liquidCount++;
        }
        list = new Allocation[](wallets.length + liquidCount);

        uint256 n;
        for (uint256 i = 0; i < wallets.length; i++) {
            list[n++] = Allocation({
                label: wallets[i].label,
                addr: wallets[i].addr,
                amount: wallets[i].amount,
                isWallet: true
            });
        }
        for (uint256 i = 0; i < grants.length; i++) {
            if (!_isKind(grants[i], "team")) continue;
            (uint256 liquid,) = VestingSchedules.teamSplit(grants[i].amountKash * 1 ether);
            list[n++] = Allocation({
                label: string.concat(grants[i].label, "-liquid"),
                addr: grants[i].beneficiary,
                amount: liquid,
                isWallet: false
            });
        }
    }

    // --- entry points ---------------------------------------------------------------------------

    /// @notice Prints the genesis allocation list, one line per entry:
    /// `label address <esp> esp (<KASH> KASH) wallet|liquid [revocable|non-revocable]`, then
    /// the totals. The esp figure is exact; the KASH figure shows every fractional digit. The
    /// address/amount pairs are what `networks/<net>/allocations.json` needs.
    function predict() external view returns (Allocation[] memory list) {
        return predict(configPath());
    }

    /// @notice `predict()` for an explicit config path.
    function predict(string memory path) public view returns (Allocation[] memory list) {
        Wallet[] memory wallets = plan(path);
        list = allocations(path);
        uint256 locked;
        uint256 liquid;
        console.log("config:", path);
        console.log("Create2Deployer:", Create2DeployerLib.addr(vm));
        for (uint256 i = 0; i < list.length; i++) {
            Allocation memory a = list[i];
            string memory kind = "liquid";
            if (a.isWallet) {
                kind = wallets[i].revocable ? "wallet revocable" : "wallet non-revocable";
                locked += a.amount;
            } else {
                liquid += a.amount;
            }
            console.log(
                string.concat(
                    a.label,
                    " ",
                    vm.toString(a.addr),
                    " ",
                    vm.toString(a.amount),
                    " esp (",
                    formatKash(a.amount),
                    " KASH) ",
                    kind
                )
            );
        }
        console.log(string.concat("locked in vesting wallets: ", formatKash(locked), " KASH"));
        console.log(string.concat("liquid to team members:    ", formatKash(liquid), " KASH"));
        console.log(
            string.concat("total:                     ", formatKash(locked + liquid), " KASH")
        );
    }

    /// @notice Local dry run, no RPC: executes every planned init code through the pinned
    /// Create2Deployer (etched if this EVM lacks it) and asserts each wallet lands at its
    /// predicted address with the configured beneficiary, schedule, revoker and treasury. Run
    /// this before publishing an allocation list; a config that passes `predict()` but fails
    /// here would leave genesis funds at addresses no code can ever reach.
    function check() external returns (Wallet[] memory wallets) {
        return check(configPath());
    }

    /// @notice `check()` for an explicit config path.
    function check(string memory path) public returns (Wallet[] memory wallets) {
        address deployer = Create2DeployerLib.addr(vm);
        if (deployer.code.length == 0) vm.etch(deployer, Create2DeployerLib.code(vm));
        wallets = plan(path);
        (Header memory h,) = readConfig(path);

        for (uint256 i = 0; i < wallets.length; i++) {
            Wallet memory x = wallets[i];
            require(x.addr.code.length == 0, string.concat(x.label, ": address already has code"));
            ICreate2Deployer(deployer).deploy(0, x.salt, x.initCode);
            _verifyWallet(h, x);
        }
        console.log(
            string.concat(
                "check: ",
                vm.toString(wallets.length),
                " wallets deploy at their predicted addresses"
            )
        );
    }

    /// @notice Deploys every wallet in the plan that does not exist yet, then checks each one
    /// against its config. Every wallet must hold exactly its configured amount afterwards
    /// (genesis funded it) unless `ALLOW_UNFUNDED=true` (testnets / dev, before `fund()`).
    /// Idempotent.
    function run() external returns (Wallet[] memory wallets) {
        return run(configPath(), vm.envOr("ALLOW_UNFUNDED", false));
    }

    /// @notice `run()` for an explicit config path and funding policy.
    function run(string memory path, bool allowUnfunded) public returns (Wallet[] memory wallets) {
        address deployer = Create2DeployerLib.addr(vm);
        require(deployer.code.length > 0, "DeployVesting: Create2Deployer is not preinstalled here");
        wallets = plan(path);
        (Header memory h,) = readConfig(path);

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
            _verifyWallet(h, x);
            uint256 bal = x.addr.balance;
            if (bal == x.amount) continue;
            string memory msg_ = string.concat(
                x.label,
                " holds ",
                formatKash(bal),
                " KASH, config says ",
                formatKash(x.amount),
                " (genesis allocation missing or wrong? ALLOW_UNFUNDED=true + fund() on testnets)"
            );
            require(allowUnfunded, msg_);
            console.log("WARNING", msg_);
        }
    }

    /// @notice Sends each wallet the difference between its config amount and its balance,
    /// from the broadcaster. For testnets / dev chains where genesis did not pre-fund the
    /// addresses; on mainnet the allocation is in genesis.json and this is a no-op. Refuses a
    /// revoked wallet: after a revoke everything it holds belongs to the beneficiary, so a
    /// top-up would hand them what the treasury took back.
    function fund() external {
        fund(configPath());
    }

    /// @notice `fund()` for an explicit config path.
    function fund(string memory path) public {
        Wallet[] memory wallets = plan(path);
        vm.startBroadcast();
        for (uint256 i = 0; i < wallets.length; i++) {
            Wallet memory x = wallets[i];
            require(x.addr.code.length > 0, string.concat(x.label, ": not deployed, run() first"));
            if (x.revocable) {
                require(
                    !RevocableVestingWallet(payable(x.addr)).revoked(),
                    string.concat(x.label, ": revoked, refusing to fund")
                );
            }
            uint256 bal = x.addr.balance;
            if (bal >= x.amount) continue;
            (bool ok,) = x.addr.call{value: x.amount - bal}("");
            require(ok, string.concat(x.label, ": funding transfer failed"));
            console.log(
                string.concat("funded   ", x.label, " ", formatKash(x.amount - bal), " KASH")
            );
        }
        vm.stopBroadcast();
    }

    // --- internals ------------------------------------------------------------------------------

    function _team(Header memory h, GrantConfig memory g) internal pure returns (Wallet memory) {
        (uint64 start, uint64 cliff, uint64 duration) = VestingSchedules.team(h.tge);
        (, uint256 locked) = VestingSchedules.teamSplit(g.amountKash * 1 ether);
        bytes memory args = abi.encode(g.beneficiary, start, cliff, duration, h.revoker, h.treasury);
        bytes memory initCode = abi.encodePacked(type(RevocableVestingWallet).creationCode, args);
        return _wallet(h.deployer, g.label, initCode, locked, true);
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

    /// @dev The wallet at `x.addr` exists and its constructor arguments read back as planned.
    function _verifyWallet(Header memory h, Wallet memory x) internal view {
        require(x.addr.code.length > 0, string.concat(x.label, ": no code at predicted address"));
        KonstellationVestingWallet w = KonstellationVestingWallet(payable(x.addr));
        // The constructor args are the tail of the init code; decode the common prefix.
        (address beneficiary, uint64 start, uint64 cliff, uint64 duration) =
            abi.decode(_args(x), (address, uint64, uint64, uint64));
        require(w.owner() == beneficiary, string.concat(x.label, ": beneficiary mismatch"));
        require(w.start() == start, string.concat(x.label, ": start mismatch"));
        require(w.cliff() == start + cliff, string.concat(x.label, ": cliff mismatch"));
        require(w.duration() == duration, string.concat(x.label, ": duration mismatch"));
        if (x.revocable) {
            RevocableVestingWallet r = RevocableVestingWallet(payable(x.addr));
            require(r.revoker() == h.revoker, string.concat(x.label, ": revoker mismatch"));
            require(r.treasury() == h.treasury, string.concat(x.label, ": treasury mismatch"));
        }
    }

    /// @dev The ABI-encoded constructor arguments appended to the creation code.
    function _args(Wallet memory x) internal pure returns (bytes memory args) {
        uint256 codeLen = x.revocable
            ? type(RevocableVestingWallet).creationCode.length
            : type(KonstellationVestingWallet).creationCode.length;
        args = new bytes(x.initCode.length - codeLen);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = x.initCode[codeLen + i];
        }
    }

    function _isKind(GrantConfig memory g, string memory kind) internal pure returns (bool) {
        return keccak256(bytes(g.kind)) == keccak256(bytes(kind));
    }

    /// @dev Every key at `path` is in `required` or `optional`, and every `required` one exists.
    function _requireKeys(
        string memory json,
        string memory path,
        string[] memory required,
        string[] memory optional
    ) internal pure {
        string memory where = bytes(path).length == 0 ? "config" : path;
        string[] memory keys = vm.parseJsonKeys(json, bytes(path).length == 0 ? "." : path);
        for (uint256 i = 0; i < keys.length; i++) {
            if (!_contains(required, keys[i]) && !_contains(optional, keys[i])) {
                revert(string.concat(where, ": unknown key '", keys[i], "'"));
            }
        }
        for (uint256 i = 0; i < required.length; i++) {
            if (!_contains(keys, required[i])) {
                revert(string.concat(where, ": missing key '", required[i], "'"));
            }
        }
    }

    function _contains(string[] memory list, string memory s) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (keccak256(bytes(list[i])) == keccak256(bytes(s))) return true;
        }
        return false;
    }

    function _headerKeys() internal pure returns (string[] memory k) {
        k = new string[](4);
        k[0] = "tge";
        k[1] = "revoker";
        k[2] = "treasury";
        k[3] = "grants";
    }

    function _headerOptionalKeys() internal pure returns (string[] memory k) {
        k = new string[](1);
        k[0] = "_comment";
    }

    function _grantKeys() internal pure returns (string[] memory k) {
        k = new string[](4);
        k[0] = "amountKash";
        k[1] = "beneficiary";
        k[2] = "kind";
        k[3] = "label";
    }

    /// @notice `amount` in esp rendered as KASH with every non-zero fractional digit, e.g.
    /// 54000000300000000000000000 → "54000000.3".
    function formatKash(uint256 amount) public pure returns (string memory) {
        uint256 whole = amount / 1 ether;
        uint256 frac = amount % 1 ether;
        if (frac == 0) return vm.toString(whole);
        bytes memory digits = new bytes(18);
        for (uint256 i = 18; i > 0; i--) {
            // 48 + (0..9) fits a uint8.
            // forge-lint: disable-next-line(unsafe-typecast)
            digits[i - 1] = bytes1(uint8(48 + frac % 10));
            frac /= 10;
        }
        uint256 len = 18;
        while (digits[len - 1] == "0") {
            len--;
        }
        bytes memory trimmed = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            trimmed[i] = digits[i];
        }
        return string.concat(vm.toString(whole), ".", string(trimmed));
    }
}
