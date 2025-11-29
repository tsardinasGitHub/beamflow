defmodule Beamflow.Database.Migration do
  @moduledoc """
  Sistema de migración para la base de datos Beamflow.

  Proporciona backup/restore automático para migraciones seguras de schema.

  ## ¿Por qué es necesario?

  Mnesia requiere destruir el schema para modificar la estructura de tablas.
  Sin backup/restore, perderíamos todos los datos al hacer cambios.

  ## Uso

      # Migración completa (backup → destroy → create → restore)
      Beamflow.Database.Migration.migrate()

      # Solo backup
      {:ok, backup} = Beamflow.Database.Migration.backup_all()

      # Crear tablas desde cero (desarrollo)
      Beamflow.Database.Migration.setup(:dev)

      # Restaurar desde backup
      Beamflow.Database.Migration.restore_all(backup)

  ## Estructura del Backup

      %{
        timestamp: DateTime.t(),
        tables: %{
          workflows: [%Workflow{}, ...],
          events: [%Event{}, ...],
          idempotency: [%Idempotency{}, ...],
          dlq: [%DeadLetterEntry{}, ...]
        }
      }
  """

  use Amnesia
  require Logger

  alias Beamflow.Database
  alias Beamflow.Database.{Workflow, Event, Idempotency, DeadLetterEntry}

  @tables [Workflow, Event, Idempotency, DeadLetterEntry]

  # ============================================================================
  # API Pública
  # ============================================================================

  @doc """
  Ejecuta migración completa con backup/restore automático.

  1. Backup de todos los datos existentes
  2. Destruye schema y tablas
  3. Crea nuevas tablas con schema actualizado
  4. Restaura datos

  ## Opciones
    - `:force` - Forzar migración aunque haya errores de backup
    - `:skip_backup` - No hacer backup (⚠️ peligroso)

  ## Retorno
    - `{:ok, %{backed_up: n, restored: n}}` - Éxito
    - `{:error, reason}` - Error
  """
  @spec migrate(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(opts \\ []) do
    Logger.info("Starting database migration...")

    skip_backup = Keyword.get(opts, :skip_backup, false)
    force = Keyword.get(opts, :force, false)

    # Paso 1: Backup
    backup_result =
      if skip_backup do
        Logger.warning("Skipping backup as requested - data may be lost!")
        {:ok, %{timestamp: DateTime.utc_now(), tables: %{}}}
      else
        backup_all()
      end

    case backup_result do
      {:ok, backup} ->
        backed_up_count = count_backup_records(backup)
        Logger.info("Backed up #{backed_up_count} records")

        # Paso 2: Destruir y recrear
        :ok = destroy_and_create()

        # Paso 3: Restaurar
        case restore_all(backup) do
          {:ok, restored} ->
            restored_count = Enum.sum(Map.values(restored))
            Logger.info("Migration complete. Restored #{restored_count} records")
            {:ok, %{backed_up: backed_up_count, restored: restored_count, details: restored}}

          {:error, reason} = error ->
            Logger.error("Failed to restore data: #{inspect(reason)}")
            # Guardar backup en archivo para recuperación manual
            save_backup_to_file(backup)
            error
        end

      {:error, reason} = error ->
        if force do
          Logger.warning("Backup failed but continuing with force=true: #{inspect(reason)}")
          :ok = destroy_and_create()
          {:ok, %{backed_up: 0, restored: 0, warning: "Backup failed, data lost"}}
        else
          Logger.error("Backup failed, aborting migration: #{inspect(reason)}")
          error
        end
    end
  end

  @doc """
  Configura la base de datos desde cero.

  ## Modos
    - `:dev` - Desarrollo, destruye todo y crea limpio
    - `:prod` - Producción, solo crea si no existe
    - `:test` - Testing, usa ram_copies
  """
  @spec setup(atom()) :: :ok | {:error, term()}
  def setup(mode \\ :dev) do
    Logger.info("Setting up database in #{mode} mode...")

    case mode do
      :dev ->
        Amnesia.stop()
        Amnesia.Schema.destroy()
        Amnesia.Schema.create([node()])
        Amnesia.start()
        Database.create(disk: [node()])
        add_indexes()
        :ok

      :prod ->
        # Solo crear si no existe
        ensure_mnesia_dir()
        ensure_schema()
        Amnesia.start()

        if tables_exist?() do
          Logger.info("Tables already exist, skipping creation")
          :ok
        else
          Database.create(disk: [node()])
          add_indexes()
          :ok
        end

      :test ->
        Amnesia.stop()
        Amnesia.Schema.destroy()
        Amnesia.Schema.create([node()])
        Amnesia.start()
        # En test usamos ram_copies para velocidad
        Database.create(memory: [node()])
        :ok
    end
  end

  @doc """
  Hace backup de todas las tablas.
  """
  @spec backup_all() :: {:ok, map()} | {:error, term()}
  def backup_all do
    Logger.debug("Backing up all tables...")

    try do
      backup = %{
        timestamp: DateTime.utc_now(),
        node: node(),
        tables: %{}
      }

      tables_data =
        Enum.reduce(@tables, %{}, fn table, acc ->
          case backup_table(table) do
            {:ok, records} ->
              table_key = table_to_key(table)
              Map.put(acc, table_key, records)

            {:error, reason} ->
              Logger.warning("Could not backup #{table}: #{inspect(reason)}")
              Map.put(acc, table_to_key(table), [])
          end
        end)

      {:ok, %{backup | tables: tables_data}}
    rescue
      e ->
        Logger.error("Backup failed: #{Exception.message(e)}")
        {:error, {:backup_failed, Exception.message(e)}}
    end
  end

  @doc """
  Hace backup de una tabla específica.
  """
  @spec backup_table(module()) :: {:ok, [struct()]} | {:error, term()}
  def backup_table(table) do
    try do
      if table_exists?(table) do
        Amnesia.transaction do
          records = table.stream() |> Enum.to_list()
          {:ok, records}
        end
      else
        {:ok, []}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Restaura todas las tablas desde un backup.
  """
  @spec restore_all(map()) :: {:ok, map()} | {:error, term()}
  def restore_all(backup) do
    Logger.debug("Restoring from backup...")

    try do
      results =
        Enum.reduce(backup.tables, %{}, fn {table_key, records}, acc ->
          table = key_to_table(table_key)
          count = restore_table(table, records)
          Map.put(acc, table_key, count)
        end)

      {:ok, results}
    rescue
      e ->
        Logger.error("Restore failed: #{Exception.message(e)}")
        {:error, {:restore_failed, Exception.message(e)}}
    end
  end

  @doc """
  Restaura una tabla específica.
  """
  @spec restore_table(module(), [struct()]) :: non_neg_integer()
  def restore_table(table, records) do
    Logger.debug("Restoring #{length(records)} records to #{table}...")

    Enum.each(records, fn record ->
      try do
        Amnesia.transaction do
          table.write(record)
        end
      rescue
        e ->
          Logger.warning("Could not restore record: #{inspect(e)}")
      end
    end)

    length(records)
  end

  @doc """
  Guarda backup en archivo JSON para recuperación de emergencia.
  """
  @spec save_backup_to_file(map()) :: :ok | {:error, term()}
  def save_backup_to_file(backup) do
    filename = "backup_#{DateTime.to_unix(backup.timestamp)}.json"
    path = Path.join(backup_dir(), filename)

    case File.mkdir_p(backup_dir()) do
      :ok ->
        # Convertir a JSON-safe
        json_safe = convert_to_json_safe(backup)

        case Jason.encode(json_safe, pretty: true) do
          {:ok, json} ->
            File.write!(path, json)
            Logger.info("Backup saved to #{path}")
            :ok

          {:error, reason} ->
            Logger.error("Could not encode backup to JSON: #{inspect(reason)}")
            {:error, reason}
        end

      error ->
        Logger.error("Could not create backup directory: #{inspect(error)}")
        error
    end
  end

  @doc """
  Lista backups disponibles en disco.
  """
  @spec list_backups() :: [String.t()]
  def list_backups do
    case File.ls(backup_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort(:desc)

      {:error, _} -> []
    end
  end

  @doc """
  Carga un backup desde archivo.
  """
  @spec load_backup_from_file(String.t()) :: {:ok, map()} | {:error, term()}
  def load_backup_from_file(filename) do
    path = Path.join(backup_dir(), filename)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, convert_from_json(data)}
          error -> error
        end

      error -> error
    end
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp destroy_and_create do
    Logger.debug("Destroying and recreating schema...")

    Amnesia.stop()
    Amnesia.Schema.destroy()

    ensure_mnesia_dir()
    Amnesia.Schema.create([node()])
    Amnesia.start()

    # Crear tablas según el entorno
    storage_type = storage_type_for_env()

    case storage_type do
      :disc_copies -> Database.create(disk: [node()])
      :ram_copies -> Database.create(memory: [node()])
    end

    add_indexes()

    :ok
  end

  defp add_indexes do
    Logger.debug("Adding table indexes...")

    # Los índices ya están definidos en deftable, pero los añadimos explícitamente
    # por si Amnesia no los crea automáticamente
    safe_add_index(Workflow, :status)
    safe_add_index(Workflow, :workflow_module)
    safe_add_index(Event, :workflow_id)
    safe_add_index(Event, :event_type)
    safe_add_index(Idempotency, :status)
    safe_add_index(DeadLetterEntry, :status)
    safe_add_index(DeadLetterEntry, :type)
    safe_add_index(DeadLetterEntry, :workflow_id)
  end

  defp safe_add_index(table, attribute) do
    case :mnesia.add_table_index(table, attribute) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _, _}} -> :ok
      {:aborted, reason} ->
        Logger.debug("Could not add index #{table}.#{attribute}: #{inspect(reason)}")
    end
  end

  defp table_exists?(table) do
    :mnesia.system_info(:tables) |> Enum.member?(table)
  end

  defp tables_exist? do
    existing = :mnesia.system_info(:tables)
    Enum.all?(@tables, &(&1 in existing))
  end

  defp ensure_mnesia_dir do
    dir = Application.get_env(:mnesia, :dir) || ~c".mnesia/#{node()}"
    dir_string = to_string(dir)

    case File.mkdir_p(dir_string) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Could not create Mnesia directory: #{inspect(reason)}")
    end
  end

  defp ensure_schema do
    nodes = [node()]
    dir = Application.get_env(:mnesia, :dir) || ~c".mnesia/#{node()}"
    schema_file = Path.join(to_string(dir), "schema.DAT")

    unless File.exists?(schema_file) do
      :mnesia.stop()
      :mnesia.create_schema(nodes)
    end
  end

  defp storage_type_for_env do
    case node() do
      :nonode@nohost -> :ram_copies
      _ -> :disc_copies
    end
  end

  defp backup_dir do
    Path.join([File.cwd!(), ".mnesia", "backups"])
  end

  defp table_to_key(Workflow), do: :workflows
  defp table_to_key(Event), do: :events
  defp table_to_key(Idempotency), do: :idempotency
  defp table_to_key(DeadLetterEntry), do: :dlq

  defp key_to_table(:workflows), do: Workflow
  defp key_to_table(:events), do: Event
  defp key_to_table(:idempotency), do: Idempotency
  defp key_to_table(:dlq), do: DeadLetterEntry
  defp key_to_table("workflows"), do: Workflow
  defp key_to_table("events"), do: Event
  defp key_to_table("idempotency"), do: Idempotency
  defp key_to_table("dlq"), do: DeadLetterEntry

  defp count_backup_records(backup) do
    backup.tables
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp convert_to_json_safe(backup) do
    %{
      "timestamp" => DateTime.to_iso8601(backup.timestamp),
      "node" => to_string(backup.node),
      "tables" => Map.new(backup.tables, fn {k, v} ->
        {to_string(k), Enum.map(v, &struct_to_map/1)}
      end)
    }
  end

  defp struct_to_map(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(atom) when is_atom(atom), do: to_string(atom)
  defp serialize_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end
  defp serialize_value(list) when is_list(list), do: Enum.map(list, &serialize_value/1)
  defp serialize_value(other), do: other

  defp convert_from_json(data) do
    %{
      timestamp: parse_datetime(data["timestamp"]),
      node: String.to_atom(data["node"]),
      tables: Map.new(data["tables"], fn {k, v} ->
        table = key_to_table(k)
        {String.to_atom(k), Enum.map(v, &(map_to_struct(table, &1)))}
      end)
    }
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp map_to_struct(table, map) do
    attrs = Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      value = deserialize_value(key, v)
      {key, value}
    end)

    struct(table, attrs)
  end

  defp deserialize_value(key, value) when key in [:started_at, :completed_at, :created_at, :updated_at, :inserted_at, :timestamp, :next_retry_at] do
    case value do
      nil -> nil
      str when is_binary(str) -> parse_datetime(str)
      other -> other
    end
  end
  defp deserialize_value(:status, value) when is_binary(value), do: String.to_atom(value)
  defp deserialize_value(:type, value) when is_binary(value), do: String.to_atom(value)
  defp deserialize_value(:event_type, value) when is_binary(value), do: String.to_atom(value)
  defp deserialize_value(_key, value), do: value
end
