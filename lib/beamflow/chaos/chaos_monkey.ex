defmodule Beamflow.Chaos.ChaosMonkey do
  @moduledoc """
  Chaos Monkey para BEAMFlow - Inyección de fallos controlada.

  Este módulo implementa un sistema de chaos engineering que permite:
  - Inyectar fallos aleatorios en steps de workflows
  - Simular timeouts y crashes de procesos
  - Validar que el sistema se recupera correctamente
  - Verificar la idempotencia de las operaciones

  ## Arquitectura

  ```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                         ChaosMonkey System                               │
  │                                                                         │
  │  ┌───────────────┐    ┌────────────────┐    ┌───────────────────────┐  │
  │  │  ChaosMonkey  │───►│ FaultInjector  │───►│  Affected Processes   │  │
  │  │  (GenServer)  │    │                │    │  - WorkflowActors     │  │
  │  │               │    │  Injects:      │    │  - Steps              │  │
  │  │  Config:      │    │  - Crashes     │    │  - CircuitBreakers    │  │
  │  │  - Profiles   │    │  - Timeouts    │    │                       │  │
  │  │  - Schedules  │    │  - Errors      │    └───────────────────────┘  │
  │  │  - Targets    │    │  - Latency     │                               │
  │  └───────────────┘    └────────────────┘                               │
  │                              │                                          │
  │                              ▼                                          │
  │                     ┌────────────────┐                                  │
  │                     │  ChaosReport   │                                  │
  │                     │  - Events      │                                  │
  │                     │  - Recoveries  │                                  │
  │                     │  - Metrics     │                                  │
  │                     └────────────────┘                                  │
  └─────────────────────────────────────────────────────────────────────────┘
  ```

  ## Perfiles de Chaos

  - `:gentle` - Baja probabilidad de fallos, ideal para demo
  - `:moderate` - Probabilidad media, testing funcional
  - `:aggressive` - Alta probabilidad, stress testing
  - `:custom` - Configuración personalizada

  ## Uso

      # Iniciar chaos mode
      ChaosMonkey.start()

      # Parar chaos mode
      ChaosMonkey.stop()

      # Cambiar perfil
      ChaosMonkey.set_profile(:aggressive)

      # Inyectar fallo específico
      ChaosMonkey.inject(:crash, target: :random_workflow)

      # Ver estadísticas
      ChaosMonkey.stats()

  ## Seguridad

  ⚠️  **NUNCA habilitar en producción** - Solo para desarrollo/testing.
  El sistema verifica `Mix.env()` y rechaza ejecutarse en `:prod`.
  """

  use GenServer
  require Logger

  alias Beamflow.Engine.{WorkflowActor, AlertSystem}

  @type fault_type :: :crash | :timeout | :error | :latency | :compensation_fail
  @type profile :: :gentle | :moderate | :aggressive | :custom
  @type target :: :random_workflow | :random_step | :circuit_breaker | :all

  @profiles %{
    gentle: %{
      crash_probability: 0.05,
      timeout_probability: 0.03,
      error_probability: 0.08,
      latency_probability: 0.10,
      compensation_fail_probability: 0.02,
      latency_range_ms: 100..500,
      interval_ms: 10_000,
      max_events_per_interval: 1
    },
    moderate: %{
      crash_probability: 0.15,
      timeout_probability: 0.10,
      error_probability: 0.20,
      latency_probability: 0.25,
      compensation_fail_probability: 0.08,
      latency_range_ms: 200..2_000,
      interval_ms: 5_000,
      max_events_per_interval: 3
    },
    aggressive: %{
      crash_probability: 0.30,
      timeout_probability: 0.20,
      error_probability: 0.35,
      latency_probability: 0.40,
      compensation_fail_probability: 0.15,
      latency_range_ms: 500..5_000,
      interval_ms: 2_000,
      max_events_per_interval: 5
    }
  }

  defstruct [
    :profile,
    :config,
    :enabled,
    :started_at,
    :timer_ref,
    events: [],
    recoveries: [],
    stats: %{
      total_injections: 0,
      crashes: 0,
      timeouts: 0,
      errors: 0,
      latencies: 0,
      compensation_failures: 0,
      successful_recoveries: 0,
      failed_recoveries: 0
    }
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Inicia el ChaosMonkey. Solo funciona en entornos no-producción.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Activa el chaos mode con el perfil especificado.
  """
  @spec start(profile()) :: :ok | {:error, :production_env}
  def start(profile \\ :gentle) do
    GenServer.call(__MODULE__, {:start_chaos, profile})
  end

  @doc """
  Detiene el chaos mode.
  """
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop_chaos)
  end

  @doc """
  Verifica si el chaos mode está activo.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  catch
    :exit, _ -> false
  end

  @doc """
  Cambia el perfil de chaos.
  """
  @spec set_profile(profile()) :: :ok
  def set_profile(profile) do
    GenServer.call(__MODULE__, {:set_profile, profile})
  end

  @doc """
  Inyecta un fallo específico.
  """
  @spec inject(fault_type(), keyword()) :: :ok | {:error, term()}
  def inject(fault_type, opts \\ []) do
    GenServer.call(__MODULE__, {:inject, fault_type, opts})
  end

  @doc """
  Obtiene estadísticas del chaos mode.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Obtiene los últimos eventos de chaos.
  """
  @spec events(keyword()) :: [map()]
  def events(opts \\ []) do
    GenServer.call(__MODULE__, {:events, opts})
  end

  @doc """
  Resetea las estadísticas.
  """
  @spec reset_stats() :: :ok
  def reset_stats do
    GenServer.call(__MODULE__, :reset_stats)
  end

  @doc """
  Obtiene el perfil actual y su configuración.
  """
  @spec current_profile() :: {profile(), map()}
  def current_profile do
    GenServer.call(__MODULE__, :current_profile)
  end

  @doc """
  Verifica si debería inyectar un fallo basado en probabilidad.
  Usado por steps para opt-in a chaos testing.
  """
  @spec should_fail?(fault_type()) :: boolean()
  def should_fail?(fault_type) do
    if enabled?() do
      GenServer.call(__MODULE__, {:should_fail?, fault_type})
    else
      false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Registra una recuperación exitosa (para métricas).
  """
  @spec record_recovery(String.t(), atom()) :: :ok
  def record_recovery(workflow_id, recovery_type) do
    GenServer.cast(__MODULE__, {:record_recovery, workflow_id, recovery_type})
  catch
    :exit, _ -> :ok
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    profile = Keyword.get(opts, :profile, :gentle)
    config = @profiles[profile] || @profiles[:gentle]

    state = %__MODULE__{
      profile: profile,
      config: config,
      enabled: false,
      started_at: nil
    }

    Logger.info("🐒 ChaosMonkey initialized with profile: #{profile}")

    {:ok, state}
  end

  @impl true
  def handle_call({:start_chaos, profile}, _from, state) do
    if production_env?() do
      Logger.error("🐒 ChaosMonkey REFUSED to start in production environment!")
      {:reply, {:error, :production_env}, state}
    else
      config = @profiles[profile] || @profiles[:gentle]

      new_state = %{state |
        enabled: true,
        profile: profile,
        config: config,
        started_at: DateTime.utc_now(),
        timer_ref: schedule_chaos_event(config.interval_ms)
      }

      Logger.warning("🐒 ChaosMonkey ACTIVATED! Profile: #{profile}")
      AlertSystem.send_alert(%{
        severity: :high,
        type: :chaos_mode,
        title: "Chaos Mode Activated",
        message: "ChaosMonkey started with profile: #{profile}",
        metadata: %{profile: profile, config: config}
      })

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_chaos, _from, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    new_state = %{state |
      enabled: false,
      timer_ref: nil
    }

    Logger.info("🐒 ChaosMonkey DEACTIVATED")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  @impl true
  def handle_call({:set_profile, profile}, _from, state) do
    config = @profiles[profile] || state.config

    new_state = %{state |
      profile: profile,
      config: config
    }

    Logger.info("🐒 ChaosMonkey profile changed to: #{profile}")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:inject, fault_type, opts}, _from, state) do
    if state.enabled do
      target = Keyword.get(opts, :target, :random_workflow)
      result = inject_fault(fault_type, target, state)
      {:reply, result, update_stats(state, fault_type)}
    else
      {:reply, {:error, :chaos_not_enabled}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.merge(state.stats, %{
      enabled: state.enabled,
      profile: state.profile,
      started_at: state.started_at,
      uptime_seconds: calculate_uptime(state),
      recent_events: Enum.take(state.events, 10)
    })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:events, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    events = Enum.take(state.events, limit)
    {:reply, events, state}
  end

  @impl true
  def handle_call(:reset_stats, _from, state) do
    new_state = %{state |
      stats: %{
        total_injections: 0,
        crashes: 0,
        timeouts: 0,
        errors: 0,
        latencies: 0,
        compensation_failures: 0,
        successful_recoveries: 0,
        failed_recoveries: 0
      },
      events: [],
      recoveries: []
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:current_profile, _from, state) do
    {:reply, {state.profile, state.config}, state}
  end

  @impl true
  def handle_call({:should_fail?, fault_type}, _from, state) do
    probability = get_probability(fault_type, state.config)
    should_fail = :rand.uniform() < probability
    {:reply, should_fail, state}
  end

  @impl true
  def handle_cast({:record_recovery, workflow_id, recovery_type}, state) do
    recovery = %{
      workflow_id: workflow_id,
      recovery_type: recovery_type,
      timestamp: DateTime.utc_now()
    }

    new_stats = Map.update!(state.stats, :successful_recoveries, &(&1 + 1))
    new_state = %{state |
      stats: new_stats,
      recoveries: [recovery | Enum.take(state.recoveries, 99)]
    }

    Logger.info("🐒 Recovery recorded: #{workflow_id} via #{recovery_type}")

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:chaos_tick, state) do
    if state.enabled do
      new_state = execute_chaos_round(state)
      timer_ref = schedule_chaos_event(state.config.interval_ms)
      {:noreply, %{new_state | timer_ref: timer_ref}}
    else
      {:noreply, state}
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp production_env? do
    Application.get_env(:beamflow, :env) == :prod or
      (function_exported?(Mix, :env, 0) and Mix.env() == :prod)
  end

  defp schedule_chaos_event(interval_ms) do
    Process.send_after(self(), :chaos_tick, interval_ms)
  end

  defp execute_chaos_round(state) do
    max_events = state.config.max_events_per_interval
    fault_types = [:crash, :timeout, :error, :latency, :compensation_fail]

    # Seleccionar aleatoriamente qué tipos de fallo inyectar
    events_to_inject = for _ <- 1..max_events,
                           :rand.uniform() < 0.5,
                           do: Enum.random(fault_types)

    Enum.reduce(events_to_inject, state, fn fault_type, acc ->
      if should_inject?(fault_type, acc.config) do
        inject_fault(fault_type, :random_workflow, acc)
        update_stats_with_event(acc, fault_type)
      else
        acc
      end
    end)
  end

  defp should_inject?(fault_type, config) do
    probability = get_probability(fault_type, config)
    :rand.uniform() < probability
  end

  defp get_probability(fault_type, config) do
    case fault_type do
      :crash -> config.crash_probability
      :timeout -> config.timeout_probability
      :error -> config.error_probability
      :latency -> config.latency_probability
      :compensation_fail -> config.compensation_fail_probability
      _ -> 0.0
    end
  end

  defp inject_fault(fault_type, target, state) do
    case {fault_type, target} do
      {:crash, :random_workflow} ->
        inject_crash_to_random_workflow()

      {:timeout, :random_workflow} ->
        inject_timeout_to_random_workflow(state.config.latency_range_ms)

      {:error, :random_workflow} ->
        inject_error_to_random_workflow()

      {:latency, :random_workflow} ->
        inject_latency_to_random_workflow(state.config.latency_range_ms)

      {:compensation_fail, :random_workflow} ->
        inject_compensation_failure()

      {_, :all} ->
        inject_fault_to_all(fault_type, state)

      _ ->
        Logger.debug("🐒 Unknown fault injection: #{fault_type}/#{target}")
        :ok
    end
  end

  defp inject_crash_to_random_workflow do
    case get_random_workflow_pid() do
      nil ->
        Logger.debug("🐒 No workflows to crash")
        :ok

      pid ->
        workflow_id = get_workflow_id(pid)
        Logger.warning("🐒 CRASH injected into workflow: #{workflow_id}")

        # Registrar antes de matar
        record_chaos_event(:crash, workflow_id)

        # Enviar exit signal
        Process.exit(pid, :chaos_monkey_kill)
        :ok
    end
  end

  defp inject_timeout_to_random_workflow(latency_range) do
    case get_random_workflow_pid() do
      nil ->
        :ok

      pid ->
        workflow_id = get_workflow_id(pid)
        delay = Enum.random(latency_range)
        Logger.warning("🐒 TIMEOUT (#{delay}ms) injected into workflow: #{workflow_id}")
        record_chaos_event(:timeout, workflow_id, %{delay_ms: delay})

        # Enviar mensaje de simular timeout
        send(pid, {:chaos_timeout, delay})
        :ok
    end
  end

  defp inject_error_to_random_workflow do
    case get_random_workflow_pid() do
      nil ->
        :ok

      pid ->
        workflow_id = get_workflow_id(pid)
        error_type = Enum.random([:database_error, :network_error, :validation_error, :internal_error])
        Logger.warning("🐒 ERROR (#{error_type}) injected into workflow: #{workflow_id}")
        record_chaos_event(:error, workflow_id, %{error_type: error_type})

        send(pid, {:chaos_error, error_type})
        :ok
    end
  end

  defp inject_latency_to_random_workflow(latency_range) do
    case get_random_workflow_pid() do
      nil ->
        :ok

      pid ->
        workflow_id = get_workflow_id(pid)
        delay = Enum.random(latency_range)
        Logger.info("🐒 LATENCY (#{delay}ms) injected into workflow: #{workflow_id}")
        record_chaos_event(:latency, workflow_id, %{delay_ms: delay})

        send(pid, {:chaos_latency, delay})
        :ok
    end
  end

  defp inject_compensation_failure do
    # Este flag será leído por el Saga cuando ejecute compensaciones
    :persistent_term.put(:chaos_compensation_fail, true)
    Logger.warning("🐒 COMPENSATION FAILURE flag set - next compensation will fail")
    record_chaos_event(:compensation_fail, "global", %{})

    # Limpiar después de un tiempo
    Process.send_after(self(), :clear_compensation_fail, 5_000)
    :ok
  end

  defp inject_fault_to_all(fault_type, state) do
    workflows = get_all_workflow_pids()

    Enum.each(workflows, fn pid ->
      inject_fault(fault_type, {:specific, pid}, state)
    end)

    :ok
  end

  defp get_random_workflow_pid do
    case Registry.select(Beamflow.WorkflowRegistry, [{{:"$1", :"$2", :_}, [], [:"$2"]}]) do
      [] -> nil
      pids -> Enum.random(pids)
    end
  catch
    _, _ -> nil
  end

  defp get_all_workflow_pids do
    Registry.select(Beamflow.WorkflowRegistry, [{{:"$1", :"$2", :_}, [], [:"$2"]}])
  catch
    _, _ -> []
  end

  defp get_workflow_id(pid) do
    case Registry.keys(Beamflow.WorkflowRegistry, pid) do
      [id | _] -> id
      [] -> "unknown"
    end
  catch
    _, _ -> "unknown"
  end

  defp record_chaos_event(type, target, metadata \\ %{}) do
    event = %{
      id: generate_event_id(),
      type: type,
      target: target,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    # Broadcast via PubSub para UI
    Phoenix.PubSub.broadcast(
      Beamflow.PubSub,
      "chaos:events",
      {:chaos_event, event}
    )

    event
  end

  defp generate_event_id do
    "chaos_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp update_stats(state, fault_type) do
    key = fault_type_to_stat_key(fault_type)

    new_stats = state.stats
    |> Map.update!(:total_injections, &(&1 + 1))
    |> Map.update!(key, &(&1 + 1))

    %{state | stats: new_stats}
  end

  defp update_stats_with_event(state, fault_type) do
    event = %{
      type: fault_type,
      timestamp: DateTime.utc_now()
    }

    state
    |> update_stats(fault_type)
    |> Map.update!(:events, fn events -> [event | Enum.take(events, 99)] end)
  end

  defp fault_type_to_stat_key(:crash), do: :crashes
  defp fault_type_to_stat_key(:timeout), do: :timeouts
  defp fault_type_to_stat_key(:error), do: :errors
  defp fault_type_to_stat_key(:latency), do: :latencies
  defp fault_type_to_stat_key(:compensation_fail), do: :compensation_failures
  defp fault_type_to_stat_key(_), do: :errors

  defp calculate_uptime(%{started_at: nil}), do: 0
  defp calculate_uptime(%{started_at: started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end
end
