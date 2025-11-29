defmodule Beamflow.Database.Query do
  @moduledoc """
  Módulo de queries genéricas para la base de datos Beamflow.

  Proporciona funciones de alto nivel para operaciones CRUD
  y consultas complejas usando Amnesia.

  ## Uso

      alias Beamflow.Database.Query

      # Obtener un registro
      Query.get(Workflow, "wf-123")

      # Listar con filtro
      Query.list(Workflow, status: :running)

      # Crear registro
      Query.create(%Workflow{id: "wf-123", status: :pending})

      # Actualizar
      Query.update(workflow, %{status: :completed})

      # Eliminar
      Query.delete(Workflow, "wf-123")

  ## Transacciones

  Todas las operaciones de escritura usan transacciones Amnesia.
  Las lecturas usan `dirty_read` para mayor rendimiento cuando
  la consistencia estricta no es necesaria.
  """

  use Amnesia
  require Amnesia.Helper
  require Logger

  alias Beamflow.Database.{Workflow, Event, Idempotency, DeadLetterEntry}

  # ============================================================================
  # Operaciones Genéricas
  # ============================================================================

  @doc """
  Obtiene un registro por su clave primaria.

  ## Parámetros
    - table: Módulo de la tabla (Workflow, Event, etc.)
    - key: Clave primaria

  ## Retorno
    - `{:ok, record}` si existe
    - `{:error, :not_found}` si no existe
  """
  @spec get(module(), term()) :: {:ok, struct()} | {:error, :not_found}
  def get(table, key) do
    Amnesia.transaction do
      case table.read(key) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  @doc """
  Obtiene un registro usando dirty read (sin transacción).
  Más rápido pero sin garantía de consistencia estricta.
  """
  @spec get_dirty(module(), term()) :: {:ok, struct()} | {:error, :not_found}
  def get_dirty(table, key) do
    case :mnesia.dirty_read(table, key) do
      [] -> {:error, :not_found}
      [record] -> {:ok, record_to_struct(table, record)}
    end
  end

  @doc """
  Lista todos los registros de una tabla con filtros opcionales.

  ## Opciones
    - Cualquier atributo de la tabla para filtrar
    - `:limit` - Número máximo de resultados
    - `:order_by` - Campo para ordenar
    - `:order` - `:asc` o `:desc`
  """
  @spec list(module(), keyword()) :: {:ok, [struct()]}
  def list(table, opts \\ []) do
    {meta_opts, filter_opts} = Keyword.split(opts, [:limit, :order_by, :order])

    Amnesia.transaction do
      records =
        table.stream()
        |> Enum.to_list()
        |> List.flatten()  # Tablas :bag retornan listas anidadas
        |> apply_filters(filter_opts)
        |> apply_ordering(meta_opts)
        |> apply_limit(meta_opts)

      {:ok, records}
    end
  end

  @doc """
  Cuenta registros que coinciden con los filtros.
  """
  @spec count(module(), keyword()) :: non_neg_integer()
  def count(table, filters \\ []) do
    {:ok, records} = list(table, filters)
    length(records)
  end

  @doc """
  Crea o actualiza un registro.
  """
  @spec write(struct()) :: {:ok, struct()} | {:error, term()}
  def write(record) do
    Amnesia.transaction do
      record.__struct__.write(record)
      {:ok, record}
    end
  rescue
    e ->
      Logger.error("Error writing record: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Alias de write para mayor claridad semántica.
  """
  @spec create(struct()) :: {:ok, struct()} | {:error, term()}
  def create(record), do: write(record)

  @doc """
  Actualiza un registro existente.
  """
  @spec update(struct(), map()) :: {:ok, struct()} | {:error, term()}
  def update(record, attrs) do
    updated = Map.merge(record, Map.new(attrs))
    write(updated)
  end

  @doc """
  Elimina un registro por clave primaria.
  """
  @spec delete(module(), term()) :: :ok | {:error, term()}
  def delete(table, key) do
    Amnesia.transaction do
      table.delete(key)
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Elimina un registro por su struct.
  """
  @spec delete_record(struct()) :: :ok | {:error, term()}
  def delete_record(record) do
    Amnesia.transaction do
      record.__struct__.delete(record)
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ============================================================================
  # Queries Específicas - Workflow
  # ============================================================================

  @doc """
  Lista workflows por estado.
  """
  @spec list_workflows_by_status(atom(), keyword()) :: {:ok, [Workflow.t()]}
  def list_workflows_by_status(status, opts \\ []) do
    list(Workflow, Keyword.put(opts, :status, status))
  end

  @doc """
  Cuenta workflows por estado.
  """
  @spec count_workflows_by_status() :: map()
  def count_workflows_by_status do
    {:ok, all} = list(Workflow)

    all
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, wfs} -> {status, length(wfs)} end)
    |> Map.new()
    |> Map.merge(%{pending: 0, running: 0, completed: 0, failed: 0}, fn _k, v1, _v2 -> v1 end)
  end

  @doc """
  Obtiene un workflow con sus eventos.
  """
  @spec get_workflow_with_events(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_workflow_with_events(workflow_id) do
    Amnesia.transaction do
      case Workflow.read(workflow_id) do
        nil ->
          {:error, :not_found}

        workflow ->
          events =
            Event.stream()
            |> Enum.filter(& &1.workflow_id == workflow_id)
            |> Enum.sort_by(& &1.timestamp, DateTime)

          {:ok, %{workflow: workflow, events: events}}
      end
    end
  end

  # ============================================================================
  # Queries Específicas - Event
  # ============================================================================

  @doc """
  Obtiene eventos de un workflow.
  """
  @spec get_events_for_workflow(String.t(), keyword()) :: {:ok, [Event.t()]}
  def get_events_for_workflow(workflow_id, opts \\ []) do
    Amnesia.transaction do
      events =
        Event.stream()
        |> Enum.to_list()
        |> List.flatten()  # Tablas :bag retornan listas anidadas
        |> Enum.filter(fn event -> event.workflow_id == workflow_id end)
        |> apply_filters(Keyword.delete(opts, :limit))
        |> Enum.sort_by(fn event -> event.timestamp end, DateTime)
        |> apply_limit(opts)

      {:ok, events}
    end
  end

  @doc """
  Registra un evento para un workflow.
  """
  @spec record_event(String.t(), atom(), map()) :: {:ok, Event.t()}
  def record_event(workflow_id, event_type, data \\ %{}) do
    event = Event.new(workflow_id, event_type, data)
    write(event)
  end

  # ============================================================================
  # Queries Específicas - Idempotency
  # ============================================================================

  @doc """
  Obtiene el estado de idempotencia para una clave.
  """
  @spec get_idempotency_status(String.t()) ::
    :not_found | {:pending, DateTime.t()} | {:completed, map()} | {:failed, term()}
  def get_idempotency_status(key) do
    case get_dirty(Idempotency, key) do
      {:error, :not_found} -> :not_found
      {:ok, %{status: :pending, started_at: started}} -> {:pending, started}
      {:ok, %{status: :completed, result: result}} -> {:completed, result}
      {:ok, %{status: :failed, error: error}} -> {:failed, error}
    end
  end

  @doc """
  Marca una clave como pendiente.
  """
  @spec mark_pending(String.t()) :: :ok | {:error, term()}
  def mark_pending(key) do
    record = Idempotency.pending(key)
    case write(record) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Marca una clave como completada.
  """
  @spec mark_completed(String.t(), map()) :: :ok | {:error, term()}
  def mark_completed(key, result) do
    Amnesia.transaction do
      case Idempotency.read(key) do
        nil ->
          record = %Idempotency{
            key: key,
            status: :completed,
            started_at: DateTime.utc_now(),
            completed_at: DateTime.utc_now(),
            result: result,
            error: nil
          }
          Idempotency.write(record)
          :ok

        record ->
          updated = Idempotency.complete(record, result)
          Idempotency.write(updated)
          :ok
      end
    end
  end

  @doc """
  Marca una clave como fallida.
  """
  @spec mark_failed(String.t(), term()) :: :ok | {:error, term()}
  def mark_failed(key, error) do
    Amnesia.transaction do
      case Idempotency.read(key) do
        nil ->
          record = %Idempotency{
            key: key,
            status: :failed,
            started_at: DateTime.utc_now(),
            completed_at: DateTime.utc_now(),
            result: nil,
            error: error
          }
          Idempotency.write(record)
          :ok

        record ->
          updated = Idempotency.fail(record, error)
          Idempotency.write(updated)
          :ok
      end
    end
  end

  @doc """
  Lista registros pendientes (posibles crashes).
  """
  @spec list_pending_idempotency() :: [Idempotency.t()]
  def list_pending_idempotency do
    {:ok, records} = list(Idempotency, status: :pending)
    records
  end

  @doc """
  Estadísticas de idempotencia.
  """
  @spec idempotency_stats() :: map()
  def idempotency_stats do
    {:ok, all} = list(Idempotency)

    all
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, records} -> {status, length(records)} end)
    |> Map.new()
    |> Map.merge(%{pending: 0, completed: 0, failed: 0}, fn _k, v1, _v2 -> v1 end)
  end

  # ============================================================================
  # Queries Específicas - DeadLetterEntry
  # ============================================================================

  @doc """
  Lista entradas DLQ pendientes.
  """
  @spec list_dlq_pending(keyword()) :: {:ok, [DeadLetterEntry.t()]}
  def list_dlq_pending(opts \\ []) do
    list(DeadLetterEntry, Keyword.put(opts, :status, :pending))
  end

  @doc """
  Estadísticas del DLQ.
  """
  @spec dlq_stats() :: map()
  def dlq_stats do
    {:ok, all} = list(DeadLetterEntry)

    %{
      total: length(all),
      by_status: Enum.frequencies_by(all, & &1.status),
      by_type: Enum.frequencies_by(all, & &1.type),
      pending_critical: Enum.count(all, & &1.type == :critical_failure and &1.status == :pending),
      oldest_pending: all
        |> Enum.filter(& &1.status == :pending)
        |> Enum.min_by(& &1.created_at, DateTime, fn -> nil end)
        |> case do
          nil -> nil
          e -> e.created_at
        end
    }
  end

  @doc """
  Obtiene entradas DLQ listas para retry.
  """
  @spec get_dlq_due_for_retry() :: [DeadLetterEntry.t()]
  def get_dlq_due_for_retry do
    now = DateTime.utc_now()
    {:ok, pending} = list_dlq_pending()

    Enum.filter(pending, fn entry ->
      entry.next_retry_at != nil and
      DateTime.compare(entry.next_retry_at, now) != :gt
    end)
  end

  # ============================================================================
  # Utilidades
  # ============================================================================

  @doc """
  Estadísticas de todas las tablas.
  """
  @spec table_stats() :: [map()]
  def table_stats do
    [Workflow, Event, Idempotency, DeadLetterEntry]
    |> Enum.map(fn table ->
      count = count(table)
      %{table: table, count: count}
    end)
  end

  @doc """
  Verifica integridad de datos.
  """
  @spec data_integrity_check() :: map()
  def data_integrity_check do
    {:ok, workflows} = list(Workflow)
    {:ok, events} = list(Event)
    {:ok, dlq} = list(DeadLetterEntry)

    workflow_ids = MapSet.new(workflows, fn w -> w.id end)

    # Eventos huérfanos (workflow no existe)
    orphaned_events = Enum.filter(events, fn event ->
      not MapSet.member?(workflow_ids, event.workflow_id)
    end)

    # DLQ entries huérfanas
    orphaned_dlq = Enum.filter(dlq, fn entry ->
      entry.status == :pending and not MapSet.member?(workflow_ids, entry.workflow_id)
    end)

    %{
      orphaned_events: length(orphaned_events),
      orphaned_dlq: length(orphaned_dlq),
      status: if(length(orphaned_events) == 0 and length(orphaned_dlq) == 0, do: :ok, else: :issues_found)
    }
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp apply_filters(records, []), do: records
  defp apply_filters(records, filters) do
    Enum.filter(records, fn record ->
      Enum.all?(filters, fn {key, value} ->
        Map.get(record, key) == value
      end)
    end)
  end

  defp apply_ordering(records, opts) do
    case Keyword.get(opts, :order_by) do
      nil -> records
      field ->
        order = Keyword.get(opts, :order, :asc)
        case order do
          :asc -> Enum.sort_by(records, &Map.get(&1, field))
          :desc -> Enum.sort_by(records, &Map.get(&1, field), :desc)
        end
    end
  end

  defp apply_limit(records, opts) do
    case Keyword.get(opts, :limit) do
      nil -> records
      limit -> Enum.take(records, limit)
    end
  end

  # Convierte tupla Mnesia a struct
  defp record_to_struct(table, tuple) when is_tuple(tuple) do
    [_table_name | values] = Tuple.to_list(tuple)

    # Obtener atributos de la tabla desde Mnesia
    attributes = :mnesia.table_info(table, :attributes)

    pairs = Enum.zip(attributes, values)
    struct(table, pairs)
  end

  defp record_to_struct(_table, record), do: record
end
