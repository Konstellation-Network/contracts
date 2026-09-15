# contracts

Preinstall Solidity + verification for Konstellation (Foundry). See `ENGINEERING.md §6.3`
in the org root for the full spec.

```
src/WKASH.sol            wrapped native token (KASH / esp, 18 decimals) -- post-genesis deploy
preinstalls/*.json       pinned bytecode for genesis preinstalls, canonical mainnet addresses
script/VerifyPreinstalls.s.sol   live check: preinstalls/*.json vs what's actually deployed
test/GenesisBytecode.t.sol       offline check: preinstalls/*.json internal integrity
```

## Build

```shell
forge build
```

## Test

```shell
forge test
```

## Verify preinstalls against their live deployment

```shell
MAINNET_RPC_URL=https://... forge script script/VerifyPreinstalls.s.sol
```

`src/vesting/` is not yet built. D12 (`ENGINEERING.md §11`) is decided — Solidity vesting
contracts, not `x/auth` vesting accounts — implementation is the next open item here.
