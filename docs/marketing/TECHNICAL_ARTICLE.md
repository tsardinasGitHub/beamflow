# Building Fault-Tolerant Workflow Engines with Elixir/OTP

> A deep dive into BeamFlow: patterns, architecture decisions, and lessons learned.

---

## The Problem: Workflows That Actually Fail

Picture this: You're building an insurance onboarding system. A customer submits their application, and your system needs to:

1. Validate their identity
2. Check their credit history
3. Calculate the premium
4. Reserve the policy
5. Send confirmation email
6. Notify billing system

Everything works fine in development. Then production happens.

```
Step 1: Validate identity    ✅
Step 2: Check credit         ✅
Step 3: Calculate premium    ✅
Step 4: Reserve policy       ✅
Step 5: Send email           ❌ (SMTP server timeout)
```

Now what? The customer's policy is reserved, their credit was checked, but they never got confirmation. Your database says "completed," but it's not. You've got inconsistent state.

**This is the problem BeamFlow solves.**

---

## Why Elixir? (Spoiler: It's the BEAM)

Before diving into patterns, let's talk about why Elixir is uniquely suited for this problem.

The BEAM (Erlang VM) was designed by Ericsson in the 1980s for telephone switches. Requirements:
- **99.9999999% uptime** (nine nines = 31ms downtime per year)
- **Hot code upgrades** (can't reboot a phone switch)
- **Millions of concurrent connections** (phone calls)

These requirements map perfectly to workflow orchestration:
- Workflows must not lose state
- System must handle thousands of concurrent workflows
- Failures must be isolated and recoverable

### The Secret Sauce: Lightweight Processes

```elixir
# This spawns a new process (not an OS thread!)
# Each process is ~2KB of memory
spawn(fn -> do_work() end)

# You can have MILLIONS running simultaneously
for i <- 1..1_000_000 do
  spawn(fn -> Process.sleep(:infinity) end)
end
# This actually works. Try it.
```

In BeamFlow, every workflow is its own process. If one crashes, others are completely unaffected.

---

## Pattern 1: The Actor Model (GenServer)

Every workflow in BeamFlow is a GenServer—a process that:
- Maintains state
- Responds to messages
- Can be supervised

```elixir
defmodule Beamflow.Engine.WorkflowActor do
  use GenServer

  # State includes: current step, workflow data, status
  defstruct [:workflow_id, :current_step, :status, :data]

  def handle_call(:execute_next_step, _from, state) do
    case execute_step(state.current_step, state.data) do
      {:ok, new_data} ->
        new_state = %{state | 
          current_step: state.current_step + 1,
          data: new_data
        }
        {:reply, :ok, new_state}
        
      {:error, reason} ->
        # Trigger compensation
        {:reply, {:error, reason}, state}
    end
  end
end
```

**Why this matters**: Each workflow is isolated. A bug in workflow A cannot crash workflow B.

---

## Pattern 2: Supervision Trees ("Let It Crash")

Instead of defensive programming everywhere, OTP says: "Let processes crash, and have supervisors restart them."

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Beamflow.Supervisor                              │
│                         │                                           │
│    ┌──────────────┬─────┴─────┬───────────────┐                    │
│    │              │           │               │                    │
│    ▼              ▼           ▼               ▼                    │
│ PubSub      AlertSystem   DeadLetterQueue  WorkflowSupervisor     │
│                                                   │                │
│                                          ┌────────┼────────┐       │
│                                          │        │        │       │
│                                          ▼        ▼        ▼       │
│                                       Actor    Actor    Actor     │
│                                       (wf-1)   (wf-2)   (wf-3)    │
└─────────────────────────────────────────────────────────────────────┘
```

```elixir
defmodule Beamflow.Engine.WorkflowSupervisor do
  use DynamicSupervisor

  def start_workflow(workflow_module, id, params) do
    DynamicSupervisor.start_child(__MODULE__, %{
      id: WorkflowActor,
      start: {WorkflowActor, :start_link, [workflow_module, id, params]},
      restart: :transient  # Restart if crashes abnormally
    })
  end
end
```

**The beauty**: If a WorkflowActor crashes mid-execution, the supervisor restarts it. The actor can then check Mnesia for its last persisted state and resume.

---

## Pattern 3: Saga with Compensations

Remember our email failure? The Saga pattern solves this by defining compensations:

```elixir
defmodule ReservePolicy do
  use Beamflow.Engine.Saga

  @impl true
  def execute(%{customer_id: id, plan: plan} = state) do
    case PolicyService.reserve(id, plan) do
      {:ok, reservation_id} ->
        {:ok, Map.put(state, :reservation_id, reservation_id)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def compensate(%{reservation_id: id} = state, _opts) do
    # UNDO: Cancel the reservation
    PolicyService.cancel(id)
    {:ok, state}
  end
end
```

When step 5 (email) fails, BeamFlow automatically:
1. Calls `SendEmail.compensate/2` (if defined)
2. Calls `ReservePolicy.compensate/2` (cancels reservation)
3. Calls `CalculatePremium.compensate/2`
4. ...and so on, in reverse order

**Result**: System returns to consistent state.

---

## Pattern 4: Circuit Breaker

What if the email service is down for 10 minutes? Do you keep trying and timing out?

Circuit Breaker pattern:

```
CLOSED (normal) ──[5 failures]──► OPEN (reject all)
      ▲                                  │
      │                            [30s timeout]
      │                                  │
      └───────[success]─── HALF-OPEN ◄───┘
                           (try one)
```

```elixir
case CircuitBreaker.call(:email_service, fn -> 
  EmailAPI.send(email) 
end) do
  {:ok, response} -> 
    handle_success(response)
    
  {:error, :circuit_open} -> 
    # Don't even try—service is known to be down
    # Queue for later or use fallback
    queue_for_retry(email)
    
  {:error, reason} -> 
    handle_error(reason)
end
```

BeamFlow tracks failures per service and automatically opens circuits when thresholds are exceeded.

---

## Pattern 5: Dead Letter Queue

Some failures are permanent. After N retries with exponential backoff, the workflow goes to the DLQ:

```elixir
# After all retries exhausted
DeadLetterQueue.enqueue(%{
  type: :workflow_failed,
  workflow_id: "wf-123",
  failed_step: SendEmail,
  error: {:smtp_error, :invalid_recipient},
  context: workflow_state,
  retry_count: 5
})
```

Operators can then:
- Inspect the failure
- Fix the underlying issue
- Retry or resolve manually

---

## The Visual Debugger: "What Happened?"

One of BeamFlow's killer features is the **Replay Mode**. Every event is stored:

```elixir
# Events stored in Mnesia
:workflow_started
:step_started  
:step_completed
:step_failed
:compensation_started
:workflow_completed
```

The UI can then "replay" the workflow:

```
Timeline: ═══════════════════════════════════════════►
          │         │           │         │
          ▼         ▼           ▼         ▼
        Start    Step 1     Step 2    Step 3 FAIL
                Complete   Complete   
                                       │
                                       ▼
                               Compensation ←──┐
                                       │       │
                                       ▼       │
                               Compensation ───┘
```

This is invaluable for debugging production issues.

---

## Chaos Engineering: Breaking Things on Purpose

Netflix popularized Chaos Engineering with their Chaos Monkey. BeamFlow has one built-in:

```elixir
# Activate chaos mode
ChaosMonkey.start(:moderate)

# Profile definitions
:gentle    # 5% crash probability
:moderate  # 15% crash probability  
:aggressive # 30% crash probability

# Types of faults injected
- Random process crashes
- Artificial latency (50-500ms)
- Simulated errors
- Timeout simulation
```

**Why?** To verify that:
- Supervisors restart crashed processes
- Sagas correctly compensate
- Circuit breakers trip appropriately
- DLQ captures irrecoverable failures

---

## Lessons Learned

### 1. Event Sourcing Is Worth It

Storing events instead of just state seems like overhead, but:
- Debugging becomes trivial
- Replay mode is free
- Audit trail comes automatically

### 2. Supervision Hierarchies Require Thought

Not all processes should restart the same way:
- `:permanent` - Always restart
- `:temporary` - Never restart
- `:transient` - Restart only on abnormal exit

BeamFlow uses `:transient` for workflow actors—we don't want to restart a completed workflow.

### 3. Idempotency Is Non-Negotiable

Every step must be safe to retry:

```elixir
def execute(%{idempotency_key: key} = state) do
  case check_already_executed(key) do
    {:ok, cached_result} -> 
      {:ok, cached_result}  # Return cached, don't re-execute
    :not_found -> 
      do_actual_work(state)
  end
end
```

### 4. Visual Tools Change Everything

The time invested in LiveView dashboard paid off 10x in debugging and demos.

---

## What's Next?

BeamFlow is open source and actively developed. Future plans:

- **AI Agent Orchestration**: LLM pipelines with automatic retry
- **Python/TypeScript SDKs**: Define workflows in popular languages
- **Cloud Offering**: Managed version for those who don't want to operate

---

## Try It Yourself

```bash
git clone https://github.com/tsardinasGitHub/beamflow
cd beamflow
mix deps.get
mix test  # 334 tests
mix phx.server
# Visit http://localhost:4000
```

**Resources:**
- [GitHub Repository](https://github.com/tsardinasGitHub/beamflow)
- [Architecture Decision Records](docs/adr/)
- [Educational Guide (Spanish)](docs/GUIA_TECNICA_EDUCATIVA.md)

---

*Built with ❤️ and a lot of ☕ using Elixir, Phoenix LiveView, and OTP.*

---

## About the Author

[Tu nombre] is a software engineer passionate about distributed systems and functional programming. Currently exploring the intersection of AI and fault-tolerant systems.

[LinkedIn] | [GitHub] | [Twitter/X]
