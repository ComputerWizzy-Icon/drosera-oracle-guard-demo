# 🛡 Drosera Oracle Manipulation Guard (Production-Ready Demo)

A DeFi security monitoring system built on the **Drosera network** that detects **oracle manipulation + liquidity drain attacks** and automatically triggers protocol protection.

Deployed on **Hoodi Testnet (Chain ID: 560048)**  
All contracts verified and fully test-covered (5/5 passing).

---

## 🧠 Core Idea

This system protects a lending protocol from **composite DeFi attacks**:

> Price manipulation alone is not enough.  
> Liquidity drain alone is not enough.  
> **Both together = confirmed attack.**

It uses a **Drosera Trap + Responder architecture**:

- Samples 5 consecutive blocks
- Builds baseline from previous 4 blocks
- Detects abnormal price movement + TVL collapse
- Requires operator consensus (Drosera network)
- Automatically pauses the lending pool when attack is confirmed

---

## 🏗 Deployed Architecture (Hoodi Testnet)

### ✅ Live Contracts

| Contract                  | Address                                      |
|--------------------------|----------------------------------------------|
| AMMOracle                | `0x41b3616b40e50aD0f3d5e28E74c89325a4f4fFFf` |
| MockProductionLendingPool| `0x5e7Eb055331905b1DA8e1aEA8F692E7F45074144` |
| DroseraResponder         | `0x533435C16e2d59A4EE3B5E807C22a4716B6285C8` |
| OracleManipulationTrap   | `0x26C8Dca81557EC11faDFDF1F8EF726aeBDf9CcBa` |

---

## 🔍 System Design

---

## 1. 📈 AMM Oracle (Price Engine)

A constant product AMM:

- `reserve0 * reserve1 = k`
- Price = `reserve1 / reserve0`

Supports:

- `swap0For1()` → price increases
- `swap1For0()` → price decreases

Used to simulate real oracle manipulation attacks.

---

## 2. 🏦 Lending Pool (Target Protocol)

`MockProductionLendingPool` is a production-grade lending simulation.

### Core mechanics:

- ETH collateral lending system
- Borrow limit:

```

maxBorrow = collateralValue × 75%

```

- TVL model:

```

getTvl() = accountedLiquidity - totalBorrows
(minimum 0)

````

- Interest accrual per block (WAD-based model)

---

### 🔐 Safety Systems

- Oracle staleness protection (1 hour max)
- ReentrancyGuard protection
- Pausable via Drosera responder
- Solvency checks on borrow + withdraw
- Interest-index based debt tracking
- Liquidity accounting correctness

---

## 3. 🚨 Drosera Responder (Execution Layer)

Handles confirmed attack responses from Drosera relayer.

### Flow:

1. Receives encoded payload
2. Validates:
   - Pool is approved
   - Reason is valid attack type
3. Executes:

```solidity
pool.emergencyPause();
````

---

### Response Payload

```solidity
struct ResponsePayload {
    address pool;
    Reason reason;
    uint256 currentPrice;
    uint256 baselinePrice;
    uint256 currentTvl;
    uint256 baselineTvl;
    uint256 currentBlockNumber;
}
```

---

### Attack Reasons

* PriceSpikeAndTvlDrop
* PriceCrashAndTvlDrop

---

### Design Properties

* Idempotent execution (safe replay resistant)
* Relayer-restricted execution
* Pool whitelist enforcement
* Emergency-only control path

---

## 4. 🧠 Oracle Manipulation Trap (Core Engine)

This is the **security brain** of the system.

---

## 📦 Data Collection

Each snapshot:

```solidity
struct CollectOutput {
    address pool;
    address oracle;
    uint256 price;
    uint256 tvl;
    bool paused;
    uint256 blockNumber;
}
```

---

## 📊 Baseline Logic (Critical Design)

Uses last 4 blocks:

```
baselinePrice = avg(block[1..4].price)
baselineTvl   = avg(block[1..4].tvl)
```

✔ Current block excluded intentionally
✔ Strict 5-block sliding window validation

---

## 🚨 Trigger Conditions

All must be true:

---

### 1. TVL Drop (Mandatory)

```
TVL drop ≥ 10%
```

---

### 2. Price Anomaly

Either:

#### Spike:

```
currentPrice ≥ baseline × 5
```

#### Crash:

```
currentPrice ≤ baseline ÷ 5
```

---

### 3. Strict Block Continuity

```
block[i] = block[i-1] + 1
```

No gaps allowed.

---

### 4. Baseline Safety

Reject if:

* baselinePrice < 1e12
* baselineTvl < 1 ether

---

### 5. Extreme Detection Path

Early trigger if:

* ≥10x price spike/crash
* ≥25% TVL drop

---

## 🧾 Response Output

When triggered:

```solidity
return (true, abi.encode(ResponsePayload));
```

---

## 🧪 Attack Simulation (Tested Scenario)

### Normal state:

```
price = 1e18
tvl = 100 ETH
```

---

### Attack:

```solidity
oracle.swap1For0(4000 ether);
pool.borrow(50 ether);
```

---

### Result:

```
price spikes
TVL drops
```

---

### Detection Chain:

* Price anomaly ✔
* TVL drop ✔
* Clean history ✔

➡ Trap triggers

---

### Response Flow:

```
Drosera consensus (3 operators)
        ↓
DroseraResponder.executeResponse()
        ↓
LendingPool.emergencyPause()
```

---

## 🧪 Test Coverage (5/5 PASSING)

* ✔ Spike + TVL drop triggers trap
* ✔ Crash + drain triggers trap
* ✔ Spike alone rejected
* ✔ TVL drop alone rejected
* ✔ Normal operation passes safely

---

## 🔧 Deployment Flow

1. Deploy AMMOracle
2. Deploy Lending Pool
3. Fund liquidity (0.05 ETH)
4. Deploy Responder
5. Link responder → pool
6. Deploy Trap
7. Configure Drosera network

---

## 📡 Drosera Config (UPDATED)

```toml
block_sample_size = 5
cooldown_period_blocks = 1

min_number_of_operators = 3
max_number_of_operators = 7

response_function = "executeResponse(bytes)"
response_contract = "0x533435C16e2d59A4EE3B5E807C22a4716B6285C8"

private_trap = false
whitelist = []
```

---

## 🔐 Key Design Decisions

### ✔ Correctness

* Baseline excludes current block
* Strict contiguous history validation
* TVL floor protection for stable baselines

### ✔ Security Model

* Price alone cannot trigger response
* TVL drop is mandatory condition
* Multi-condition anomaly detection

### ✔ Decentralization

* 3+ operator consensus
* Relayer-separated execution layer
* No centralized trigger authority

### ✔ Safety

* Idempotent responder
* Pool approval gating
* Replay-safe execution

---

## ⚠️ Limitations

* No real liquidation engine yet
* Single oracle (AMM-based only)
* No TWAP / time-weighted pricing
* Simplified lending model

---

## 🚀 Roadmap

* Chainlink / Pyth oracle integration
* Multi-oracle consensus system
* Full liquidation engine
* MEV-resistant oracle layer
* Cross-chain deployment
* Operator slashing system

---

## 🧠 One-line Summary

A decentralized DeFi security system that detects oracle manipulation and liquidity drains in real time, and autonomously pauses vulnerable lending pools using Drosera consensus.
