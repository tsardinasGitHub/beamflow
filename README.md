# BEAMFlow Orchestrator ⚡

**A Distributed, Fault-Tolerant Workflow Engine built with Elixir/OTP & Mnesia.**

[![Elixir](https://img.shields.io/badge/Elixir-1.15-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-LiveView-orange.svg)](https://www.phoenixframework.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 📖 Introduction

**BEAMFlow** is a showcase project demonstrating how to build a **resilient, self-healing distributed system** on the BEAM (Erlang VM). Unlike traditional workflow engines that rely on external databases (Postgres/Redis) for state, BEAMFlow leverages **OTP Actors (GenServer)** for execution and **Mnesia** for real-time distributed persistence.

It includes a **"Chaos Mode"** that intentionally kills processes to demonstrate the supervision tree's ability to recover state and resume workflows without data loss.

---

## 🏗 Architecture

The system follows a **Reactive Actor Model** architecture:

graph TD
    A[Client API] -->|Start Workflow| B(WorkflowDispatcher)
    B -->|Spawn| C{PartitionSupervisor}
    C -->|Manage| D[WorkflowActor (GenServer)]
    D -->|Persist State| E[(Mnesia Distributed DB)]
    D -->|Emit Events| F[Phoenix PubSub]
    F -->|Update| G[LiveView Dashboard]
    
    subgraph "Chaos Engineering"
        H[ChaosMonkey] -.->|Random Kill| D
    end### Key Components

1.  **WorkflowActor (GenServer):** Each active workflow is an isolated process. If it crashes, it affects *only* that workflow.
2.  **Mnesia Cluster:** State is replicated across nodes in real-time. If a node dies, others take over.
3.  **LiveView Dashboard:** Visualizes 10,000+ concurrent workflows in real-time using Telemetry metrics.

---

## 🚀 Features

-   **Massive Concurrency:** Handles thousands of simultaneous workflows.
-   **Fault Tolerance:** Supervision Trees ensure processes restart automatically upon failure.
-   **Distributed State:** Data is consistent across the cluster (NoSQL/Mnesia).
-   **Chaos Engineering:** Built-in "Chaos Mode" to simulate production failures (network partition, process crash).
-   **Backoff & Retries:** Automatic retry logic with exponential backoff for integration steps.

---

## 🛠 Installation & Usage

### Prerequisites
-   Elixir 1.15+
-   Erlang/OTP 26+

### 1. Clone and Setup
git clone https://github.com/tsardinasGitHub/beamflow.git
cd beamflow
mix deps.get### 2. Run the Cluster
Start the application in an IEx shell:
iex -S mix phx.server### 3. Access the Dashboard
Open `http://localhost:4000` to see the Real-Time Workflow Dashboard.

### 4. Unleash Chaos 💥
Toggle the **"Enable Chaos Mode"** switch in the UI. You will see processes crashing in the logs, but the "Success Rate" metric will remain stable as OTP recovers them.

---

## 🧪 Testing

Run the test suite, which includes property-based testing for the engine logic:

mix test## 📄 License
MIT
