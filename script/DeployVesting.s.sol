// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {KonstellationVestingWallet} from "../src/vesting/KonstellationVestingWallet.sol";
import {RevocableVestingWallet} from "../src/vesting/RevocableVestingWallet.sol";
import {VestingSchedules} from "../src/vesting/VestingSchedules.sol";
import {Create2DeployerLib, ICreate2Deployer} from "./lib/Create2Deployer.sol";
import {InitCodePins} from "./lib/InitCodePins.sol";

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
/// Every entry point first checks this build's wallet creation code against the pins in
/// script/lib/InitCodePins.sol: a drifted build (other optimizer settings, `--via-ir`, a stray
/// `.env`, a bumped dependency) is refused before it can emit an address.
///
/// The config is parsed field by field with typed accessors and validated: every key is checked
/// against the schema and must occur exactly once in the raw file (forge's JSON parser keeps
/// the last of two duplicate keys and reports one), a quoted number means the same as a plain
/// one, labels are `[a-z0-9-]+` and never end in `-liquid`, `tge` is unix seconds in 2001..2096,
/// team grants are a multiple of 10 KASH and community buckets of 20 KASH (so every wallet and
/// liquid amount is a whole KASH, as genesis allocations are), no beneficiary appears twice, and
/// `revoker` / `treasury` are non-zero, are not a team beneficiary and are not a planned wallet
/// address (a treasury that is itself a vesting wallet would hand revoked KASH to that wallet's
/// beneficiary). A wallet whose constructor would revert must never reach `predict()`, because a
/// genesis allocation at an address no init code can ever succeed at is lost. Those addresses
/// must also be EOAs or contracts that accept plain native transfers and are address-stable
/// for the life of the grant (a Safe is; a Cosmos `x/auth` multisig and a module account are
/// not) -- the script cannot check that, so the operator must.
///
/// `check()` executes every planned init code on a local EVM (the pinned Create2Deployer is
/// etched if absent) and asserts code at each predicted address with the configured parameters:
/// run it, and CI does, before an allocation list is published. `predict()` prints the genesis
/// allocation list: every wallet (locked amounts) and every team beneficiary (liquid amounts),
/// exact to the wei. The 50 M community-pool seed is genesis `distribution` state and is not
/// modelled here.
///
/// Configs live in script/config/ (`fs_permissions` in foundry.toml allows nothing else): a real
/// network's is `script/config/vesting.<net>.json`, checked in, and `VESTING_CONFIG` selects it
/// (from the command line -- `.env` is gitignored and must not be relied on).
///
/// Funding: a wallet has "received" `balance + released()`; `run()` reverts on a shortfall
/// against the config amount and only warns on a surplus (anyone can send dust to a public
/// address; extra KASH simply vests to the beneficiary), so a wallet that has already released
/// is still recognised as funded and `run()` stays idempotent. Nothing in the environment
/// relaxes that: the testnet path, where genesis did not fund the wallets, is the explicit
/// `run(string,bool,bool)` overload followed by `fund()`, which sends only the shortfall.
///
/// Usage (VESTING_CONFIG defaults to script/config/vesting.example.json):
///   forge script script/DeployVesting.s.sol --sig "check()"                     # local dry run
///   forge script script/DeployVesting.s.sol --sig "predict()"                   # allocations
///   forge script script/DeployVesting.s.sol --rpc-url ... --broadcast           # mainnet deploy
///   forge script script/DeployVesting.s.sol --rpc-url ... --broadcast \
///     --sig "run(string,bool,bool)" script/config/vesting.testnet-1.json true false
///     # testnets: allowShortfall=true (fund() next); allowStaleTge=true only for a dev chain
///     # whose tge is deliberately in the past
///   forge script script/DeployVesting.s.sol --sig "fund()" --rpc-url ... --broadcast
///     # testnets only: send each wallet its shortfall from the broadcaster
contract DeployVestingScript is Script {
    string internal constant DEFAULT_CONFIG = "script/config/vesting.example.json";
    string internal constant SALT_PREFIX = "konstellation-network/contracts:vesting:v1:";

    /// @dev Sanity range for `tge`: 2001-09-09 .. 2096-10-02. Outside it is a units mistake
    /// (milliseconds, a block number) or an overflow, never a launch date.
    uint256 internal constant TGE_MIN = 1_000_000_000;
    uint256 internal constant TGE_MAX = 4_000_000_000;
    /// @dev A tge more than this far in the past is stale: the schedule would be partly or wholly
    /// vested the moment the wallets exist.
    uint256 internal constant TGE_STALE_AFTER = 30 days;
    /// @dev §7 granularity: a team grant splits 10/90, a community bucket 30/25/20/15/10 %.
    uint256 internal constant TEAM_GRANULARITY_KASH = 10;
    uint256 internal constant COMMUNITY_GRANULARITY_KASH = 20;

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
        InitCodePins.requireCanonicalVesting();
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
        _requireKeyCounts(json, n);
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
            _validateGrant(h, grants[i]);
            for (uint256 j = 0; j < i; j++) {
                require(
                    grants[j].beneficiary != grants[i].beneficiary,
                    string.concat(
                        grants[i].label, ": beneficiary already used by ", grants[j].label
                    )
                );
            }
        }
    }

    /// @dev Per-grant semantic checks (label charset, amounts, addresses).
    function _validateGrant(Header memory h, GrantConfig memory g) internal pure {
        _validateLabel(g.label);
        require(g.beneficiary != address(0), string.concat(g.label, ": zero beneficiary"));
        require(g.amountKash > 0, string.concat(g.label, ": zero amount"));
        if (_isKind(g, "team")) {
            require(
                g.amountKash % TEAM_GRANULARITY_KASH == 0,
                string.concat(g.label, ": team grant must be a multiple of 10 KASH")
            );
            require(
                g.beneficiary != h.revoker, string.concat(g.label, ": beneficiary is the revoker")
            );
            require(
                g.beneficiary != h.treasury, string.concat(g.label, ": beneficiary is the treasury")
            );
        } else if (_isKind(g, "community")) {
            require(
                g.amountKash % COMMUNITY_GRANULARITY_KASH == 0,
                string.concat(g.label, ": community bucket must be a multiple of 20 KASH")
            );
        }
    }

    /// @dev Labels are salt preimages and file/allocation names: non-empty, `[a-z0-9-]` only (no
    /// unicode confusables, no upper case), and never ending in `-liquid`, which is reserved for
    /// the generated liquid entries.
    function _validateLabel(string memory label) internal pure {
        bytes memory b = bytes(label);
        require(b.length > 0, "config: empty label");
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-";
            require(ok, string.concat(label, ": label must match [a-z0-9-]+"));
        }
        require(
            !_endsWith(label, "-liquid"), string.concat(label, ": label must not end in -liquid")
        );
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory z = bytes(suffix);
        if (z.length > a.length) return false;
        for (uint256 i = 0; i < z.length; i++) {
            if (a[a.length - z.length + i] != z[i]) return false;
        }
        return true;
    }

    /// @dev Every schema key must occur exactly once per object in the raw file. Forge's JSON
    /// parser keeps the last of two duplicate keys and `parseJsonKeys` reports one, so a second
    /// `"amountKash": 1` or a trailing `"tge": ...` would otherwise win silently. Keys are
    /// counted as `"<key>"` followed by optional whitespace and `:`, not preceded by a backslash;
    /// labels cannot contain quotes and `_comment` can only contain an escaped `\"`, so no value
    /// can fake a key.
    function _requireKeyCounts(string memory json, uint256 grantsCount) internal pure {
        string[] memory hk = _headerKeys();
        for (uint256 i = 0; i < hk.length; i++) {
            uint256 c = _countKey(json, hk[i]);
            require(c == 1, string.concat("config: key '", hk[i], "' must occur exactly once"));
        }
        string[] memory ok = _headerOptionalKeys();
        for (uint256 i = 0; i < ok.length; i++) {
            uint256 c = _countKey(json, ok[i]);
            require(c <= 1, string.concat("config: key '", ok[i], "' must occur at most once"));
        }
        string[] memory gk = _grantKeys();
        for (uint256 i = 0; i < gk.length; i++) {
            uint256 c = _countKey(json, gk[i]);
            require(
                c == grantsCount,
                string.concat("config: key '", gk[i], "' must occur exactly once per grant")
            );
        }
    }

    /// @dev Occurrences of `"key"` + optional whitespace + `:` in `json`, ignoring ones whose
    /// opening quote is escaped.
    function _countKey(string memory json, string memory key) internal pure returns (uint256 n) {
        bytes memory j = bytes(json);
        bytes memory pat = bytes(string.concat("\"", key, "\""));
        if (pat.length > j.length) return 0;
        for (uint256 i = 0; i + pat.length <= j.length; i++) {
            if (i > 0 && j[i - 1] == "\\") continue;
            bool hit = true;
            for (uint256 k = 0; k < pat.length; k++) {
                if (j[i + k] != pat[k]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) continue;
            uint256 p = i + pat.length;
            while (p < j.length && (j[p] == " " || j[p] == "\t" || j[p] == "\n" || j[p] == "\r")) {
                p++;
            }
            if (p < j.length && j[p] == ":") n++;
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
            require(
                wallets[i].addr != h.treasury && wallets[i].addr != h.revoker,
                string.concat("config: treasury/revoker is the ", wallets[i].label, " wallet")
            );
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
        _warnIfStale(path, vm.unixTime() / 1000);
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
        return run(configPath(), false, false);
    }

    /// @notice `run()` for an explicit config path and policy. `allowShortfall` turns a funding
    /// shortfall into a warning (testnets, before `fund()`); `allowStaleTge` accepts a `tge`
    /// more than 30 days before the chain's clock (a dev chain replaying a past schedule).
    /// Neither is read from the environment.
    function run(string memory path, bool allowShortfall, bool allowStaleTge)
        public
        returns (Wallet[] memory wallets)
    {
        address deployer = Create2DeployerLib.addr(vm);
        require(deployer.code.length > 0, "DeployVesting: Create2Deployer is not preinstalled here");
        wallets = plan(path);
        (Header memory h,) = readConfig(path);
        // A stale tge only matters for wallets that do not exist yet: re-running later, over
        // an already deployed schedule, must stay idempotent.
        bool anyToDeploy;
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i].addr.code.length == 0) anyToDeploy = true;
        }
        if (anyToDeploy) _requireFreshTge(h, allowStaleTge);

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
            uint256 received = _received(x.addr);
            if (received == x.amount) continue;
            string memory msg_ = string.concat(
                x.label,
                " received ",
                formatKash(received),
                " KASH (balance + released), config says ",
                formatKash(x.amount)
            );
            if (received > x.amount) {
                console.log("WARNING surplus:", msg_);
                continue;
            }
            require(allowShortfall, string.concat("shortfall: ", msg_));
            console.log("WARNING shortfall:", msg_);
        }
    }

    /// @notice What a wallet has been given so far: its balance plus what it already released.
    function _received(address wallet) internal view returns (uint256) {
        return wallet.balance + KonstellationVestingWallet(payable(wallet)).released();
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
            uint256 received = _received(x.addr);
            if (received >= x.amount) continue;
            (bool ok,) = x.addr.call{value: x.amount - received}("");
            require(ok, string.concat(x.label, ": funding transfer failed"));
            console.log(
                string.concat("funded   ", x.label, " ", formatKash(x.amount - received), " KASH")
            );
        }
        vm.stopBroadcast();
    }

    // --- internals ------------------------------------------------------------------------------

    /// @dev On-chain time: a tge more than TGE_STALE_AFTER before `block.timestamp` is refused
    /// unless explicitly allowed.
    function _requireFreshTge(Header memory h, bool allowStale) internal view {
        // Off-chain script logic with a 30-day tolerance: validator drift is irrelevant here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > uint256(h.tge) + TGE_STALE_AFTER) {
            string memory msg_ = string.concat(
                "config: tge ",
                vm.toString(h.tge),
                " is more than 30 days before the chain's clock ",
                vm.toString(block.timestamp),
                " -- the schedule would start already vested"
            );
            require(allowStale, msg_);
            console.log("WARNING", msg_);
        }
    }

    /// @dev Offline entry points only have the wall clock; say so, do not refuse.
    function _warnIfStale(string memory path, uint256 nowSeconds) internal view {
        (Header memory h,) = readConfig(path);
        if (nowSeconds > uint256(h.tge) + TGE_STALE_AFTER) {
            console.log(
                string.concat(
                    "WARNING tge ",
                    vm.toString(h.tge),
                    " is more than 30 days in the past (wall clock ",
                    vm.toString(nowSeconds),
                    "); run() will refuse it unless allowStaleTge"
                )
            );
        }
    }

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
