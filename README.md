# 🛡 Drosera-Native Security: Oracle Manipulation Guard

A decentralized security simulation built on the Drosera-inspired trap architecture that detects and responds to **oracle manipulation attacks in DeFi protocols in real time**.

This project demonstrates how modular “Trap + Responder” systems can act as an **adaptive security layer for lending protocols**, replacing static threshold-based guards with state-aware anomaly detection.

---

## 🧠 Core Idea

Traditional DeFi security systems rely on fixed rules like price thresholds or admin-triggered pauses.

This system introduces a **state-driven security layer** that continuously analyzes on-chain behavior:

* Tracks short-term market history using a rolling window
* Detects abnormal oracle price movement patterns
* Monitors liquidity (TVL) changes alongside price shifts
* Triggers automated response when anomalies align

---

## 🏗 System Architecture

The system is composed of three core contracts:

---

### 1. 🏦 Protocol Layer — `LendingPool`

A collateral-based lending protocol dependent on an external AMM oracle for pricing.

* Users deposit ETH as collateral
* Borrowing power is calculated using oracle price
* Includes `Pausable` + emergency shutdown capability
* Vulnerable by design to oracle manipulation

---

### 2. 🧠 Detection Layer — `OracleManipulationTrap`

Implements the `ITrap` interface and performs anomaly detection.

It works by analyzing a **5-block rolling observation window**:

* Captures oracle price per block
* Captures protocol TVL per block
* Computes a moving average baseline
* Detects deviation from expected price behavior

---

### 3. ⚡ Response Layer — `DroseraResponder`

Acts as the execution bridge between detection and protocol enforcement.

* Receives encoded trigger payloads (`abi.encode(pool)`)
* Validates that the pool is approved
* Calls `emergencyPause()` on the affected pool
* Prevents repeated execution if already paused

---

## 🛡 Security Logic (Trap Design)

Instead of static thresholds, detection is based on **temporal pattern analysis**.

---

### 📊 Observation Phase (`collect`)

Each block snapshot records:

* Oracle price from `AMMOracle`
* Current pool TVL
* Block number for ordering validation

These are encoded into `CollectOutput` and stored off-chain in a rolling buffer.

---

### 🔍 Detection Phase (`shouldRespond`)

The trap evaluates a 5-sample window and verifies:

* All samples belong to the same pool
* Block ordering is valid (no tampering or reordering)
* No zero-value corruption in price or TVL

It then computes:

* **Moving average price baseline**
* **TVL percentage drop**
* **Current price deviation**

---

### 🚨 Trigger Conditions

The system triggers only when BOTH conditions are met:

* **Price anomaly**

  * Current price is > 5× average baseline OR < 1/5 of baseline

* **Liquidity stress**

  * TVL drops by more than 10% in the observation window

If both conditions match:

```solidity
return (true, abi.encode(current.pool));
```

---

## 🚀 Technical Components

* `AMMOracle.sol` → Constant product AMM price simulation
* `LendingPool.sol` → Collateralized lending protocol
* `OracleManipulationTrap.sol` → Anomaly detection engine
* `DroseraResponder.sol` → Execution bridge for emergency response

---

## 🔁 System Flow

1. **Data Collection**

   * Trap collects price + TVL snapshots each block

2. **State Buffering**

   * Test environment simulates a rolling 5-block history

3. **Attack Simulation**

   * Oracle is manipulated via swap
   * Borrowing becomes artificially inflated

4. **Detection**

   * Trap detects abnormal deviation + liquidity shift

5. **Response**

   * Responder executes `emergencyPause()`
   * Lending pool is frozen before further damage

---

## ⚙️ Prerequisites

* Foundry: [https://book.getfoundry.sh/getting-started/installation](https://book.getfoundry.sh/getting-started/installation)
* Solidity ^0.8.19

---

## 📦 Setup & Installation

```bash
git clone https://github.com/ComputerWizzy-Icon/drosera-oracle-guard-demo.git
cd drosera-oracle-guard-demo

forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

---

## 🧪 Testing

The test suite simulates a full attack lifecycle:

### 1. Baseline Phase

* 5 blocks of normal market activity

### 2. Attack Phase

* Oracle price is heavily manipulated
* Borrow power becomes inflated

### 3. Detection Phase

* Trap detects abnormal price + TVL divergence

### 4. Response Phase

* Responder pauses the pool

---

## ▶️ Run Tests

```bash
forge test --match-path test/AttackSimulation.t.sol -vv
```

---

## 💡 Why This Design Matters

### 🔐 1. Event-Driven Security

Security is not static. It reacts to **state changes over time**, not single-point thresholds.

### ⚡ 2. Lightweight On-Chain Logic

Heavy computation is avoided by using off-chain buffering + minimal on-chain validation.

### 🧠 3. Multi-Signal Detection

Combines:

* price movement
* liquidity shifts
* temporal consistency

This reduces false positives compared to single-metric systems.

---

## 🌍 Vision

This project demonstrates a shift from:

> Static DeFi security models

to:

> Continuous, state-aware protocol defense systems

---

## 📄 License

MIT

---
