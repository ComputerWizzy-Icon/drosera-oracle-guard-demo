# 🛡 Drosera-Native Security: Oracle Manipulation Guard

A **production-grade autonomous security system** built on the Drosera Network that detects and mitigates **oracle manipulation attacks in real time**.

This project demonstrates how decentralized “Traps” can act as a **live security layer for DeFi protocols**, replacing static guards with adaptive, state-aware detection logic.

---

## 🧠 Core Idea

Traditional DeFi security relies on fixed rules and admin-controlled pauses.

This system introduces a **self-observing security layer** powered by Drosera:

* It continuously monitors protocol behavior
* Learns short-term market context (via rolling history)
* Detects abnormal deviations in price and liquidity
* Triggers enforcement only when consensus-backed conditions are met

---

## 🏗 System Architecture

The system is built across three coordinated layers:

### 1. 🏦 Protocol Layer — `LendingPool`

A collateralized lending protocol that depends on an external AMM oracle for asset valuation.

* Users deposit collateral and borrow against it
* Vulnerable to oracle manipulation attacks
* Includes a controlled `Pausable` mechanism for emergency response

---

### 2. 🧠 Detection Layer — `OracleManipulationTrap`

The core intelligence module implementing the Drosera `ITrap` interface.

It performs **on-chain anomaly detection using historical state analysis**:

* Maintains a rolling **5-block observation window**
* Computes a **moving average price baseline**
* Tracks protocol **TVL (Total Value Locked)** changes

---

### 3. ⚡ Enforcement Layer — `DroseraResponder`

Acts as the execution gateway between Drosera consensus and the protocol.

* Receives verified trigger signals from the Drosera network
* Executes emergency actions (e.g., pausing the protocol)
* Ensures only authorized consensus-driven responses are executed

---

## 🛡 Security Logic (The Trap)

Instead of simple threshold checks, this system uses **temporal pattern analysis**.

### 📊 Observation Phase (`collect`)

Each block snapshot captures:

* Oracle price
* Protocol TVL

These are stored in a rolling buffer for analysis.

---

### 🔍 Detection Phase (`shouldRespond`)

The Trap evaluates a **5-block rolling window** to distinguish:

* natural volatility
  vs
* malicious manipulation

---

### 🚨 Trigger Conditions

The system responds only when strong anomalies occur:

* **Price Spike Detection**

  * Current price exceeds **500% of moving average**

* **TVL Drain Detection**

  * Protocol TVL drops by **more than 20%** within the observation window

---

## 🚀 Technical Components

* **`AMMOracle.sol`** → Simulated manipulatable price feed
* **`LendingPool.sol`** → Core lending protocol with emergency pause control
* **`OracleManipulationTrap.sol`** → Detection engine (moving average anomaly detection)
* **`DroseraResponder.sol`** → Execution bridge for Drosera-driven enforcement

---

### 🔗 Data Flow & Calldata Mapping

The system uses a precise byte-handshake between the Detection and Enforcement layers:

1. **Trigger:** When `shouldRespond` returns `true`, it encodes the target `LendingPool` address into `bytes responseCalldata` using `abi.encode(pool)`.
2. **Relay:** The Drosera Network captures this bytes payload and passes it to the `DroseraResponder`.
3. **Execution:** The `DroseraResponder` receives the payload in its `executeResponse(address target)` function.
4. **Action:** The Responder decodes the payload and calls `LendingPool(target).emergencyPause()`.

This architecture ensures the Trap can dynamically specify which pool needs protection without hardcoding addresses in the Responder.

---

## ⚙️ Prerequisites

* Foundry → [https://book.getfoundry.sh/getting-started/installation](https://book.getfoundry.sh/getting-started/installation)
* Solidity ^0.8.19

---

## 📦 Setup & Installation

```bash
# Clone repository
git clone <your-repo-link>
cd drosera-demo

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

---

## 🧪 Simulation & Testing

The test suite simulates a full oracle manipulation attack lifecycle:

### 1. 🟢 Warm-up Phase

* 5-block stable market simulation
* Builds historical baseline for anomaly detection

### 2. 🔥 Exploit Phase

* Attacker manipulates AMM oracle price
* Attempts to drain up to 50% of protocol liquidity

### 3. 🧠 Detection Phase

* Trap analyzes rolling price + TVL data
* Detects deviation from expected behavior

### 4. ⚡ Mitigation Phase

* Drosera consensus triggers responder
* Lending pool is paused before secondary damage occurs

---

## ▶️ Run Tests

```bash
forge test --match-path test/Attack.t.sol -vv
```

---

## 💡 Why This Design Matters

### 🔐 1. Decentralized Security Enforcement

No centralized bot or admin control. Detection and response are governed by **Drosera consensus logic**.

### ⚡ 2. Low Overhead Architecture

* Protocol remains lightweight
* Heavy computation occurs in the Trap layer
* On-chain execution is minimal and efficient

### 🧠 3. Resilient Detection Model

The moving average system prevents:

* false positives
* single-block manipulation tricks
* noise-based triggers

---

## 🌍 Vision

This system demonstrates a shift from:

> “static smart contract security”

to:

> “adaptive, autonomous protocol defense systems”

---

## 📄 License

MIT

---
