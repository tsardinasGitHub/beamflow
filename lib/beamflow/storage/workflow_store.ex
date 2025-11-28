defmodule Beamflow.Storage.WorkflowStore do
  @moduledoc """
  Capa de persistencia para workflows usando Mnesia.

  Este módulo proporciona operaciones CRUD para persistir el estado de los
  workflows y su historial de ejecución. Usa transacciones Mnesia para
  garantizar consistencia ACID.

  ## Tablas

  - `:beamflow_workflows` - Estado principal de cada workflow
  - `:beamflow_events` - Historial de eventos (step completado, fallo, etc.)

  ## Uso

      # Guardar workflow
      {:ok, workflow} = WorkflowStore.save_workflow(actor_state)

      # Obtener workflow
      {:ok, workflow} = WorkflowStore.get_workflow("req-123")

      # Listar workflows por estado
      {:ok, workflows} = WorkflowStore.list_workflows_by_status(:running)

      # Registrar evento
      :ok = WorkflowStore.record_event("req-123", :step_completed, %{step: "ValidateIdentity"})

  ## Transacciones

  Todas las operaciones usan `:mnesia.transaction/1` para garantizar atomicidad.
  Para operaciones de solo lectura, usamos `:mnesia.dirty_read/1` para mayor
  rendimiento cuando la consistencia estricta no es crítica.

  Ver ADR-001 para justificación de Mnesia como almacenamiento.
  """

  require Logger

  # ============================================================================
  # Tipos
  # ============================================================================

  @typedoc "Registro de workflow persistido"
  @type workflow_record :: %{
          id: String.t(),
          workflow_module: module(),
          status: atom(),
          workflow_state: map(),
          current_step_index: non_neg_integer(),
          total_steps: non_neg_integer(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          error: term() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc "Registro de evento"
  @type event_record :: %{
          id: String.t(),
          workflow_id: String.t(),
          event_type: atom(),
          data: map(),
          timestamp: DateTime.t()
        }

  # Nombres de tablas Mnesia
  @workflows_table :beamflow_workflows
  @events_table :beamflow_events

  # ============================================================================
  # API Pública - Workflows
  # ============================================================================

  @doc """
  Guarda o actualiza un workflow en Mnesia.

  ## Parámetros

    * `actor_state` - Estado del actor del workflow (map completo del GenServer)

  ## Retorno

    * `{:ok, workflow_record}` - Workflow persistido exitosamente
    * `{:error, reason}` - Error al persistir

  ## Ejemplo

      iex> WorkflowStore.save_workflow(%{workflow_id: "req-123", status: :running, ...})
      {:ok, %{id: "req-123", status: :running, ...}}
  """
  @spec save_workflow(map()) :: {:ok, workflow_record()} | {:error, term()}
  def save_workflow(actor_state) do
    now = DateTime.utc_now()

    record = {
      @workflows_table,
      actor_state.workflow_id,
      actor_state.workflow_module,
      actor_state.status,
      actor_state.workflow_state,
      actor_state.current_step_index,
      actor_state.total_steps,
      actor_state.started_at,
      actor_state.completed_at,
      actor_state.error,
      Map.get(actor_state, :inserted_at, now),
      now
    }

    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, :ok} ->
        Logger.debug("Workflow #{actor_state.workflow_id} persisted to Mnesia")
        {:ok, record_to_map(record)}

      {:aborted, reason} ->
        Logger.error("Failed to persist workflow #{actor_state.workflow_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Obtiene un workflow por su ID.

  ## Parámetros

    * `workflow_id` - Identificador único del workflow

  ## Retorno

    * `{:ok, workflow_record}` - Workflow encontrado
    * `{:error, :not_found}` - No existe workflow con ese ID

  ## Ejemplo

      iex> WorkflowStore.get_workflow("req-123")
      {:ok, %{id: "req-123", status: :completed, ...}}
  """
  @spec get_workflow(String.t()) :: {:ok, workflow_record()} | {:error, :not_found}
  def get_workflow(workflow_id) do
    # Usamos dirty_read para lecturas rápidas
    case :mnesia.dirty_read(@workflows_table, workflow_id) do
      [record] -> {:ok, record_to_map(record)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Obtiene un workflow usando transacción (para consistencia estricta).

  Use `get_workflow/1` para lecturas normales. Esta función es útil cuando
  necesita garantizar que lee el valor más reciente en una transacción.

  ## Parámetros

    * `workflow_id` - Identificador único del workflow

  ## Retorno

    * `{:ok, workflow_record}` - Workflow encontrado
    * `{:error, :not_found}` - No existe workflow con ese ID
    * `{:error, reason}` - Error de transacción
  """
  @spec get_workflow_strict(String.t()) :: {:ok, workflow_record()} | {:error, term()}
  def get_workflow_strict(workflow_id) do
    case :mnesia.transaction(fn -> :mnesia.read(@workflows_table, workflow_id) end) do
      {:atomic, [record]} -> {:ok, record_to_map(record)}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Lista todos los workflows, opcionalmente filtrados por estado.

  ## Parámetros

    * `opts` - Opciones de filtrado:
      * `:status` - Filtrar por estado (`:pending`, `:running`, `:completed`, `:failed`)
      * `:limit` - Número máximo de resultados (default: sin límite)

  ## Retorno

    * `{:ok, [workflow_record]}` - Lista de workflows

  ## Ejemplos

      iex> WorkflowStore.list_workflows()
      {:ok, [%{id: "req-123", ...}, %{id: "req-456", ...}]}

      iex> WorkflowStore.list_workflows(status: :running)
      {:ok, [%{id: "req-789", status: :running, ...}]}
  """
  @spec list_workflows(keyword()) :: {:ok, [workflow_record()]}
  def list_workflows(opts \\ []) do
    status_filter = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit)

    # Usamos dirty_match_object para listar
    pattern =
      if status_filter do
        {@workflows_table, :_, :_, status_filter, :_, :_, :_, :_, :_, :_, :_, :_}
      else
        {@workflows_table, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}
      end

    records = :mnesia.dirty_match_object(pattern)

    workflows =
      records
      |> Enum.map(&record_to_map/1)
      |> maybe_limit(limit)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:ok, workflows}
  end

  @doc """
  Elimina un workflow de Mnesia.

  También elimina todos los eventos asociados.

  ## Parámetros

    * `workflow_id` - Identificador del workflow a eliminar

  ## Retorno

    * `:ok` - Workflow eliminado exitosamente
    * `{:error, reason}` - Error al eliminar
  """
  @spec delete_workflow(String.t()) :: :ok | {:error, term()}
  def delete_workflow(workflow_id) do
    transaction = fn ->
      # Eliminar workflow
      :mnesia.delete({@workflows_table, workflow_id})

      # Eliminar eventos asociados
      events = :mnesia.match_object({@events_table, :_, workflow_id, :_, :_, :_})
      Enum.each(events, &:mnesia.delete_object/1)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, _} ->
        Logger.info("Workflow #{workflow_id} and its events deleted from Mnesia")
        :ok

      {:aborted, reason} ->
        Logger.error("Failed to delete workflow #{workflow_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # API Pública - Eventos
  # ============================================================================

  @doc """
  Registra un evento en el historial del workflow.

  ## Parámetros

    * `workflow_id` - ID del workflow
    * `event_type` - Tipo de evento (`:step_started`, `:step_completed`, `:step_failed`, etc.)
    * `data` - Datos adicionales del evento

  ## Retorno

    * `:ok` - Evento registrado exitosamente
    * `{:error, reason}` - Error al registrar

  ## Ejemplo

      iex> WorkflowStore.record_event("req-123", :step_completed, %{step: "ValidateIdentity", duration_ms: 350})
      :ok
  """
  @spec record_event(String.t(), atom(), map()) :: :ok | {:error, term()}
  def record_event(workflow_id, event_type, data \\ %{}) do
    event_id = UUID.uuid4()
    now = DateTime.utc_now()

    record = {
      @events_table,
      event_id,
      workflow_id,
      event_type,
      data,
      now
    }

    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, :ok} ->
        Logger.debug("Event #{event_type} recorded for workflow #{workflow_id}")
        :ok

      {:aborted, reason} ->
        Logger.error("Failed to record event for #{workflow_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Obtiene el historial de eventos de un workflow.

  ## Parámetros

    * `workflow_id` - ID del workflow
    * `opts` - Opciones:
      * `:event_type` - Filtrar por tipo de evento
      * `:limit` - Número máximo de eventos

  ## Retorno

    * `{:ok, [event_record]}` - Lista de eventos ordenados por timestamp

  ## Ejemplo

      iex> WorkflowStore.get_events("req-123")
      {:ok, [
        %{event_type: :step_started, timestamp: ~U[2025-01-01 10:00:00Z], ...},
        %{event_type: :step_completed, timestamp: ~U[2025-01-01 10:00:01Z], ...}
      ]}
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [event_record()]}
  def get_events(workflow_id, opts \\ []) do
    event_type_filter = Keyword.get(opts, :event_type)
    limit = Keyword.get(opts, :limit)

    pattern =
      if event_type_filter do
        {@events_table, :_, workflow_id, event_type_filter, :_, :_}
      else
        {@events_table, :_, workflow_id, :_, :_, :_}
      end

    events =
      :mnesia.dirty_match_object(pattern)
      |> Enum.map(&event_record_to_map/1)
      |> Enum.sort_by(& &1.timestamp, DateTime)
      |> maybe_limit(limit)

    {:ok, events}
  end

  # ============================================================================
  # API Pública - Utilidades
  # ============================================================================

  @doc """
  Cuenta workflows por estado.

  Útil para dashboards y métricas.

  ## Retorno

  Mapa con conteo por estado.

  ## Ejemplo

      iex> WorkflowStore.count_by_status()
      %{pending: 5, running: 12, completed: 156, failed: 3}
  """
  @spec count_by_status() :: map()
  def count_by_status do
    {:ok, all} = list_workflows()

    all
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, workflows} -> {status, length(workflows)} end)
    |> Map.new()
    |> Map.merge(%{pending: 0, running: 0, completed: 0, failed: 0}, fn _k, v1, _v2 -> v1 end)
  end

  @doc """
  Verifica si las tablas de Mnesia están disponibles.

  ## Retorno

    * `true` - Tablas disponibles
    * `false` - Tablas no disponibles
  """
  @spec tables_available?() :: boolean()
  def tables_available? do
    tables = :mnesia.system_info(:tables)
    @workflows_table in tables and @events_table in tables
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp record_to_map(
         {_table, id, workflow_module, status, workflow_state, current_step_index, total_steps,
          started_at, completed_at, error, inserted_at, updated_at}
       ) do
    %{
      id: id,
      workflow_module: workflow_module,
      status: status,
      workflow_state: workflow_state,
      current_step_index: current_step_index,
      total_steps: total_steps,
      started_at: started_at,
      completed_at: completed_at,
      error: error,
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  defp event_record_to_map({_table, id, workflow_id, event_type, data, timestamp}) do
    %{
      id: id,
      workflow_id: workflow_id,
      event_type: event_type,
      data: data,
      timestamp: timestamp
    }
  end

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit), do: Enum.take(list, limit)
end
