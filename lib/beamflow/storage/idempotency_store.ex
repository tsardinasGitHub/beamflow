defmodule Beamflow.Storage.IdempotencyStore do
  @moduledoc """
  Almacenamiento Mnesia para registros de idempotencia.

  Esta tabla mantiene el estado de ejecución de cada step para
  garantizar exactamente-una-vez en side-effects.

  ## Tabla: `:beamflow_idempotency`

  | Campo | Tipo | Descripción |
  |-------|------|-------------|
  | key | String | "{workflow_id}:{step}:{attempt}" |
  | status | atom | :pending, :completed, :failed |
  | started_at | DateTime | Inicio de ejecución |
  | completed_at | DateTime | Fin (nil si pending) |
  | result | map | Resultado del step |
  | error | term | Error si falló |
  """

  require Logger

  @table :beamflow_idempotency

  @type status :: :pending | :completed | :failed
  @type idempotency_record :: %{
          key: String.t(),
          status: status(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          result: map() | nil,
          error: term() | nil
        }

  # ============================================================================
  # API Pública
  # ============================================================================

  @doc """
  Obtiene el estado de una clave de idempotencia.

  ## Retorno

  - `:not_found` - No hay registro
  - `{:pending, started_at}` - En progreso
  - `{:completed, result}` - Completado
  - `{:failed, error}` - Falló
  """
  @spec get_status(String.t()) ::
          :not_found
          | {:pending, DateTime.t()}
          | {:completed, map()}
          | {:failed, term()}
  def get_status(key) do
    case :mnesia.dirty_read(@table, key) do
      [] ->
        :not_found

      [{@table, ^key, :pending, started_at, _completed, _result, _error}] ->
        {:pending, started_at}

      [{@table, ^key, :completed, _started, _completed, result, _error}] ->
        {:completed, result}

      [{@table, ^key, :failed, _started, _completed, _result, error}] ->
        {:failed, error}
    end
  end

  @doc """
  Marca un step como pendiente (en ejecución).
  """
  @spec mark_pending(String.t()) :: :ok | {:error, term()}
  def mark_pending(key) do
    now = DateTime.utc_now()

    record = {@table, key, :pending, now, nil, nil, nil}

    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Marca un step como completado con su resultado.
  """
  @spec mark_completed(String.t(), map()) :: :ok | {:error, term()}
  def mark_completed(key, result) do
    now = DateTime.utc_now()

    transaction = fn ->
      case :mnesia.read(@table, key) do
        [{@table, ^key, :pending, started_at, _completed, _result, _error}] ->
          record = {@table, key, :completed, started_at, now, result, nil}
          :mnesia.write(record)

        [] ->
          # No había pending, registrar de todas formas
          record = {@table, key, :completed, now, now, result, nil}
          :mnesia.write(record)

        _ ->
          {:error, :invalid_state}
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} -> :ok
      {:atomic, {:error, reason}} -> {:error, reason}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Marca un step como fallido.
  """
  @spec mark_failed(String.t(), term()) :: :ok | {:error, term()}
  def mark_failed(key, error) do
    now = DateTime.utc_now()

    transaction = fn ->
      case :mnesia.read(@table, key) do
        [{@table, ^key, :pending, started_at, _completed, _result, _error}] ->
          record = {@table, key, :failed, started_at, now, nil, error}
          :mnesia.write(record)

        [] ->
          record = {@table, key, :failed, now, now, nil, error}
          :mnesia.write(record)

        _ ->
          {:error, :invalid_state}
      end
    end

    case :mnesia.transaction(transaction) do
      {:atomic, :ok} -> :ok
      {:atomic, {:error, reason}} -> {:error, reason}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Lista todos los registros pendientes (posibles crashes).

  Útil para monitoreo y recuperación manual.
  """
  @spec list_pending() :: [idempotency_record()]
  def list_pending do
    pattern = {@table, :_, :pending, :_, :_, :_, :_}

    :mnesia.dirty_match_object(pattern)
    |> Enum.map(&record_to_map/1)
  end

  @doc """
  Elimina registros más antiguos que la fecha especificada.

  Solo elimina registros :completed o :failed.
  Los :pending se mantienen para investigación.
  """
  @spec cleanup_older_than(DateTime.t()) :: {:ok, non_neg_integer()}
  def cleanup_older_than(older_than) do
    transaction = fn ->
      # Buscar todos los registros completados o fallidos
      completed_pattern = {@table, :_, :completed, :_, :_, :_, :_}
      failed_pattern = {@table, :_, :failed, :_, :_, :_, :_}

      completed = :mnesia.match_object(completed_pattern)
      failed = :mnesia.match_object(failed_pattern)

      all_records = completed ++ failed

      # Filtrar los que son más antiguos
      to_delete =
        Enum.filter(all_records, fn {_, _, _, started_at, _, _, _} ->
          DateTime.compare(started_at, older_than) == :lt
        end)

      # Eliminar
      Enum.each(to_delete, fn record ->
        :mnesia.delete_object(record)
      end)

      length(to_delete)
    end

    case :mnesia.transaction(transaction) do
      {:atomic, count} -> {:ok, count}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Obtiene estadísticas de idempotencia.
  """
  @spec stats() :: %{pending: integer(), completed: integer(), failed: integer()}
  def stats do
    pending = :mnesia.dirty_match_object({@table, :_, :pending, :_, :_, :_, :_}) |> length()
    completed = :mnesia.dirty_match_object({@table, :_, :completed, :_, :_, :_, :_}) |> length()
    failed = :mnesia.dirty_match_object({@table, :_, :failed, :_, :_, :_, :_}) |> length()

    %{pending: pending, completed: completed, failed: failed}
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp record_to_map({@table, key, status, started_at, completed_at, result, error}) do
    %{
      key: key,
      status: status,
      started_at: started_at,
      completed_at: completed_at,
      result: result,
      error: error
    }
  end
end
