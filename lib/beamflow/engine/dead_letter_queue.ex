defmodule Beamflow.Engine.DeadLetterQueue do
  @moduledoc """
  Dead Letter Queue (DLQ) para workflows que fallan irrecuperablemente.

  ## Propósito

  Cuando un workflow falla y sus compensaciones también fallan (o no pueden
  ejecutarse), el workflow se envía al DLQ para:

  1. **Auditoría**: Registro completo del fallo para investigación
  2. **Reprocesamiento manual**: Operadores pueden revisar y reprocessar
  3. **Reprocesamiento automático**: Reintento programado con backoff
  4. **Alertas**: Notificación a sistemas de monitoreo

  ## Tipos de Entradas

  | Tipo | Descripción | Acción Recomendada |
  |------|-------------|-------------------|
  | `:workflow_failed` | Workflow falló después de reintentos | Revisar logs |
  | `:compensation_failed` | Compensación de un step falló | ⚠️ Intervención manual |
  | `:critical_failure` | Fallo que dejó estado inconsistente | 🚨 Urgente |

  ## Uso

      # Encolar un workflow fallido
      DeadLetterQueue.enqueue(%{
        type: :compensation_failed,
        workflow_id: "wf-123",
        workflow_module: MyWorkflow,
        failed_step: ProcessPayment,
        error: {:refund_failed, :timeout, "tx_abc"},
        context: workflow_state,
        metadata: %{attempts: 5, last_attempt: DateTime.utc_now()}
      })

      # Listar entradas pendientes
      DeadLetterQueue.list_pending()

      # Reprocesar manualmente
      DeadLetterQueue.retry(entry_id)

      # Marcar como resuelto
      DeadLetterQueue.resolve(entry_id, :manual_resolution, "Refund procesado manualmente")

  ## Almacenamiento

  Las entradas se persisten en Amnesia (Beamflow.Database.DeadLetterEntry)
  para sobrevivir reinicios. Ver ADR-005 para detalles de migración.
  """

  use GenServer
  use Amnesia

  require Logger

  alias Beamflow.Engine.AlertSystem
  alias Beamflow.Database.DeadLetterEntry

  @ets_cache :beamflow_dlq_cache

  # ============================================================================
  # Types
  # ============================================================================

  @type entry_type :: :workflow_failed | :compensation_failed | :critical_failure
  @type entry_status :: :pending | :retrying | :resolved | :abandoned

  @type entry :: %{
          id: String.t(),
          type: entry_type(),
          status: entry_status(),
          workflow_id: String.t(),
          workflow_module: module(),
          failed_step: module() | nil,
          error: term(),
          context: map(),
          metadata: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          retry_count: non_neg_integer(),
          next_retry_at: DateTime.t() | nil,
          resolution: map() | nil
        }

  @type enqueue_opts :: %{
          type: entry_type(),
          workflow_id: String.t(),
          workflow_module: module(),
          failed_step: module() | nil,
          error: term(),
          context: map(),
          metadata: map()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Dead Letter Queue server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a failed workflow or compensation for later processing.

  ## Parameters

    * `opts` - Map with:
      * `:type` - Required. One of `:workflow_failed`, `:compensation_failed`, `:critical_failure`
      * `:workflow_id` - Required. The workflow identifier
      * `:workflow_module` - Required. The workflow module
      * `:failed_step` - The step that failed (optional)
      * `:error` - The error that occurred
      * `:context` - The workflow state at time of failure
      * `:metadata` - Additional metadata

  ## Returns

    * `{:ok, entry_id}` - Entry created successfully
    * `{:error, reason}` - Failed to create entry

  ## Examples

      DeadLetterQueue.enqueue(%{
        type: :compensation_failed,
        workflow_id: "wf-123",
        workflow_module: OrderWorkflow,
        failed_step: ProcessPayment,
        error: {:refund_failed, :timeout},
        context: %{payment_tx: %{id: "tx_abc"}},
        metadata: %{original_error: :email_service_down}
      })
  """
  @spec enqueue(enqueue_opts()) :: {:ok, String.t()} | {:error, term()}
  def enqueue(opts) do
    GenServer.call(__MODULE__, {:enqueue, opts})
  end

  @doc """
  Lists all pending entries in the DLQ.

  ## Options

    * `:type` - Filter by entry type
    * `:status` - Filter by status (default: `:pending`)
    * `:limit` - Maximum entries to return (default: 100)
    * `:since` - Only entries created after this DateTime

  ## Examples

      DeadLetterQueue.list_pending()
      DeadLetterQueue.list_pending(type: :critical_failure)
      DeadLetterQueue.list_pending(status: :retrying, limit: 10)
  """
  @spec list_pending(keyword()) :: {:ok, [entry()]}
  def list_pending(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc """
  Gets a specific entry by ID.
  """
  @spec get(String.t()) :: {:ok, entry()} | {:error, :not_found}
  def get(entry_id) do
    GenServer.call(__MODULE__, {:get, entry_id})
  end

  @doc """
  Retries a DLQ entry.

  For workflow failures, this will attempt to restart the workflow.
  For compensation failures, this will attempt the compensation again.

  ## Options

    * `:force` - Retry even if max retries exceeded
    * `:delay` - Delay before retry in ms

  ## Examples

      DeadLetterQueue.retry("dlq_abc123")
      DeadLetterQueue.retry("dlq_abc123", force: true)
  """
  @spec retry(String.t(), keyword()) :: {:ok, :retrying} | {:error, term()}
  def retry(entry_id, opts \\ []) do
    GenServer.call(__MODULE__, {:retry, entry_id, opts})
  end

  @doc """
  Marks an entry as resolved.

  ## Parameters

    * `entry_id` - The entry to resolve
    * `resolution_type` - One of:
      * `:auto_resolved` - System resolved automatically
      * `:manual_resolution` - Operator resolved manually
      * `:abandoned` - Decided not to retry
      * `:compensated_externally` - Compensation done outside system
    * `notes` - Optional notes about the resolution

  ## Examples

      DeadLetterQueue.resolve("dlq_abc", :manual_resolution, "Refund issued via Stripe dashboard")
      DeadLetterQueue.resolve("dlq_xyz", :abandoned, "Customer cancelled order anyway")
  """
  @spec resolve(String.t(), atom(), String.t() | nil) :: :ok | {:error, term()}
  def resolve(entry_id, resolution_type, notes \\ nil) do
    GenServer.call(__MODULE__, {:resolve, entry_id, resolution_type, notes})
  end

  @doc """
  Gets statistics about the DLQ.

  Returns counts by type and status.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Processes entries that are due for automatic retry.

  This is typically called by a scheduler.
  """
  @spec process_due_retries() :: {:ok, non_neg_integer()}
  def process_due_retries do
    GenServer.call(__MODULE__, :process_due_retries)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Crear tabla ETS para cache rápido
    :ets.new(@ets_cache, [:named_table, :set, :public, read_concurrency: true])

    # Cargar entradas existentes en cache (desde Amnesia)
    load_into_cache()

    # Programar procesamiento automático de retries
    schedule_retry_processing()

    Logger.info("DeadLetterQueue started")

    {:ok, %{retry_timer: nil}}
  end

  @impl true
  def handle_call({:enqueue, opts}, _from, state) do
    entry = create_entry(opts)

    case persist_entry(entry) do
      :ok ->
        cache_entry(entry)

        # Enviar alerta según severidad
        send_alert(entry)

        Logger.warning("DLQ: Entry #{entry.id} created - #{entry.type} for workflow #{entry.workflow_id}")
        {:reply, {:ok, entry.id}, state}

      {:error, reason} ->
        Logger.error("DLQ: Failed to persist entry: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    entries = list_entries(opts)
    {:reply, {:ok, entries}, state}
  end

  @impl true
  def handle_call({:get, entry_id}, _from, state) do
    case get_entry(entry_id) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call({:retry, entry_id, opts}, _from, state) do
    case get_entry(entry_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        result = do_retry(entry, opts)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:resolve, entry_id, resolution_type, notes}, _from, state) do
    case get_entry(entry_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        result = do_resolve(entry, resolution_type, notes)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = calculate_stats()
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:process_due_retries, _from, state) do
    count = do_process_due_retries()
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:process_retries, state) do
    do_process_due_retries()
    schedule_retry_processing()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_entry(opts) do
    # Usar DeadLetterEntry.new/1 de Amnesia
    DeadLetterEntry.new(%{
      type: opts[:type] || opts.type,
      workflow_id: opts[:workflow_id] || opts.workflow_id,
      workflow_module: opts[:workflow_module] || opts.workflow_module,
      failed_step: opts[:failed_step],
      error: opts[:error],
      context: opts[:context] || %{},
      original_params: opts[:original_params] || %{},
      metadata: opts[:metadata] || %{}
    })
  end

  defp persist_entry(entry) do
    Amnesia.transaction do
      DeadLetterEntry.write(entry)
    end
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_into_cache do
    Amnesia.transaction do
      entries =
        DeadLetterEntry.stream()
        |> Enum.to_list()
        |> List.flatten()

      Enum.each(entries, fn entry ->
        :ets.insert(@ets_cache, {entry.id, entry_to_map(entry)})
      end)

      Logger.debug("DLQ: Loaded #{length(entries)} entries into cache")
    end
  rescue
    e ->
      Logger.warning("DLQ: Could not load from Amnesia: #{Exception.message(e)}")
  end

  defp cache_entry(%DeadLetterEntry{} = entry) do
    :ets.insert(@ets_cache, {entry.id, entry_to_map(entry)})
  end

  defp cache_entry(entry) when is_map(entry) do
    :ets.insert(@ets_cache, {entry.id, entry})
  end

  # Convierte struct Amnesia a map (para compatibilidad API)
  defp entry_to_map(%DeadLetterEntry{} = e) do
    %{
      id: e.id,
      type: e.type,
      status: e.status,
      workflow_id: e.workflow_id,
      workflow_module: e.workflow_module,
      failed_step: e.failed_step,
      error: e.error,
      context: e.context,
      original_params: e.original_params,
      metadata: e.metadata,
      created_at: e.created_at,
      updated_at: e.updated_at,
      retry_count: e.retry_count,
      next_retry_at: e.next_retry_at,
      resolution: e.resolution
    }
  end

  defp get_entry(entry_id) do
    case :ets.lookup(@ets_cache, entry_id) do
      [{_, entry}] -> entry
      [] -> nil
    end
  end

  defp list_entries(opts) do
    status_filter = Keyword.get(opts, :status, :pending)
    type_filter = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 100)

    :ets.tab2list(@ets_cache)
    |> Enum.map(fn {_, entry} -> entry end)
    |> Enum.filter(fn entry ->
      status_match = entry.status == status_filter
      type_match = type_filter == nil or entry.type == type_filter
      status_match and type_match
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp do_retry(entry, opts) do
    max_retries = 10
    force = Keyword.get(opts, :force, false)

    if entry.retry_count >= max_retries and not force do
      {:error, :max_retries_exceeded}
    else
      # Actualizar entrada usando DeadLetterEntry.increment_retry/1
      updated_entry =
        Amnesia.transaction do
          case DeadLetterEntry.read(entry.id) do
            nil -> nil
            existing -> DeadLetterEntry.increment_retry(existing)
          end
        end

      if updated_entry do
        persist_entry(updated_entry)
        cache_entry(updated_entry)

        # Ejecutar retry en proceso separado
        spawn(fn -> execute_retry(entry_to_map(updated_entry)) end)

        {:ok, :retrying}
      else
        {:error, :not_found}
      end
    end
  end

  defp execute_retry(entry) do
    Logger.info("DLQ: Retrying entry #{entry.id} (attempt #{entry.retry_count})")

    result =
      case entry.type do
        :compensation_failed ->
          retry_compensation(entry)

        :workflow_failed ->
          retry_workflow(entry)

        :critical_failure ->
          # Critical failures require manual intervention
          {:error, :requires_manual_intervention}
      end

    case result do
      {:ok, _} ->
        do_resolve(entry, :auto_resolved, "Retry succeeded on attempt #{entry.retry_count}")

      {:error, reason} ->
        Logger.warning("DLQ: Retry failed for #{entry.id}: #{inspect(reason)}")
        # Entry stays in pending state for next retry
        Amnesia.transaction do
          case DeadLetterEntry.read(entry.id) do
            nil -> :ok
            existing ->
              updated = %{existing | status: :pending, updated_at: DateTime.utc_now()}
              DeadLetterEntry.write(updated)
              cache_entry(updated)
          end
        end
    end
  end

  defp retry_compensation(entry) do
    step_module = entry.failed_step
    context = entry.context

    if step_module && function_exported?(step_module, :compensate, 2) do
      step_module.compensate(context, [])
    else
      {:error, :no_compensation_function}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp retry_workflow(entry) do
    # Re-ejecutar el workflow desde el principio con params originales
    workflow_module = entry.workflow_module
    workflow_id = "#{entry.workflow_id}_retry_#{entry.retry_count}"

    # Usar params originales si existen, sino intentar extraer del context
    params = get_retry_params(entry)

    case Beamflow.Engine.WorkflowSupervisor.start_workflow(workflow_module, workflow_id, params) do
      {:ok, _pid} -> {:ok, :workflow_restarted}
      error -> error
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Obtener parámetros para retry, con fallback inteligente
  defp get_retry_params(entry) do
    cond do
      # Primero: usar original_params si existen y no están vacíos
      is_map(entry.original_params) and map_size(entry.original_params) > 0 ->
        entry.original_params

      # Fallback: convertir context (workflow_state) a string keys
      is_map(entry.context) and map_size(entry.context) > 0 ->
        convert_to_string_keys(entry.context)

      true ->
        %{}
    end
  end

  # Convierte claves átomo a string para compatibilidad con initial_state
  defp convert_to_string_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp do_resolve(entry, resolution_type, notes) do
    updated_entry =
      Amnesia.transaction do
        case DeadLetterEntry.read(entry.id) do
          nil -> nil
          existing -> DeadLetterEntry.resolve(existing, resolution_type, notes)
        end
      end

    if updated_entry do
      case persist_entry(updated_entry) do
        :ok ->
          cache_entry(updated_entry)
          Logger.info("DLQ: Entry #{entry.id} resolved as #{resolution_type}")
          :ok

        error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  defp calculate_stats do
    entries = :ets.tab2list(@ets_cache) |> Enum.map(fn {_, e} -> e end)

    %{
      total: length(entries),
      by_status: Enum.frequencies_by(entries, & &1.status),
      by_type: Enum.frequencies_by(entries, & &1.type),
      pending_critical: Enum.count(entries, & &1.type == :critical_failure and &1.status == :pending),
      oldest_pending: entries
        |> Enum.filter(& &1.status == :pending)
        |> Enum.min_by(& &1.created_at, DateTime, fn -> nil end)
        |> case do
          nil -> nil
          e -> e.created_at
        end
    }
  end

  defp do_process_due_retries do
    now = DateTime.utc_now()

    due_entries =
      :ets.tab2list(@ets_cache)
      |> Enum.map(fn {_, e} -> e end)
      |> Enum.filter(fn entry ->
        entry.status == :pending and
        entry.next_retry_at != nil and
        DateTime.compare(entry.next_retry_at, now) != :gt
      end)

    Enum.each(due_entries, fn entry ->
      do_retry(entry, [])
    end)

    length(due_entries)
  end

  defp schedule_retry_processing do
    # Procesar cada 5 minutos
    Process.send_after(self(), :process_retries, :timer.minutes(5))
  end

  defp send_alert(entry) do
    severity =
      case entry.type do
        :critical_failure -> :critical
        :compensation_failed -> :high
        :workflow_failed -> :medium
      end

    AlertSystem.send_alert(%{
      severity: severity,
      type: :dlq_entry_created,
      title: "DLQ Entry: #{entry.type}",
      message: "Workflow #{entry.workflow_id} added to DLQ",
      metadata: %{
        entry_id: entry.id,
        workflow_id: entry.workflow_id,
        failed_step: inspect(entry.failed_step),
        error: inspect(entry.error)
      }
    })
  end
end
