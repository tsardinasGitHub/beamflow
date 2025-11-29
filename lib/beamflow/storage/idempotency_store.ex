defmodule Beamflow.Storage.IdempotencyStore do
  @moduledoc """
  Almacenamiento Amnesia para registros de idempotencia.

  Esta tabla mantiene el estado de ejecución de cada step para
  garantizar exactamente-una-vez en side-effects.

  ## Tabla Amnesia: `Beamflow.Database.Idempotency`

  | Campo | Tipo | Descripción |
  |-------|------|-------------|
  | key | String | "{workflow_id}:{step}:{attempt}" |
  | status | atom | :pending, :completed, :failed |
  | started_at | DateTime | Inicio de ejecución |
  | completed_at | DateTime | Fin (nil si pending) |
  | result | map | Resultado del step |
  | error | term | Error si falló |

  ## Migración

  Este módulo fue migrado de Mnesia raw a Amnesia (ver ADR-005).
  """

  require Logger

  use Amnesia
  alias Beamflow.Database.Idempotency

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
    case :mnesia.dirty_read(Idempotency, key) do
      [] ->
        :not_found

      [record] when is_tuple(record) ->
        case tuple_to_record(record) do
          %{status: :pending, started_at: started_at} ->
            {:pending, started_at}

          %{status: :completed, result: result} ->
            {:completed, result}

          %{status: :failed, error: error} ->
            {:failed, error}
        end
    end
  end

  @doc """
  Marca un step como pendiente (en ejecución).
  """
  @spec mark_pending(String.t()) :: :ok | {:error, term()}
  def mark_pending(key) do
    record = Idempotency.pending(key)

    Amnesia.transaction do
      Idempotency.write(record)
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Marca un step como completado con su resultado.
  """
  @spec mark_completed(String.t(), map()) :: :ok | {:error, term()}
  def mark_completed(key, result) do
    now = DateTime.utc_now()

    Amnesia.transaction do
      case Idempotency.read(key) do
        nil ->
          # No había pending, registrar de todas formas
          record = %Idempotency{
            key: key,
            status: :completed,
            started_at: now,
            completed_at: now,
            result: result,
            error: nil
          }
          Idempotency.write(record)

        existing ->
          updated = Idempotency.complete(existing, result)
          Idempotency.write(updated)
      end
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Marca un step como fallido.
  """
  @spec mark_failed(String.t(), term()) :: :ok | {:error, term()}
  def mark_failed(key, error) do
    now = DateTime.utc_now()

    Amnesia.transaction do
      case Idempotency.read(key) do
        nil ->
          record = %Idempotency{
            key: key,
            status: :failed,
            started_at: now,
            completed_at: now,
            result: nil,
            error: error
          }
          Idempotency.write(record)

        existing ->
          updated = Idempotency.fail(existing, error)
          Idempotency.write(updated)
      end
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Lista todos los registros pendientes (posibles crashes).

  Útil para monitoreo y recuperación manual.
  """
  @spec list_pending() :: [idempotency_record()]
  def list_pending do
    Amnesia.transaction do
      Idempotency.stream()
      |> Enum.to_list()
      |> List.flatten()
      |> Enum.filter(fn r -> r.status == :pending end)
      |> Enum.map(&record_to_map/1)
    end
  end

  @doc """
  Elimina registros más antiguos que la fecha especificada.

  Solo elimina registros :completed o :failed.
  Los :pending se mantienen para investigación.
  """
  @spec cleanup_older_than(DateTime.t()) :: {:ok, non_neg_integer()}
  def cleanup_older_than(older_than) do
    Amnesia.transaction do
      to_delete =
        Idempotency.stream()
        |> Enum.to_list()
        |> List.flatten()
        |> Enum.filter(fn r ->
          r.status in [:completed, :failed] and
          DateTime.compare(r.started_at, older_than) == :lt
        end)

      Enum.each(to_delete, fn record ->
        Idempotency.delete(record.key)
      end)

      {:ok, length(to_delete)}
    end
  end

  @doc """
  Obtiene estadísticas de idempotencia.
  """
  @spec stats() :: %{pending: integer(), completed: integer(), failed: integer()}
  def stats do
    Amnesia.transaction do
      all =
        Idempotency.stream()
        |> Enum.to_list()
        |> List.flatten()

      pending = Enum.count(all, fn r -> r.status == :pending end)
      completed = Enum.count(all, fn r -> r.status == :completed end)
      failed = Enum.count(all, fn r -> r.status == :failed end)

      %{pending: pending, completed: completed, failed: failed}
    end
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  # Convierte tupla Mnesia raw a map (para dirty_read)
  defp tuple_to_record({Idempotency, key, status, started_at, completed_at, result, error}) do
    %{
      key: key,
      status: status,
      started_at: started_at,
      completed_at: completed_at,
      result: result,
      error: error
    }
  end

  defp record_to_map(%Idempotency{} = r) do
    %{
      key: r.key,
      status: r.status,
      started_at: r.started_at,
      completed_at: r.completed_at,
      result: r.result,
      error: r.error
    }
  end
end
