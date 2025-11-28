defmodule Beamflow.Engine.CircuitBreaker do
  @moduledoc """
  Circuit Breaker pattern implementation for protecting external services.

  ## Estados del Circuit Breaker

  ```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                      Circuit Breaker States                         │
  │                                                                     │
  │    ┌──────────┐   N failures    ┌──────────┐   timeout   ┌────────┐│
  │    │  CLOSED  │───────────────►│   OPEN   │────────────►│  HALF  ││
  │    │ (normal) │                │ (reject) │             │  OPEN  ││
  │    └──────────┘                └──────────┘             └────────┘│
  │         ▲                            ▲                      │     │
  │         │ success                    │ failure              │     │
  │         └────────────────────────────┴──────────────────────┘     │
  │                                                                     │
  └─────────────────────────────────────────────────────────────────────┘
  ```

  ## Uso

      # Crear un circuit breaker para un servicio
      {:ok, _pid} = CircuitBreaker.start_link(name: :email_service)

      # Ejecutar una operación protegida
      case CircuitBreaker.call(:email_service, fn -> send_email(to, body) end) do
        {:ok, result} -> handle_success(result)
        {:error, :circuit_open} -> handle_fallback()
        {:error, reason} -> handle_error(reason)
      end

      # Verificar estado
      CircuitBreaker.status(:email_service)
      # => %{state: :closed, failures: 0, successes: 0}

  ## Configuración

      CircuitBreaker.start_link(
        name: :payment_gateway,
        failure_threshold: 5,        # Fallos para abrir el circuito
        success_threshold: 3,        # Éxitos en half-open para cerrar
        timeout: :timer.seconds(30), # Tiempo en estado open
        reset_timeout: :timer.minutes(5) # Reset de contadores si no hay actividad
      )
  """

  use GenServer

  require Logger

  # =============================================================================
  # Types
  # =============================================================================

  @type state :: :closed | :open | :half_open

  @type status :: %{
          state: state(),
          failures: non_neg_integer(),
          successes: non_neg_integer(),
          last_failure: DateTime.t() | nil,
          last_success: DateTime.t() | nil,
          opened_at: DateTime.t() | nil
        }

  @type options :: [
          name: atom(),
          failure_threshold: pos_integer(),
          success_threshold: pos_integer(),
          timeout: pos_integer(),
          reset_timeout: pos_integer(),
          on_state_change: (state(), state() -> any()) | nil
        ]

  # =============================================================================
  # Default Configuration
  # =============================================================================

  @default_failure_threshold 5
  @default_success_threshold 3
  @default_timeout :timer.seconds(30)
  @default_reset_timeout :timer.minutes(5)

  # Named breaker configurations
  @named_breakers %{
    email_service: %{
      failure_threshold: 3,
      success_threshold: 2,
      timeout: :timer.seconds(60)
    },
    payment_gateway: %{
      failure_threshold: 2,
      success_threshold: 3,
      timeout: :timer.seconds(120)
    },
    external_api: %{
      failure_threshold: 5,
      success_threshold: 2,
      timeout: :timer.seconds(30)
    },
    database: %{
      failure_threshold: 3,
      success_threshold: 1,
      timeout: :timer.seconds(10)
    }
  }

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Starts a new circuit breaker process.

  ## Options

    * `:name` - Required. The name to register the circuit breaker under.
    * `:failure_threshold` - Number of failures before opening (default: 5).
    * `:success_threshold` - Number of successes in half-open to close (default: 3).
    * `:timeout` - Time in milliseconds before transitioning from open to half-open (default: 30s).
    * `:reset_timeout` - Time without activity to reset counters (default: 5min).
    * `:on_state_change` - Optional callback `fn old_state, new_state -> ... end`.

  ## Examples

      {:ok, _pid} = CircuitBreaker.start_link(name: :my_service)

      {:ok, _pid} = CircuitBreaker.start_link(
        name: :payment_api,
        failure_threshold: 3,
        timeout: :timer.seconds(60)
      )
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  @doc """
  Gets a circuit breaker for a named configuration, starting it if needed.

  ## Named Configurations

    * `:email_service` - 3 failures, 60s timeout
    * `:payment_gateway` - 2 failures, 120s timeout
    * `:external_api` - 5 failures, 30s timeout
    * `:database` - 3 failures, 10s timeout

  ## Examples

      {:ok, pid} = CircuitBreaker.get_or_start(:email_service)
  """
  @spec get_or_start(atom()) :: {:ok, pid()} | {:error, term()}
  def get_or_start(name) do
    case lookup(name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        config = Map.get(@named_breakers, name, %{})
        opts = Map.to_list(config) ++ [name: name]

        case start_link(opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc """
  Executes a function through the circuit breaker.

  Returns `{:error, :circuit_open}` if the circuit is open.
  Otherwise, executes the function and tracks success/failure.

  ## Examples

      CircuitBreaker.call(:email_service, fn ->
        EmailClient.send(to, subject, body)
      end)

      # With timeout
      CircuitBreaker.call(:slow_service, fn -> slow_operation() end, timeout: 5000)
  """
  @spec call(atom(), (-> any()), keyword()) :: {:ok, any()} | {:error, term()}
  def call(name, fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 5000)

    case lookup(name) do
      {:ok, pid} ->
        GenServer.call(pid, {:call, fun}, timeout)

      {:error, :not_found} ->
        # Auto-start with defaults if not found
        case get_or_start(name) do
          {:ok, pid} -> GenServer.call(pid, {:call, fun}, timeout)
          error -> error
        end
    end
  end

  @doc """
  Reports a success to the circuit breaker without executing a function.

  Useful when you want manual control over success/failure reporting.
  """
  @spec report_success(atom()) :: :ok
  def report_success(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.cast(pid, :success)
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Reports a failure to the circuit breaker without executing a function.

  Useful when you want manual control over success/failure reporting.
  """
  @spec report_failure(atom(), term()) :: :ok
  def report_failure(name, _reason \\ :unknown) do
    case lookup(name) do
      {:ok, pid} -> GenServer.cast(pid, :failure)
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Gets the current status of a circuit breaker.

  ## Examples

      CircuitBreaker.status(:email_service)
      # => %{state: :closed, failures: 2, successes: 10, ...}
  """
  @spec status(atom()) :: {:ok, status()} | {:error, :not_found}
  def status(name) do
    case lookup(name) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :status)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Checks if the circuit is currently allowing requests.

  ## Examples

      if CircuitBreaker.allow?(:email_service) do
        send_email()
      else
        queue_for_later()
      end
  """
  @spec allow?(atom()) :: boolean()
  def allow?(name) do
    case status(name) do
      {:ok, %{state: :closed}} -> true
      {:ok, %{state: :half_open}} -> true
      _ -> false
    end
  end

  @doc """
  Forces the circuit breaker to a specific state.

  Useful for testing or manual intervention.

  ## Examples

      CircuitBreaker.force_state(:email_service, :open)
      CircuitBreaker.force_state(:email_service, :closed)
  """
  @spec force_state(atom(), state()) :: :ok | {:error, :not_found}
  def force_state(name, new_state) when new_state in [:closed, :open, :half_open] do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, {:force_state, new_state})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Resets the circuit breaker to its initial closed state.

  ## Examples

      CircuitBreaker.reset(:email_service)
  """
  @spec reset(atom()) :: :ok | {:error, :not_found}
  def reset(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, :reset)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Stops a circuit breaker process.
  """
  @spec stop(atom()) :: :ok
  def stop(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.stop(pid)
      {:error, :not_found} -> :ok
    end
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    state = %{
      name: name,
      state: :closed,
      failures: 0,
      successes: 0,
      last_failure: nil,
      last_success: nil,
      opened_at: nil,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      reset_timeout: Keyword.get(opts, :reset_timeout, @default_reset_timeout),
      on_state_change: Keyword.get(opts, :on_state_change),
      timeout_ref: nil,
      reset_ref: nil
    }

    Logger.info("CircuitBreaker #{name} started in :closed state")

    {:ok, state}
  end

  @impl true
  def handle_call({:call, fun}, _from, %{state: :open} = state) do
    # Check if we should transition to half-open
    if should_try_half_open?(state) do
      new_state = transition_to(state, :half_open)
      execute_and_respond(fun, new_state)
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:call, fun}, _from, state) do
    execute_and_respond(fun, state)
  end

  def handle_call(:status, _from, state) do
    status = %{
      state: state.state,
      failures: state.failures,
      successes: state.successes,
      last_failure: state.last_failure,
      last_success: state.last_success,
      opened_at: state.opened_at
    }

    {:reply, status, state}
  end

  def handle_call({:force_state, new_state}, _from, state) do
    {:reply, :ok, transition_to(state, new_state)}
  end

  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | state: :closed,
        failures: 0,
        successes: 0,
        opened_at: nil
    }

    cancel_timers(state)
    Logger.info("CircuitBreaker #{state.name} reset to :closed")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast(:success, state) do
    {:noreply, record_success(state)}
  end

  def handle_cast(:failure, state) do
    {:noreply, record_failure(state)}
  end

  @impl true
  def handle_info(:try_half_open, %{state: :open} = state) do
    Logger.info("CircuitBreaker #{state.name} timeout expired, transitioning to :half_open")
    {:noreply, transition_to(state, :half_open)}
  end

  def handle_info(:try_half_open, state) do
    # Already transitioned, ignore
    {:noreply, state}
  end

  def handle_info(:reset_counters, state) do
    Logger.debug("CircuitBreaker #{state.name} resetting counters due to inactivity")

    new_state = %{
      state
      | failures: 0,
        successes: 0,
        reset_ref: nil
    }

    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp via_tuple(name) do
    {:via, Registry, {Beamflow.CircuitBreakerRegistry, name}}
  end

  defp lookup(name) do
    case Registry.lookup(Beamflow.CircuitBreakerRegistry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp execute_and_respond(fun, state) do
    try do
      case fun.() do
        {:ok, result} ->
          new_state = record_success(state)
          {:reply, {:ok, result}, new_state}

        {:error, reason} ->
          new_state = record_failure(state)
          {:reply, {:error, reason}, new_state}

        # Non-tuple results are treated as success
        result ->
          new_state = record_success(state)
          {:reply, {:ok, result}, new_state}
      end
    rescue
      exception ->
        new_state = record_failure(state)
        {:reply, {:error, %{type: :exception, message: Exception.message(exception)}}, new_state}
    catch
      :exit, reason ->
        new_state = record_failure(state)
        {:reply, {:error, {:exit, reason}}, new_state}
    end
  end

  defp record_success(state) do
    new_state = %{
      state
      | successes: state.successes + 1,
        last_success: DateTime.utc_now()
    }

    # Schedule counter reset
    new_state = schedule_reset(new_state)

    case state.state do
      :half_open ->
        if new_state.successes >= state.success_threshold do
          transition_to(new_state, :closed)
        else
          new_state
        end

      :closed ->
        # Reset failure counter on success
        %{new_state | failures: 0}

      _ ->
        new_state
    end
  end

  defp record_failure(state) do
    new_state = %{
      state
      | failures: state.failures + 1,
        last_failure: DateTime.utc_now()
    }

    # Schedule counter reset
    new_state = schedule_reset(new_state)

    case state.state do
      :closed ->
        if new_state.failures >= state.failure_threshold do
          transition_to(new_state, :open)
        else
          new_state
        end

      :half_open ->
        # Single failure in half-open returns to open
        transition_to(new_state, :open)

      :open ->
        new_state
    end
  end

  defp transition_to(state, new_state_name) do
    old_state_name = state.state

    if old_state_name != new_state_name do
      Logger.info(
        "CircuitBreaker #{state.name} transitioning from :#{old_state_name} to :#{new_state_name}"
      )

      # Invoke callback if provided
      if state.on_state_change do
        state.on_state_change.(old_state_name, new_state_name)
      end
    end

    cancel_timers(state)

    case new_state_name do
      :open ->
        # Schedule transition to half-open
        ref = Process.send_after(self(), :try_half_open, state.timeout)

        %{
          state
          | state: :open,
            opened_at: DateTime.utc_now(),
            successes: 0,
            timeout_ref: ref
        }

      :half_open ->
        %{state | state: :half_open, successes: 0, failures: 0}

      :closed ->
        %{state | state: :closed, failures: 0, successes: 0, opened_at: nil}
    end
  end

  defp should_try_half_open?(state) do
    case state.opened_at do
      nil ->
        true

      opened_at ->
        elapsed = DateTime.diff(DateTime.utc_now(), opened_at, :millisecond)
        elapsed >= state.timeout
    end
  end

  defp schedule_reset(state) do
    # Cancel existing reset timer
    if state.reset_ref, do: Process.cancel_timer(state.reset_ref)

    ref = Process.send_after(self(), :reset_counters, state.reset_timeout)
    %{state | reset_ref: ref}
  end

  defp cancel_timers(state) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    if state.reset_ref, do: Process.cancel_timer(state.reset_ref)
  end
end
