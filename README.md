# contracts

Solidity for Konstellation (Foundry): genesis preinstall pins, the WKASH wrapped token, and the
D12 vesting contracts. See `ENGINEERING.md §6.3` in the org root for the spec, `TOKENOMICS.md §7`
for the schedules the vesting contracts implement.

```
src/WKASH.sol                          wrapped native token (KASH / esp, 18 decimals) -- post-genesis deploy
src/vesting/KonstellationVestingWallet.sol   linear vesting + cliff, NOT revocable (treasury, community)
src/vesting/RevocableVestingWallet.sol       + revoke() by the foundation multisig (team grants, D12)
src/vesting/VestingSchedules.sol             TOKENOMICS §7 buckets as (start, cliff, duration) -- numbers live here
preinstalls/*.json                     pinned bytecode for genesis preinstalls, canonical mainnet addresses
script/DeployWKASH.s.sol               CREATE2 deploy of WKASH at its fixed address
script/DeployVesting.s.sol             CREATE2 deploy of a whole vesting schedule from a JSON config
script/config/vesting.example.json     the §7 schedule with placeholder addresses
script/lib/Create2Deployer.sol         preinstalled Create2Deployer: interface, address, address formula
script/VerifyPreinstalls.s.sol         live check: preinstalls/*.json vs what is actually deployed
test/GenesisBytecode.t.sol             offline check: preinstalls/*.json internal integrity
test/DeployWKASH.t.sol                 pins the WKASH address (below)
test/DeployVesting.t.sol               config validation + the vesting deploy against the example config
test/Create2DeployerPreinstall.t.sol   what the scripts assume about the preinstalled deployer
test/vesting/InitCodePins.t.sol        pins every CREATE2 creation-code hash (an OZ change moves wallets)
test/vesting/*.t.sol                   wallet behaviour, revoke paths, §7 year table, fuzz
test/fixtures/vesting.*.json           malformed configs the script must refuse
CODEOWNERS                             stricter rule for src/vesting/ and preinstalls/
```

## Build and test

```shell
forge build
forge test          # 85 tests incl. 6 fuzz properties at 1000 runs each ([fuzz] in foundry.toml)
forge fmt --check   # CI runs all three
```

## Dependencies

Git submodules under `lib/`, pinned by tag in `foundry.lock` (`forge install <dep>@<tag>`):

| Dependency | Tag | Used for |
|---|---|---|
| `foundry-rs/forge-std` | `v1.16.2` | tests, scripts |
| `OpenZeppelin/openzeppelin-contracts` | `v5.7.0` | `VestingWallet`, `VestingWalletCliff`, `Ownable`, `Address`, `Create2` |

Remappings are in `remappings.txt`. Bump a dependency by re-running `forge install` with the new
tag and updating this table; never track a branch (`ENGINEERING.md §2.3`).

## Deterministic addresses

WKASH and every vesting wallet are deployed post-genesis through the preinstalled
[`Create2Deployer`](preinstalls/Create2Deployer.json) at
`0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2`, so their addresses are a function of
`(deployer, salt, init code)` only and are the **same on every Konstellation network** (testnet-1,
konstellation-1, local dev). `deploy()` on it is permissionless: anyone can run the scripts and
get the same result.

To keep the init code stable, `foundry.toml` strips the CBOR metadata / IPFS hash from bytecode
(`bytecode_hash = "none"`, `cbor_metadata = false`): a comment edit does not move an address; a
change to compiled code, `solc`, `optimizer_runs` or `evm_version` can. Blockscout verifies
such bytecode as a partial match. Compiler pin: `solc = 0.8.37`, `evm_version = prague`
(the chain's fork -- cosmos/evm v0.7.3 `PragueTime = 0`; Osaka is not enabled, see
`foundry.toml`), optimizer 200 runs. The 2026-09-21 move from 0.8.28/cancun to 0.8.37/prague
produced byte-identical bytecode for every contract here, so no address changed.

### WKASH

| | |
|---|---|
| Address | **`0x34Ab8285C63b876717C2c56151700D02623559bE`** |
| Salt | `0x8f7bc75b1a2b0d0c1a3bcf6671fe700cea605f21ec5e30f5085debf329795ea5` = `keccak256("konstellation-network/contracts:WKASH:v1")` |
| Init code hash | `0x0802161d14ce9ad706732c67cb2c77690bd95b8bf26e10353c746b3e3d768e64` (= `keccak256(type(WKASH).creationCode)` at the settings in `foundry.toml`) |

