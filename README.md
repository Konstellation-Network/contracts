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
test/DeployVesting.t.sol               runs the vesting deploy against the example config
test/vesting/*.t.sol                   wallet behaviour, revoke paths, §7 year table, fuzz
CODEOWNERS                             stricter rule for src/vesting/ and preinstalls/
```

## Build and test

```shell
forge build
forge test          # 56 tests incl. 5 fuzz properties at 1000 runs each ([fuzz] in foundry.toml)
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
change to compiled code, `solc`, `optimizer_runs` or `evm_version` does. Blockscout verifies
such bytecode as a partial match.

### WKASH

| | |
|---|---|
| Address | **`0x34Ab8285C63b876717C2c56151700D02623559bE`** |
| Salt | `0x8f7bc75b1a2b0d0c1a3bcf6671fe700cea605f21ec5e30f5085debf329795ea5` = `keccak256("konstellation-network/contracts:WKASH:v1")` |
| Init code hash | `0x0802161d14ce9ad706732c67cb2c77690bd95b8bf26e10353c746b3e3d768e64` (= `keccak256(type(WKASH).creationCode)` at the settings in `foundry.toml`) |

`test/DeployWKASH.t.sol` pins the address; if it fails, something above changed and the pin, this
table, `chain-config` and `docs` must move together, deliberately. Reproduce independently:

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

Deviations from stock OpenZeppelin, both deliberate (NatSpec has the detail): **ERC-20 release
is disabled** — cosmos/evm's `werc20` precompile presents the native balance as an ERC-20, so OZ's
`release(token)` path would let a beneficiary withdraw the same KASH twice; and
`renounceOwnership` reverts (it would route releases to `address(0)`).

A wallet's total is whatever it has ever held, so it can be funded **in genesis** (allocation to
the CREATE2 address before the code exists — nothing can move it until the deterministic code
lands), at deploy time, or by a later transfer; all follow the same schedule.

### TOKENOMICS §7 as wallets

`src/vesting/VestingSchedules.sol` is the one place the numbers live; `test/vesting/
VestingSchedules.t.sol` drives real wallets through §7's year-end table.

| Bucket | Wallet | `start` | `cliff` | `duration` |
|---|---|---|---|---|
| Team (220 M, per person) | `RevocableVestingWallet` | TGE + 1 y | 0 | 3 y — 0 at the 12-month cliff, then linear (§7: 0 / 73 / 147 / 220 M) |
| Treasury locked (200 M; 50 M liquid stays with the multisig) | `KonstellationVestingWallet` | TGE | 0 | 4 y |
| Community locked (300 M; 30 M liquid) | 5 × `KonstellationVestingWallet`, one per year | TGE + (k−1) y | 0 | 1 y, amounts 30/25/20/15/10 % |

A year is 365 days. The community shape (front-loaded, decreasing slope) is piecewise linear and
one linear wallet cannot express it; five yearly tranche wallets express it exactly.

### Deploying a schedule

`script/DeployVesting.s.sol` reads a JSON config (`VESTING_CONFIG`, default
`script/config/vesting.example.json`; amounts in whole KASH, the *locked* part of each bucket):

```shell
forge script script/DeployVesting.s.sol --sig "predict()"     # addresses + amounts, for genesis allocations
forge script script/DeployVesting.s.sol --rpc-url $RPC --private-key $KEY --broadcast   # deploy, idempotent
forge script script/DeployVesting.s.sol --sig "fund()" --rpc-url $RPC --private-key $KEY --broadcast
    # testnets/dev only: top each wallet up from the broadcaster; on mainnet genesis pre-funds them
```

Salts are `keccak256("konstellation-network/contracts:vesting:v1:" ‖ label)`; labels must be unique.
A real network's config belongs in `networks/<net>/` once beneficiaries exist.

## Verify preinstalls against their live deployment

```shell
MAINNET_RPC_URL=https://... forge script script/VerifyPreinstalls.s.sol
```
