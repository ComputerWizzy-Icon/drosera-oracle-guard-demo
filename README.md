# Drosera Oracle Manipulation Guard

A production-like Drosera demo that detects oracle manipulation combined with liquidity drain and automatically pauses a vulnerable lending pool on Hoodi testnet.

## Overview

This project models a composite DeFi attack where:

- an oracle price is manipulated sharply
- immediately drainable liquidity falls materially
- a Drosera Trap evaluates recent state samples
- a relayer-gated Responder pauses the pool if the condition is confirmed

The current version incorporates the latest review corrections:

- `CollectOutput` uses `uint256` fields and flags
- `shouldRespond()` manually decodes fixed-size samples
- exact collect sample size is enforced
- the pool exposes `getRiskMetrics()` for better trap inputs
- `shouldAlert()` exists for read-failure and stale-oracle alerts
- the responder is idempotent, cooldown-protected, and verifies pause success
- tests cover detection, alerting, relayer gating, and responder cooldown

## Deployed Architecture — Hoodi Testnet

The production Trap hardcodes the Hoodi oracle and pool addresses in `OracleManipulationTrap._configForChain(560048)`.

| Contract | Address |
|---|---|
| AMMOracle | `0xBDBDA35B9A159B7E109b4CCe037201D1D055FF30` |
| MockProductionLendingPool | `0x74D909FA1bFCC2152ed7A99C343249cBB05247D2` |
| DroseraResponder | `0x774f48dC24Bf18F6E5088BC5d240565e203355e9` |
| OracleManipulationTrap | `0xD5B7358A63d93bC9C738BB2BBda8Fa6653697f6D` |

Notes:

- `0x2f7ca9d2D2AcD0D6086e0D989c7c0f9eF04D8A33` was the pre-final trap deployed before the trap-only redeploy.
- `0xD5B7358A63d93bC9C738BB2BBda8Fa6653697f6D` is the final trap address that should be used going forward.

If the oracle or pool is redeployed, update `_configForChain()` in `src/OracleManipulationTrap.sol`, rebuild, and redeploy the Trap.

## Contract Roles

### `src/AMMOracle.sol`

- exposes `getLatestPrice() -> (price, updatedAt)`
- updates `lastUpdated` on swaps
- provides freshness data for both the pool and the trap

### `src/MockProductionLendingPool.sol`

- models a production-like lending target
- tracks collateral, borrows, bad debt, pause state, and oracle freshness
- keeps `getTvl()` for compatibility
- exposes `getRiskMetrics()` as the preferred accounting surface for the Trap

`getRiskMetrics()` returns:

- `availableLiquidity`
- `totalBorrowed`
- `totalCollateral`
- `totalBadDebt`
- `utilizationBps`
- `totalAssets`

For the Trap, `availableLiquidity` is the key drain signal because it measures immediately withdrawable liquidity rather than a looser TVL proxy.

### `src/OracleManipulationTrap.sol`

The Trap collects and evaluates a fixed-size monitoring window.

It records:

- oracle price
- oracle update timestamp
- available liquidity
- borrow/collateral/bad-debt metrics
- utilization
- total assets
- pause state
- block metadata
- read-success flags

`collect()` is failure-safe:

- oracle read failures do not revert
- pool metrics read failures do not revert
- pause-state read failures do not revert
- success/failure is encoded into the sample flags

`shouldRespond()`:

- requires exactly 5 samples
- requires exact collect sample size
- manually decodes each fixed-size sample
- rejects malformed, stale, or inconsistent windows
- builds the baseline from the previous 4 samples only

Trigger conditions:

- liquidity drop of at least `10%`
- and either:
  - price spike of at least `5x`, or
  - price crash to at most `1/5x`

Extreme path:

- price move of at least `10x` or at most `1/10x`
- plus liquidity drop of at least `25%`

### `shouldAlert()`

`shouldAlert()` is an optional non-response path for operator visibility.

It returns alert-only payloads when:

- a read failed
- the oracle is stale

These reasons are intentionally not executable by the responder.

### `src/DroseraResponder.sol`

The responder now:

- restricts execution to the configured relayer
- manually decodes the fixed-size response payload
- rejects alert-only reasons
- checks pool approval
- prevents duplicate handling with `handledIncident`
- enforces on-chain cooldown with `COOLDOWN_BLOCKS`
- verifies the pause actually took effect
- safely no-ops if the exact incident was already handled
- safely no-ops if the pool is already paused from another valid response

## Attack Flow

A representative attack sequence is:

1. The attacker manipulates the AMM oracle.
2. The manipulated oracle distorts the reported price.
3. The attacker borrows aggressively against the distorted valuation.
4. Available liquidity drops sharply.
5. Drosera operators evaluate the Trap’s recent samples.
6. The Trap returns `(true, payload)` only when both price anomaly and liquidity drain are confirmed.
7. The configured relayer calls `executeResponse(bytes)`.
8. The Responder pauses the pool.

This means:

- price manipulation alone is not enough
- liquidity loss alone is not enough
- both conditions together are treated as the actionable signal

## Drosera Config

Use this `drosera.toml` shape:

```toml
ethereum_rpc = "https://ethereum-hoodi-rpc.publicnode.com"
drosera_rpc = "https://relay.hoodi.drosera.io"
eth_chain_id = 560048
drosera_address = "0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D"

[traps.oracle_guard]
path = "out/OracleManipulationTrap.sol/OracleManipulationTrap.json"
response_contract = "0x774f48dC24Bf18F6E5088BC5d240565e203355e9"
response_function = "executeResponse(bytes)"
block_sample_size = 5
cooldown_period_blocks = 20
min_number_of_operators = 3
max_number_of_operators = 7
private_trap = false
whitelist = []
```

Notes:

- `response_contract` should point to the current responder address.
- the live Trap address is used in the Drosera apply/register step after deployment.

## Cooldown

`cooldown_period_blocks = 20` is the mock-production default.

A cooldown of `1` may be useful for fast demos, but it should be treated as testnet-only because it can cause repeated response attempts while the condition remains true.

## Relayer Assumption

The responder requires the actual on-chain caller to match its configured `relayer`.

That relayer should be the operator-side EOA that submits `executeResponse(bytes)`, not the Drosera RPC URL:

```text
https://relay.hoodi.drosera.io
```

If the relayer is configured incorrectly:

- the Trap can still detect correctly
- response execution will revert

## Local Validation

Current local result:

```text
11 tests passed, 0 failed
```

Covered cases:

- real `collect()` decoding against local mocks
- malformed sample data does not revert
- spike plus liquidity-drop detection
- crash plus liquidity-drop detection
- no false positive on normal operation
- price spike without liquidity drop does not trigger
- liquidity drop alone does not trigger
- alert on read failure
- alert on stale oracle
- wrong relayer fails and correct relayer succeeds
- responder cooldown blocks a second incident

Run locally with:

```bash
forge test -vvv
```

## Deployment Status

All four deployed contracts were verified successfully on Sourcify with `exact_match` status:

- AMMOracle
- MockProductionLendingPool
- DroseraResponder
- OracleManipulationTrap

The final trap was then redeployed with the correct hardcoded Hoodi oracle and pool addresses.

## Summary

This repository demonstrates a production-like Drosera monitoring pattern for DeFi security: detect combined oracle manipulation and liquidity-drain behavior, separate actionable responses from alert-only conditions, and pause the vulnerable pool through an idempotent, cooldown-protected, relayer-gated responder.