`test/DeployWKASH.t.sol` pins the address; if it fails, something above changed and the pin, this
table, `chain-config` and `docs` must move together, deliberately. WKASH imports no
OpenZeppelin code, so `test/vesting/InitCodePins.t.sol` additionally pins the creation-code hash
of both vesting wallets (`KonstellationVestingWallet`
`0xb3500e085d7b62e11effa65bee747ae5ea54eedeeef3e97a1ec88368485747e0`, `RevocableVestingWallet`
`0x58a1dce05f84504570335ee131f82397a6d370932acfe6d8cfd465d4c1b6f59e`): an OZ bump that changes a
byte moves every wallet address, and that test is what says so. Reproduce independently:

```shell
forge script script/DeployWKASH.s.sol --sig "predict()"
cast create2 --deployer 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2 \
  --salt $(cast keccak "konstellation-network/contracts:WKASH:v1") \
  --init-code-hash $(cast keccak $(jq -r .bytecode.object out/WKASH.sol/WKASH.json))
```

Deploy (any funded key; idempotent):

```shell
forge script script/DeployWKASH.s.sol --rpc-url $RPC --private-key $KEY --broadcast
```

## Vesting (D12)

`ENGINEERING.md §11` D12: Solidity vesting contracts, not `x/auth` vesting accounts. Two
contracts on OpenZeppelin's `VestingWallet` + `VestingWalletCliff`:

- **`KonstellationVestingWallet`** — linear vesting of native KASH with an optional cliff; the
  beneficiary is the OZ `owner()`; `release()` is permissionless and always pays the owner.
  Non-revocable: the treasury and community buckets.
- **`RevocableVestingWallet`** — the same plus a one-shot `revoke()`, callable only by the
  immutable `revoker` (foundation multisig). The amount vested at that moment stays releasable
  to the beneficiary; the unvested remainder goes to the immutable `treasury` in the same call.
  Team grants.

Deviations from stock OpenZeppelin, all deliberate (NatSpec has the detail): **ERC-20 release
is disabled** — cosmos/evm's `werc20` precompile presents the native balance as an ERC-20, so OZ's
`release(token)` path would let a beneficiary withdraw the same KASH twice; `renounceOwnership`
reverts (it would route releases to `address(0)`); and **ownership transfer is two-step**
(`Ownable2Step`: the new beneficiary must `acceptOwnership()`) and refuses the wallet's own
address, so a grant cannot be sent to a typo or into itself (which would corrupt the accounting).

**Address constraints, checked by nobody but the operator.** Every `beneficiary` must be an EOA
or a contract that accepts plain native transfers (a Safe does); anything else — a contract
with no payable receive path, or a Cosmos *module account*, which the chain's balance guard
(`ENGINEERING.md §4.1.1`) refuses EVM value into — makes `release()` revert forever, and since
only the owner can move ownership the grant is unrecoverable. `revoker` and `treasury` are
immutable for the grant's whole life, so they must be **address-stable**: an EOA or a contract
multisig whose address survives signer rotation (a Safe). A Cosmos `x/auth` multisig is *not*
address-stable (its address derives from the member pubkeys and threshold, so any membership
change is a new address) and must not be used. `treasury` must also accept plain native
transfers, else `revoke()` reverts.

A wallet's total is whatever it has ever held, so it can be funded **in genesis** (allocation to
the CREATE2 address before the code exists — nothing can move it until the deterministic code
lands), at deploy time, or by a later transfer; all follow the same schedule.

### TOKENOMICS §7 as wallets (decided 2026-09-20)

`src/vesting/VestingSchedules.sol` is the one place the numbers live; `test/vesting/
VestingSchedules.t.sol` drives real wallets through §7's year-end table (team 22 / 22 / 88 /
154 / 220 / 220 M, treasury 50 / 100 / 150 / 200 / 250 M, community 50 / 134 / 204 / 260 /
302 / 330 M at genesis and the ends of years 1–5).

