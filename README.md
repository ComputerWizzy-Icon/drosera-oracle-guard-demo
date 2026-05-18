```md
# Drosera Oracle Manipulation Guard

A production-like Drosera demo that detects oracle manipulation combined with TVL drain and automatically pauses a vulnerable lending pool on Hoodi testnet.

## Overview

This project models a composite DeFi attack where:

- an oracle price is manipulated sharply
- protocol TVL drops materially
- a Drosera Trap evaluates recent state samples
- a relayer-gated Responder pauses the pool if the attack condition is confirmed

The demo is designed to be stricter than a toy mock:

- deployed addresses in the README match the Trap constants
- `collect()` is tested end-to-end against real local mocks
- oracle reads return both `price` and `updatedAt`
- external reads in `collect()` are failure-safe
- malformed sample data is rejected safely
- relayer restrictions are explicit and tested

## Deployed Architecture

The production trap hardcodes the Hoodi addresses in `src/OracleManipulationTrap.sol`.

| Contract | Address |
|---|---|
| AMMOracle | `0x1836A3Ef74CaD2e4089917EDE462ec056e1B2ddC` |
| MockProductionLendingPool | `0x71dC74681c14FB5943790a2b11A4167EEAf42040` |
| DroseraResponder | `0x96FAF4fe85b2bC67A805DFA88d4c6B17f7Dadb48` |
| OracleManipulationTrap | `0x3b983cB787874E6e14a87cdbBBe868B9D471F885` |

If the oracle or pool is redeployed, `_configForChain()` in `src/OracleManipulationTrap.sol` must be updated and the Trap must be redeployed.

## Contract Roles

`src/AMMOracle.sol`

- exposes `getLatestPrice() -> (price, updatedAt)`
- updates `lastUpdated` on swaps
- provides freshness data for the pool and trap

`src/MockProductionLendingPool.sol`

- models a production-like lending target
- tracks collateral, borrows, pause state, and oracle freshness
- exposes `getTvl()` using accounted liquidity minus borrows

`src/OracleManipulationTrap.sol`

- collects price, timestamp, TVL, pause state, block metadata, and read-success flags
- validates sample shape and freshness
- triggers only on price anomaly plus TVL collapse

`src/TestableOracleManipulationTrap.sol`

- allows local Foundry tests to exercise real `collect()` behavior
- exists only for testing, not production deployment

`src/DroseraResponder.sol`

- restricts execution to the configured relayer
- validates approved pools and reasons
- pauses the pool and emits a full response event

## Detection Logic

The Trap evaluates a 5-sample window.

Baseline is built from the previous 4 samples only:

```text
baselinePrice = average(samples[1..4].price)
baselineTvl   = average(samples[1..4].tvl)
```

The current sample is `data[0]`.

A response is rejected if any of the following is true:

- sample count is wrong
- sample encoding is malformed
- any external read failed
- oracle data is stale
- pool/oracle identity changes across samples
- block history is not strictly contiguous
- pool is already paused
- baseline values are too small

A response can trigger only if:

- TVL drop is at least `10%`
- price spikes to at least `5x` baseline, or crashes to at most `1/5x` baseline

An extreme path also exists for:

- price move of at least `10x` or at most `1/10x`
- TVL drop of at least `25%`

## Attack Flow

A representative attack sequence is:

1. The attacker manipulates the AMM oracle.
2. The manipulated oracle inflates or collapses the reported price.
3. The attacker borrows aggressively against the distorted valuation.
4. Pool TVL falls sharply.
5. Drosera operators evaluate the Trap’s recent samples.
6. The Trap returns `(true, payload)` when both price anomaly and TVL drain are confirmed.
7. The configured relayer calls `executeResponse(bytes)`.
8. The Responder pauses the pool.

This means:

- price manipulation alone is not enough
- TVL loss alone is not enough
- both conditions together are treated as the actionable signal

## Drosera Config

Use the following `drosera.toml`:

```toml
ethereum_rpc = "https://ethereum-hoodi-rpc.publicnode.com"
drosera_rpc = "https://relay.hoodi.drosera.io"
eth_chain_id = 560048
drosera_address = "0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D"

[traps.oracle_guard]
path = "out/OracleManipulationTrap.sol/OracleManipulationTrap.json"
response_contract = "0x96FAF4fe85b2bC67A805DFA88d4c6B17f7Dadb48"
response_function = "executeResponse(bytes)"
block_sample_size = 5
cooldown_period_blocks = 20
min_number_of_operators = 3
max_number_of_operators = 7
private_trap = false
whitelist = []
```

## Cooldown

`cooldown_period_blocks = 20` is the mock-production default.

A cooldown of `1` may be useful for fast testnet demos, but it should be marked as testnet-only because it can cause repeated response attempts while the condition remains true.

## Relayer Assumption

The responder requires the actual onchain caller to match its configured `relayer` address.

That relayer should be the operator-side EOA that submits `executeResponse(bytes)`, not the seed-node URL `https://relay.hoodi.drosera.io`.

If the relayer is configured incorrectly:

- the Trap can still detect correctly
- response execution will revert with `not relayer`

Current deployed responder:

```text
Responder: 0x96FAF4fe85b2bC67A805DFA88d4c6B17f7Dadb48
Relayer: the operator EOA that actually submits executeResponse(bytes)
```

## Tests

`test/Attack.t.sol` covers:

- real `collect()` decoding against local mocks
- malformed sample handling without revert
- spike plus TVL-drop detection
- crash plus TVL-drop detection
- no false positive on normal operation
- relayer failure on wrong caller and success on correct caller

Current local result:

```text
8 tests passed, 0 failed
```

Run locally with:

```bash
forge test -vvv
```

## Summary

This repository demonstrates a production-like Drosera monitoring pattern for DeFi security: detect combined oracle manipulation and liquidity drain conditions, then pause the vulnerable pool through a relayer-gated response path.
```