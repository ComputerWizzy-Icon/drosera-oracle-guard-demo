# 🛡 Drosera Oracle Manipulation Guard

A production-oriented security trap built on the [Drosera](https://drosera.io) decentralized monitoring network that detects and responds to **oracle manipulation attacks in DeFi lending protocols**.

Deployed and active on the **Hoodi testnet** (chain ID 560048).

---

## 🧠 Core Idea

Traditional DeFi security relies on fixed rules — price thresholds or admin-triggered pauses that require human intervention.

This system implements a **Drosera-native Trap + Responder architecture** that continuously monitors on-chain state:

- Tracks oracle price across a rolling 5-block window
- Computes a **historical baseline** from past samples (excluding the current block)
- Monitors TVL changes alongside price movement
- Triggers an automated emergency pause when both anomalies align simultaneously

The key insight: price manipulation and liquidity drain must **both** be detected together to trigger a response, reducing false positives from noise or normal volatility.

---

## 🏗 Architecture

### Deployed Contracts (Hoodi Testnet)

| Contract | Address |
|---|---|
| AMMOracle | `0x264F7AaaB41513f893a924e3327E924017b57328` |
| LendingPool | `0x1BFc89dF7a3D78C36D8F57493bd5026d09DaDe31` |
| DroseraResponder | `0xe0a5c1474f95e626f713c2Add464D4EC231e3747` |

---

### 1. 🏦 Protocol Layer — `LendingPool`

A collateral-based ETH lending protocol that uses an external AMM oracle for pricing.

- Users deposit ETH as collateral
- Borrow power = `collateral × price × 75%` (COLLATERAL_FACTOR_BPS = 7500)
- Tracks per-user `collateral` and `debt` mappings
- Includes `repay()` and `withdrawCollateral()` with solvency checks
- Owner-controlled liquidity funding via `fundLiquidity()`
- `Pausable` — can be frozen by the responder via `emergencyPause()`

> **Known limitations (demo scope):** no liquidations, no interest accrual, no oracle staleness checks, no multisig operations.

---

### 2. 🔍 Detection Layer — `OracleManipulationTrap`

Implements the `ITrap` interface for the Drosera network.

**Drosera compatibility:**
- No constructor arguments — addresses are hardcoded by `block.chainid`
- `collect()` is a pure view function — no state writes
- `shouldRespond()` is `pure` — operates only on the encoded sample data

**How detection works:**

`collect()` snapshots per block:


{ pool, oracle, price, tvl, blockNumber }


`shouldRespond()` receives 5 contiguous block samples and:

1. Validates all samples reference the same pool + oracle pair
2. Enforces **exactly contiguous** block ordering (`data[i-1].blockNumber == data[i].blockNumber + 1`)
3. Computes baseline from **historical samples only** (indices 1–4, excluding current block) — this is critical so a manipulated current price doesn't inflate the baseline it's measured against
4. Triggers if **both** conditions are true:
   - Price spike: `current.price > baseline × 5` OR crash: `current.price < baseline / 5`
   - TVL drop: current TVL is more than 10% below historical average

---

### 3. ⚡ Response Layer — `DroseraResponder`

Execution bridge between Drosera detection and protocol enforcement.

- `Ownable` — owner can rotate the relayer and approve/revoke pools
- Pool allowlist — only approved pools can be paused
- **Idempotent** — if pool is already paused, `executeResponse()` returns without reverting
- Emits `ResponseExecuted` on successful pause

---

## 🚨 Trigger Conditions

Both must be true simultaneously:



(price > baselinePrice × 5  OR  price < baselinePrice / 5)
AND
TVL drop from historical average > 10%


Baseline is computed from blocks `N-1` through `N-4` only — the current block is excluded to prevent a manipulated price from contaminating its own detection baseline.

---

## 🔁 Attack Flow



Normal blocks (100-103)     Attack block (104)
price = 1e18 × 4            swap1For0(9000 ETH) → price = 100e18
TVL   = 100 ETH × 4         borrow(15 ETH)      → TVL = 86 ETH
baseline price = 1e18
spike check:  100e18 > 1e18 × 5 = 5e18  ✓
TVL drop:     (100 - 86) / 100 = 14% > 10%  ✓
→ shouldRespond returns (true, abi.encode(pool))
→ DroseraResponder.executeResponse(pool)
→ LendingPool.emergencyPause()
→ pool.paused() == true


---

## 🗂 Project Structure



src/
├── interfaces/
│   └── ITrap.sol                  # Drosera trap interface
├── AMMOracle.sol                  # Constant product AMM (bidirectional swap)
├── LendingPool.sol                # Collateralized lending protocol
├── OracleManipulationTrap.sol     # Drosera trap — detection engine
└── DroseraResponder.sol           # Response executor
test/
└── AttackSimulation.t.sol         # Full attack lifecycle test
script/
└── Deploy.s.sol                   # Deployment script
drosera.toml                       # Drosera network configuration


---

## ⚙️ Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity ^0.8.19
- Hoodi testnet ETH ([faucet](https://faucet.hoodi.ethpandaops.io))

---

## 📦 Setup

```bash
git clone https://github.com/ComputerWizzy-Icon/drosera-oracle-guard-demo.git
cd drosera-oracle-guard-demo

forge install OpenZeppelin/openzeppelin-contracts --no-commit


Create a .env file:

PRIVATE_KEY=0x...
RPC_URL=https://ethereum-hoodi-rpc.publicnode.com
RELAYER_ADDRESS=0x14e424df0c35686CF58fC7D05860689041D300F6


🧪 Run Tests

forge test --match-path test/AttackSimulation.t.sol -vvv


Expected output:

[PASS] test_attack_detected_and_stopped() (gas: 855304)


The test verifies:
	1.	Baseline — 4 blocks of normal price and TVL
	2.	Attack — price pumped 100× via swap1For0, 15 ETH borrowed
	3.	Detection — trap fires on price spike + TVL drop
	4.	Response — pool paused via responder
	5.	Idempotence — second executeResponse call does not revert

🚀 Deploy

source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify


After deploying, update the hardcoded addresses in OracleManipulationTrap.sol:

ORACLE = 0x<deployed oracle>;
POOL   = 0x<deployed pool>;


Then rebuild and apply the trap to Drosera:

forge build
drosera apply


⚙️ Drosera Configuration (drosera.toml)

RPC_URL = "https://ethereum-hoodi-rpc.publicnode.com"
drosera_rpc = "https://relay.hoodi.drosera.io"

eth_chain_id = 560048
drosera_address = "0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D"

[traps.oracle_guard]
path = "out/OracleManipulationTrap.sol/OracleManipulationTrap.json"
response_contract = "0xe0a5c1474f95e626f713c2Add464D4EC231e3747"
response_function = "executeResponse(address)"
block_sample_size = 5
cooldown_period_blocks = 1
min_number_of_operators = 3
max_number_of_operators = 7
private_trap = true
whitelist = [
  "0x14e424df0c35686CF58fC7D05860689041D300F6"
]


cooldown_period_blocks = 1 — reduced from 2 because emergencyPause is idempotent; repeated calls are safe.

🔮 What’s Not Yet Production-Ready
As noted in review, the following are out of scope for this demo but required for mainnet:
	•	Liquidation engine
	•	Full multi-asset collateral accounting
	•	Interest accrual
	•	Oracle hardening and staleness checks
	•	Multisig operational model for owner functions
	•	Comprehensive invariant and fuzz test suite
	•	Relayer and responder uptime monitoring
	•	Incident recovery and unpause process

📄 License
MIT