| Bucket | Wallet | `start` | `cliff` | `duration` |
|---|---|---|---|---|
| Team (220 M, per person): **10 % liquid at genesis** as a plain balance to the member's address, 90 % locked | `RevocableVestingWallet` for the 90 % | TGE + 1 y | 0 | 3 y — 0 at the 12-month cliff, then linear |
| Treasury locked (200 M; 50 M liquid stays with the multisig) | `KonstellationVestingWallet` | TGE | 0 | 4 y |
| Community: grants 180 M and incentives 100 M, each locked | 5 × `KonstellationVestingWallet` per sub-bucket, one per year | TGE + (k−1) y | 0 | 1 y, amounts 30/25/20/15/10 % (grants 54/45/36/27/18 M, incentives 30/25/20/15/10 M) |
| Community-pool seed (50 M) | **none** — a Cosmos module account, written into genesis `distribution` state; the §4.1.1 guard refuses EVM value into it | | | |

A year is 365 days. The community shape (front-loaded, decreasing slope) is piecewise linear and
one linear wallet cannot express it; five yearly tranche wallets express it exactly. Genesis
float is 322 M (32.2 %): validators 120 M + liquidity 80 M + treasury 50 M + pool seed 50 M +
team 22 M.

### Deploying a schedule

`script/DeployVesting.s.sol` reads a JSON config selected by `VESTING_CONFIG` (default
`script/config/vesting.example.json`). **Configs live in `script/config/`** — `fs_permissions`
in `foundry.toml` lets the script read nothing else — so a real network's config is checked in
as `script/config/vesting.<net>.json` (the address/amount list it yields is what
`networks/<net>/` consumes). Amounts are whole KASH: the *whole* grant for `team`, which the
script splits 10 % liquid / 90 % wallet; the *locked* part for `treasury` and `community`.
Parsing is typed and strict: quoted numbers (`"110000000"`, `"0x68e7780"`) mean the same as
plain ones, any key outside the schema (`tge`, `revoker`, `treasury`, `grants[]{amountKash,
beneficiary, kind, label}`, optional `_comment`) is refused, `tge` must be unix seconds in
2001–2096, and `revoker`, `treasury` and every `beneficiary` must be non-zero — a wallet whose
constructor would revert must never get a predicted address, because a genesis allocation
sent there could never be reached by any init code.

```shell
forge script script/DeployVesting.s.sol --sig "check()"       # local dry run: deploys every init code, asserts each address
forge script script/DeployVesting.s.sol --sig "predict()"     # genesis allocation list (below)
forge script script/DeployVesting.s.sol --rpc-url $RPC --private-key $KEY --broadcast   # deploy, idempotent
    # fails unless every wallet holds exactly its amount (genesis funded it); ALLOW_UNFUNDED=true for testnets
ALLOW_UNFUNDED=true forge script script/DeployVesting.s.sol --rpc-url $RPC --private-key $KEY --broadcast
forge script script/DeployVesting.s.sol --sig "fund()" --rpc-url $RPC --private-key $KEY --broadcast
    # testnets/dev only: top each wallet up from the broadcaster; refuses a revoked wallet
```

Run `check()` (CI does) before publishing an allocation list.

`predict()` prints one line per genesis allocation — every wallet with its locked amount, then
every team member's address with their liquid 10 % — exact to the wei, with the KASH figure
showing every fractional digit (a 180 000 001 KASH community bucket yields a 54 000 000.3 KASH
tranche; genesis allocations are whole KASH, so pick amounts divisible by 20 for community and
10 for team, or fund the remainder):

```
treasury-locked        0x7E160C…e103  200000000000000000000000000 esp (200000000 KASH) wallet non-revocable
community-grants-y1    0x7773E5…825D   54000000000000000000000000 esp (54000000 KASH) wallet non-revocable
…
team-founder-1         0xCb17B6…8b58   99000000000000000000000000 esp (99000000 KASH) wallet revocable
team-founder-1-liquid  0x200000…0001     11000000000000000000000000 esp (11000000 KASH) liquid
locked in vesting wallets: 678000000 KASH
liquid to team members:    22000000 KASH
total:                     700000000 KASH
```

Salts are `keccak256("konstellation-network/contracts:vesting:v1:" ‖ label)`; labels must be unique.
A real network's config belongs in `networks/<net>/` once beneficiaries exist.

## Verify preinstalls against their live deployment

```shell
MAINNET_RPC_URL=https://... forge script script/VerifyPreinstalls.s.sol
```
