defmodule Beamflow.Engine.Saga do
  @moduledoc """
  Saga Pattern implementation for managing distributed transactions with compensations.

  ## El Problema

  Cuando un workflow ejecuta múltiples steps que modifican estado externo
  (base de datos, APIs, servicios), un fallo en un step intermedio puede
  dejar el sistema en un estado inconsistente:

  ```
  Step 1: Debitar cuenta     ✅ (dinero ya salió)
  Step 2: Reservar producto  ✅ (producto reservado)
  Step 3: Enviar email       ❌ (FALLA - servicio caído)
  ```

  Sin compensación, el cliente perdió dinero y el producto quedó reservado
  sin confirmación.

  ## La Solución: Saga Pattern

  Cada step define una acción de compensación que revierte su efecto:

  ```elixir
  defmodule DebitAccount do
    use Beamflow.Engine.Saga

    @impl true
    def execute(context, opts) do
      # Debitar cuenta
      {:ok, %{transaction_id: tx_id}}
    end

    @impl true
    def compensate(context, opts) do
      # Revertir: acreditar la cuenta
      CreditAccount.execute(context, opts)
    end
  end
  ```

  ## Modos de Ejecución

  ### 1. Compensación Automática (recomendado)
  El WorkflowActor ejecuta compensaciones automáticamente cuando un step falla.

  ### 2. Compensación Manual
  Para casos donde necesitas control fino:

  ```elixir
  Saga.run([
    {DebitAccount, [amount: 100]},
    {ReserveProduct, [product_id: "P123"]},
    {SendEmail, [to: "user@example.com"]}
  ], context)
  ```

  Si SendEmail falla, automáticamente ejecuta:
  1. ReserveProduct.compensate/2
  2. DebitAccount.compensate/2

  ## Garantías

  - **Eventual Consistency**: Las compensaciones aseguran consistencia eventual
  - **Idempotencia**: Las compensaciones deben ser idempotentes
  - **Best Effort**: Si una compensación falla, se registra y continúa con las demás
  """

  require Logger

  alias Beamflow.Engine.Error

  # =============================================================================
  # Behaviour Definition
  # =============================================================================

  @doc """
  Executes the step's main action.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback execute(context :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Compensates (reverts) the step's action.

  This is called when a subsequent step fails and the saga needs to rollback.
  Should be idempotent - safe to call multiple times.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  Compensation failures are logged but don't stop other compensations.
  """
  @callback compensate(context :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Optional: Returns metadata about the compensation.

  Override this to provide custom compensation metadata like:
  - `:compensation_timeout` - How long to wait for compensation
  - `:retry_compensation` - Whether to retry failed compensations
  - `:critical` - If true, abort all compensations on failure
  """
  @callback compensation_metadata() :: map()

  @optional_callbacks [compensation_metadata: 0, execute: 2]

  # =============================================================================
  # Use Macro
  # =============================================================================

  @doc """
  Use this module in a step to enable saga compensation.

  ## Options

    * `:compensate_with` - Module that handles compensation (optional, defaults to self)
    * `:compensation_timeout` - Timeout for compensation in ms (default: 30_000)
    * `:retry_compensation` - Whether to retry failed compensations (default: false)

  ## Examples

      defmodule DebitAccount do
        use Beamflow.Engine.Saga

        @impl true
        def execute(context, opts) do
          # Main action
        end

        @impl true
        def compensate(context, opts) do
          # Rollback action
        end
      end

      # With custom compensation module
      defmodule DebitAccount do
        use Beamflow.Engine.Saga, compensate_with: CreditAccount
      end
  """
  defmacro __using__(opts) do
    compensate_with = Keyword.get(opts, :compensate_with)
    compensation_timeout = Keyword.get(opts, :compensation_timeout, 30_000)
    retry_compensation = Keyword.get(opts, :retry_compensation, false)

    quote do
      @behaviour Beamflow.Engine.Saga

      @doc false
      def __saga_enabled__, do: true

      @doc false
      def __compensation_module__ do
        unquote(compensate_with) || __MODULE__
      end

      @doc false
      def __compensation_timeout__, do: unquote(compensation_timeout)

      @doc false
      def __retry_compensation__, do: unquote(retry_compensation)

      # Default implementation - no-op compensation
      @impl Beamflow.Engine.Saga
      def compensate(_context, _opts) do
        {:ok, :no_compensation_needed}
      end

      @impl Beamflow.Engine.Saga
      def compensation_metadata do
        %{
          compensation_module: __compensation_module__(),
          compensation_timeout: __compensation_timeout__(),
          retry_compensation: __retry_compensation__()
        }
      end

      defoverridable compensate: 2, compensation_metadata: 0
    end
  end

  # =============================================================================
  # Types
  # =============================================================================

  @type step :: {module(), keyword()} | module()
  @type executed_step :: %{
          module: module(),
          opts: keyword(),
          result: term(),
          executed_at: DateTime.t()
        }
  @type compensation_result :: {:ok, term()} | {:error, term()}

  @type saga_result ::
          {:ok, [executed_step()]}
          | {:error, term(), [executed_step()], [compensation_result()]}

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Runs a saga - a sequence of steps with automatic compensation on failure.

  ## Parameters

    * `steps` - List of steps to execute. Each step is either:
      - A module: `MyStep`
      - A tuple: `{MyStep, [option: value]}`
    * `initial_context` - Initial context passed to each step
    * `opts` - Options:
      - `:on_compensate` - Callback `fn module, result -> ... end` called after each compensation
      - `:parallel_compensation` - Execute compensations in parallel (default: false)
      - `:stop_on_compensation_failure` - Stop if a compensation fails (default: false)

  ## Returns

    * `{:ok, executed_steps}` - All steps succeeded
    * `{:error, reason, executed_steps, compensation_results}` - A step failed, compensations executed

  ## Examples

      Saga.run([
        {DebitAccount, [amount: 100]},
        {ReserveProduct, [product_id: "P123"]},
        SendConfirmationEmail
      ], %{user_id: "U001"})
  """
  @spec run([step()], map(), keyword()) :: saga_result()
  def run(steps, initial_context, opts \\ []) do
    steps
    |> normalize_steps()
    |> execute_steps(initial_context, [], opts)
  end

  @doc """
  Compensates a list of executed steps in reverse order.

  This is typically called automatically by `run/3`, but can be used manually
  for custom compensation scenarios.

  ## Parameters

    * `executed_steps` - List of executed steps (from most recent to oldest)
    * `context` - Current context
    * `opts` - Options (same as `run/3`)

  ## Examples

      # Manual compensation
      {:ok, executed} = Saga.run(steps, context)
      # ... something external fails ...
      Saga.compensate(executed, context)
  """
  @spec compensate([executed_step()], map(), keyword()) :: [compensation_result()]
  def compensate(executed_steps, context, opts \\ []) do
    on_compensate = Keyword.get(opts, :on_compensate)
    parallel = Keyword.get(opts, :parallel_compensation, false)
    stop_on_failure = Keyword.get(opts, :stop_on_compensation_failure, false)

    # Reverse to compensate in LIFO order
    steps_to_compensate = Enum.reverse(executed_steps)

    if parallel do
      compensate_parallel(steps_to_compensate, context, on_compensate)
    else
      compensate_sequential(steps_to_compensate, context, on_compensate, stop_on_failure)
    end
  end

  @doc """
  Checks if a module has saga compensation enabled.

  ## Examples

      Saga.saga_enabled?(DebitAccount)
      # => true

      Saga.saga_enabled?(RegularStep)
      # => false
  """
  @spec saga_enabled?(module()) :: boolean()
  def saga_enabled?(module) do
    function_exported?(module, :__saga_enabled__, 0) &&
      module.__saga_enabled__()
  end

  @doc """
  Gets the compensation module for a step.

  Returns the module that should handle compensation.
  """
  @spec compensation_module(module()) :: module()
  def compensation_module(module) do
    if function_exported?(module, :__compensation_module__, 0) do
      module.__compensation_module__()
    else
      module
    end
  end

  @doc """
  Creates an executed step record.

  Useful for building custom saga orchestration.
  """
  @spec record_execution(module(), keyword(), term()) :: executed_step()
  def record_execution(module, opts, result) do
    %{
      module: module,
      opts: opts,
      result: result,
      executed_at: DateTime.utc_now()
    }
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp normalize_steps(steps) do
    Enum.map(steps, fn
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end)
  end

  defp execute_steps([], _context, executed, _opts) do
    {:ok, Enum.reverse(executed)}
  end

  defp execute_steps([{module, step_opts} | rest], context, executed, opts) do
    Logger.debug("Saga: Executing step #{inspect(module)}")

    case execute_step(module, context, step_opts) do
      {:ok, result} ->
        executed_step = record_execution(module, step_opts, result)
        # Merge result into context for next step
        new_context = merge_result(context, result)
        execute_steps(rest, new_context, [executed_step | executed], opts)

      {:error, reason} = error ->
        Logger.warning(
          "Saga: Step #{inspect(module)} failed with #{inspect(reason)}, compensating..."
        )

        compensation_results = compensate(executed, context, opts)

        {:error, error, Enum.reverse(executed), compensation_results}
    end
  end

  defp execute_step(module, context, opts) do
    if function_exported?(module, :execute, 2) do
      module.execute(context, opts)
    else
      # Try to call the step as a regular step with run/2
      if function_exported?(module, :run, 2) do
        module.run(context, opts)
      else
        {:error, {:no_execute_function, module}}
      end
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception)}
  end

  defp compensate_sequential([], _context, _callback, _stop_on_failure) do
    []
  end

  defp compensate_sequential([step | rest], context, callback, stop_on_failure) do
    result = execute_compensation(step, context)

    if callback, do: callback.(step.module, result)

    case result do
      {:error, _} when stop_on_failure ->
        Logger.error("Saga: Compensation failed and stop_on_failure is true, aborting")
        [result]

      _ ->
        [result | compensate_sequential(rest, context, callback, stop_on_failure)]
    end
  end

  defp compensate_parallel(steps, context, callback) do
    steps
    |> Task.async_stream(
      fn step ->
        result = execute_compensation(step, context)
        if callback, do: callback.(step.module, result)
        result
      end,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:compensation_timeout, reason}}
    end)
  end

  defp execute_compensation(step, context) do
    module = step.module
    comp_module = compensation_module(module)
    opts = step.opts

    Logger.debug("Saga: Compensating #{inspect(module)} via #{inspect(comp_module)}")

    timeout =
      if function_exported?(module, :__compensation_timeout__, 0) do
        module.__compensation_timeout__()
      else
        30_000
      end

    task =
      Task.async(fn ->
        comp_module.compensate(context, opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        Logger.debug("Saga: Compensation for #{inspect(module)} succeeded")
        {:ok, result}

      {:ok, {:error, reason}} ->
        Logger.warning("Saga: Compensation for #{inspect(module)} failed: #{inspect(reason)}")
        {:error, reason}

      nil ->
        Logger.error("Saga: Compensation for #{inspect(module)} timed out")
        {:error, :compensation_timeout}
    end
  rescue
    exception ->
      Logger.error(
        "Saga: Compensation for #{inspect(step.module)} raised: #{Exception.message(exception)}"
      )

      {:error, Error.from_exception(exception)}
  end

  defp merge_result(context, result) when is_map(result) do
    Map.merge(context, result)
  end

  defp merge_result(context, _result), do: context
end
