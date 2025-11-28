defmodule Beamflow.Chaos.IdempotencyValidator do
  @moduledoc """
  Validador de idempotencia durante chaos testing.

  Este módulo verifica que las operaciones son verdaderamente idempotentes
  ejecutándolas múltiples veces y comparando resultados.

  ## Concepto

  Una operación es idempotente si ejecutarla N veces produce el mismo
  resultado que ejecutarla 1 vez. Esto es crítico para:

  - Reintentos después de fallos
  - Compensaciones de Saga
  - Recovery de crashes

  ## Uso

      # Validar que un step es idempotente
      IdempotencyValidator.validate(MyStep, initial_state)

      # Validar con múltiples ejecuciones
      IdempotencyValidator.validate(MyStep, initial_state, executions: 5)

      # Obtener reporte
      IdempotencyValidator.report()
  """

  use GenServer
  require Logger

  @type validation_result :: :idempotent | :not_idempotent | :error

  defstruct [
    validations: [],
    stats: %{
      total_validations: 0,
      idempotent: 0,
      not_idempotent: 0,
      errors: 0
    }
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Valida que un módulo de step es idempotente.

  ## Opciones

    * `:executions` - Número de ejecuciones (default: 3)
    * `:compare_fn` - Función de comparación customizada (default: ==)
    * `:timeout` - Timeout por ejecución en ms (default: 5000)

  ## Ejemplo

      {:ok, :idempotent} = IdempotencyValidator.validate(ProcessPayment, %{
        amount: 100,
        card_id: "card_123",
        idempotency_key: "unique-key-123"
      })
  """
  @spec validate(module(), map(), keyword()) :: {:ok, validation_result()} | {:error, term()}
  def validate(step_module, initial_state, opts \\ []) do
    GenServer.call(__MODULE__, {:validate, step_module, initial_state, opts}, 30_000)
  end

  @doc """
  Valida una función arbitraria es idempotente.
  """
  @spec validate_fn((-> term()), keyword()) :: {:ok, validation_result()} | {:error, term()}
  def validate_fn(fun, opts \\ []) do
    GenServer.call(__MODULE__, {:validate_fn, fun, opts}, 30_000)
  end

  @doc """
  Obtiene el reporte de validaciones.
  """
  @spec report() :: map()
  def report do
    GenServer.call(__MODULE__, :report)
  end

  @doc """
  Resetea las estadísticas.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:validate, step_module, initial_state, opts}, _from, state) do
    result = do_validate_step(step_module, initial_state, opts)
    new_state = record_validation(state, step_module, result)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:validate_fn, fun, opts}, _from, state) do
    result = do_validate_fn(fun, opts)
    new_state = record_validation(state, :anonymous_fn, result)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:report, _from, state) do
    report = %{
      stats: state.stats,
      recent_validations: Enum.take(state.validations, 20),
      idempotency_rate: calculate_rate(state.stats)
    }
    {:reply, report, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp do_validate_step(step_module, initial_state, opts) do
    executions = Keyword.get(opts, :executions, 3)
    compare_fn = Keyword.get(opts, :compare_fn, &default_compare/2)
    timeout = Keyword.get(opts, :timeout, 5_000)

    Logger.info("🔍 Validating idempotency of #{inspect(step_module)} with #{executions} executions")

    # Ejecutar el step múltiples veces
    results = for i <- 1..executions do
      Logger.debug("  Execution #{i}/#{executions}")

      task = Task.async(fn ->
        try do
          step_module.execute(initial_state)
        rescue
          e -> {:error, {:exception, e}}
        end
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    end

    analyze_results(results, compare_fn)
  end

  defp do_validate_fn(fun, opts) do
    executions = Keyword.get(opts, :executions, 3)
    compare_fn = Keyword.get(opts, :compare_fn, &default_compare/2)
    timeout = Keyword.get(opts, :timeout, 5_000)

    results = for _ <- 1..executions do
      task = Task.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, {:exception, e}}
        end
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    end

    analyze_results(results, compare_fn)
  end

  defp analyze_results(results, compare_fn) do
    # Filtrar errores de timeout
    valid_results = Enum.reject(results, fn
      {:error, :timeout} -> true
      _ -> false
    end)

    cond do
      # Todas fueron timeout
      Enum.empty?(valid_results) ->
        {:error, :all_timed_out}

      # Todas son errores
      Enum.all?(valid_results, fn
        {:error, _} -> true
        _ -> false
      end) ->
        # Verificar si los errores son consistentes (también es idempotente)
        first_error = hd(valid_results)
        if Enum.all?(valid_results, &compare_fn.(first_error, &1)) do
          Logger.info("  ✅ Idempotent (consistent error responses)")
          {:ok, :idempotent}
        else
          Logger.warning("  ❌ Not idempotent (inconsistent error responses)")
          {:ok, :not_idempotent}
        end

      # Mix de éxitos y errores
      Enum.any?(valid_results, fn
        {:error, _} -> true
        _ -> false
      end) ->
        # No determinístico - podría ser chaos o real issue
        Logger.warning("  ⚠️  Mixed results - may not be idempotent")
        {:ok, :not_idempotent}

      # Todas exitosas
      true ->
        first_result = hd(valid_results)

        # Normalizar resultados para comparación
        normalized = Enum.map(valid_results, &normalize_result/1)
        first_normalized = hd(normalized)

        if Enum.all?(normalized, &compare_fn.(first_normalized, &1)) do
          Logger.info("  ✅ Idempotent (consistent success responses)")
          {:ok, :idempotent}
        else
          Logger.warning("  ❌ Not idempotent (different success responses)")
          log_differences(normalized)
          {:ok, :not_idempotent}
        end
    end
  end

  defp normalize_result({:ok, state}) when is_map(state) do
    # Remover campos que cambian naturalmente entre ejecuciones
    state
    |> Map.drop([:timestamp, :updated_at, :created_at, :id, :uuid])
    |> Map.update(:payment_tx, nil, fn tx ->
      if is_map(tx) do
        Map.drop(tx, [:id, :created_at, :idempotency_key])
      else
        tx
      end
    end)
  end

  defp normalize_result(result), do: result

  defp default_compare(a, b), do: a == b

  defp log_differences(results) do
    Logger.debug("  Differences found:")
    [first | rest] = results

    Enum.each(rest, fn result ->
      diff = find_diff(first, result)
      unless Enum.empty?(diff) do
        Logger.debug("    #{inspect(diff)}")
      end
    end)
  end

  defp find_diff(a, b) when is_map(a) and is_map(b) do
    keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))

    Enum.reduce(keys, [], fn key, acc ->
      val_a = Map.get(a, key)
      val_b = Map.get(b, key)

      if val_a != val_b do
        [{key, {val_a, val_b}} | acc]
      else
        acc
      end
    end)
  end

  defp find_diff(a, b), do: if(a == b, do: [], else: [{:value, {a, b}}])

  defp record_validation(state, module, result) do
    validation = %{
      module: module,
      result: result,
      timestamp: DateTime.utc_now()
    }

    new_stats = state.stats
    |> Map.update!(:total_validations, &(&1 + 1))
    |> update_result_stat(result)

    %{state |
      validations: [validation | Enum.take(state.validations, 99)],
      stats: new_stats
    }
  end

  defp update_result_stat(stats, {:ok, :idempotent}), do: Map.update!(stats, :idempotent, &(&1 + 1))
  defp update_result_stat(stats, {:ok, :not_idempotent}), do: Map.update!(stats, :not_idempotent, &(&1 + 1))
  defp update_result_stat(stats, {:error, _}), do: Map.update!(stats, :errors, &(&1 + 1))
  defp update_result_stat(stats, _), do: stats

  defp calculate_rate(%{total_validations: 0}), do: 0.0
  defp calculate_rate(%{total_validations: total, idempotent: idempotent}) do
    Float.round(idempotent / total * 100, 2)
  end
end
