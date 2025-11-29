# BEAMFlow Orchestrator ⚡

**A Distributed, Fault-Tolerant Workflow Engine built with Elixir/OTP & Amnesia (Mnesia DSL).**

[![Elixir](https://img.shields.io/badge/Elixir-1.16-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-LiveView-orange.svg)](https://www.phoenixframework.org/)
[![Tests](https://img.shields.io/badge/Tests-381%20passing-brightgreen.svg)]()
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 📖 Introduction

**BEAMFlow** is a showcase project demonstrating how to build a **resilient, self-healing distributed system** on the BEAM (Erlang VM). Unlike traditional workflow engines that rely on external databases (Postgres/Redis) for state, BEAMFlow leverages **OTP Actors (GenServer)** for execution and **Mnesia** for real-time distributed persistence.

### ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🔄 **Auto-recovery** | Processes that crash restart automatically via supervision trees |
| 📊 **Real-time Dashboard** | LiveView UI updates instantly without page refresh |
| 🎯 **Saga Pattern** | Automatic compensations when something fails |
| 💥 **Chaos Engineering** | Built-in fault injection to test resilience |
| 🎬 **Visual Debugger** | "Rewind" workflows to see exactly what happened |
| 📈 **Analytics** | KPIs, trends, and data export (CSV/JSON) |

---

## 🖥️ Dashboard

BEAMFlow includes a comprehensive visual dashboard:

<!-- Screenshots: Run `mix run scripts/demo_setup.exs` then capture these views -->

| View | Description | Screenshot |
|------|-------------|------------|
| **Explorer** | List and filter workflows in real-time | [View](docs/images/dashboard-explorer.png) |
| **Details** | Event timeline with retry history | [View](docs/images/dashboard-details.png) |
| **Graph** | Interactive SVG workflow visualization | [View](docs/images/dashboard-graph.png) |
| **Analytics** | KPIs, trends, and data export | [View](docs/images/dashboard-analytics.png) |
| **Demo Mode** | Generate test workflows from UI | [http://localhost:4000/demo](http://localhost:4000/demo) |

> 📸 *Para generar datos de demo: visita `/demo` o ejecuta `mix run scripts/demo_setup.exs --count 15`*

### Replay Mode 🎬

The replay mode allows you to "rewind" any workflow to see exactly how it evolved over time - ideal for debugging, post-mortems, and demos.

<!-- TODO: Add GIF showing replay in action -->
<!-- ![Replay Mode Demo](docs/images/replay-mode.gif) -->

**Controls:**
- ▶️ Play/Pause - Automatic playback
- ⏪ Rewind - Jump to start
- ◀️▶️ Step - Navigate one event at a time
- 🎚️ Slider - Jump to any point
- ⏱️ Speed - 0.5x to 4x playback speed

> 💡 *See [DEMO_GUIDE.md](docs/DEMO_GUIDE.md) for a complete walkthrough*

---

## 🏗 Architecture

The system follows a **Reactive Actor Model** architecture:

graph TD
    A[Client API] -->|Start Workflow| B(WorkflowDispatcher)
    B -->|Spawn| C{PartitionSupervisor}
    C -->|Manage| D[WorkflowActor (GenServer)]
    D -->|Persist State| E[(Amnesia/Mnesia DB)]
    D -->|Emit Events| F[Phoenix PubSub]
    F -->|Update| G[LiveView Dashboard]
    
    subgraph "Chaos Engineering"
        H[ChaosMonkey] -.->|Random Kill| D
    end### Key Components

1.  **WorkflowActor (GenServer):** Each active workflow is an isolated process. If it crashes, it affects *only* that workflow.
2.  **Amnesia/Mnesia Cluster:** State is replicated across nodes in real-time via Amnesia DSL wrapper. If a node dies, others take over.
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
```bash
git clone https://github.com/tsardinasGitHub/beamflow.git
cd beamflow
mix deps.get
```

### 2. Initialize Database (Amnesia/Mnesia)
The database initializes automatically on application start. For manual initialization or reset:
```bash
# IMPORTANTE: Usar --sname para persistencia en disco
iex --sname beamflow -S mix run -e "Beamflow.Database.Setup.init()"
```

This command:
- Creates the Amnesia/Mnesia schema on the current node
- Initializes 4 tables: `Workflow`, `Event`, `Idempotency`, `DeadLetterEntry`
- Uses `disc_copies` for persistence when running with a named node
- Only needs to be run once (subsequent runs will skip if already exists)

> **Nota sobre persistencia:**
> - Con nodo nombrado (`--sname`): Los datos persisten en disco (`.mnesia/`)
> - Sin nodo nombrado: Los datos se almacenan solo en RAM y se pierden al reiniciar

### 3. Run the Cluster
Start the application in an IEx shell:
```bash
# Con persistencia en disco (recomendado)
iex --sname beamflow -S mix phx.server

# Sin persistencia (solo RAM, para desarrollo rápido)
iex -S mix phx.server
```

### 4. Access the Dashboard
Open `http://localhost:4000` to see the Real-Time Workflow Dashboard.

### 5. Quick Demo Setup 🚀

**Option A: From the UI (Recommended for evaluators)**

Navigate to `http://localhost:4000/demo` to:
- Generate workflows with one click
- Toggle Chaos Mode visually
- See real-time statistics

**Option B: From terminal**
```bash
# Create 10 demo workflows
mix run scripts/demo_setup.exs

# Create 20 workflows with chaos mode enabled
mix run scripts/demo_setup.exs --count 20 --chaos

# See all options
mix run scripts/demo_setup.exs --help
```

### 6. Run QA Checks (Optional)
```bash
# Verify all system components
mix run scripts/qa_check.exs

# Verbose mode
mix run scripts/qa_check.exs --verbose

# Check only API endpoints
mix run scripts/qa_check.exs --section api
```

### 6. Unleash Chaos 💥
Toggle the **"Enable Chaos Mode"** switch in the UI or via IEx:
```elixir
Beamflow.Chaos.ChaosMonkey.start(:moderate)
```
You will see processes crashing in the logs, but the "Success Rate" metric will remain stable as OTP recovers them.

---

## 🧪 Testing

Run the test suite, which includes property-based testing for the engine logic:

```bash
mix test
```

### Workflow Audit

BEAMFlow includes a static analysis tool for workflows, similar to Credo:

```bash
# Basic audit
mix beamflow.audit

# Strict mode (reduced complexity thresholds)
mix beamflow.audit --strict

# Paranoid mode (for financial/healthcare domains)
mix beamflow.audit --paranoid

# Pedantic mode (any branch without :default is an error)
mix beamflow.audit --pedantic

# JSON output for CI integration
mix beamflow.audit --format json
```

The audit checks for:
- Branches without `:default` handlers (potential dead ends)
- Excessive branch complexity (>5 options)
- Unreachable nodes in the workflow graph
- Invalid edge references

Exit codes:
- `0`: No errors (may have warnings)
- `1`: One or more errors found

---

## 📊 REST API

BEAMFlow exposes a REST API for programmatic access to analytics:

```bash
# Health check (no rate limit)
curl http://localhost:4000/api/health
# => {"status":"ok","timestamp":"2025-11-28T12:00:00Z"}

# Summary KPIs
curl http://localhost:4000/api/analytics/summary
# => {"total":150,"completed":142,"failed":8,"success_rate":94.67}

# Trend data for charts
curl http://localhost:4000/api/analytics/trends
# => {"hourly_distribution":[...],"daily_trend":[...]}

# Export data
curl http://localhost:4000/api/analytics/export?format=json
# => Full workflow data as JSON

curl http://localhost:4000/api/analytics/export?format=csv
# => CSV download
```

### Rate Limiting

API endpoints (except `/api/health`) are rate limited to **60 requests per minute per IP**.

Response headers include:
- `X-RateLimit-Limit: 60`
- `X-RateLimit-Remaining: 59`
- `X-RateLimit-Reset: 1732800000`

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [GUIA_TECNICA_EDUCATIVA.md](docs/GUIA_TECNICA_EDUCATIVA.md) | 📖 Complete technical guide for students |
| [DEMO_GUIDE.md](docs/DEMO_GUIDE.md) | Quick demo walkthrough for evaluators |
| [QA_CHECKLIST.md](docs/QA_CHECKLIST.md) | Manual testing checklist |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | Development setup and tooling |
| [ADRs](docs/adr/) | Architecture Decision Records |

---

## 📄 License
MIT
