defmodule Beamflow.Storage.MnesiaSetup do
  @moduledoc """
  Configuración e inicialización de Mnesia para Beamflow.

  Este módulo gestiona la creación del schema y tablas de Mnesia,
  proporcionando persistencia distribuida sin dependencias externas.

  ## ¿Por qué Mnesia?

  - Integrado en OTP, sin dependencias externas
  - Soporte nativo para distribución y replicación
  - Ideal para demostrar conocimiento profundo de Erlang/OTP
  - Persistencia transparente con disc_copies

  ## Tipos de Almacenamiento

  El tipo de almacenamiento depende del nombre del nodo:

  | Nodo | Comando | Tipo | Persistencia |
  |------|---------|------|--------------|
  | Anónimo | `iex -S mix` | `ram_copies` | ❌ Solo RAM |
  | Nombrado | `iex --sname beamflow -S mix` | `disc_copies` | ✅ Disco |

  ## Uso

      # Con nodo nombrado (persistencia en disco)
      iex --sname beamflow -S mix run -e "Beamflow.Storage.MnesiaSetup.install()"

      # O al iniciar la aplicación (crea tablas si no existen)
      Beamflow.Storage.MnesiaSetup.ensure_tables()

  ## Tablas

  - `:beamflow_workflows` - Estado de cada workflow
    - Atributos: id, workflow_module, status, workflow_state, current_step_index,
      total_steps, started_at, completed_at, error, inserted_at, updated_at
    - Tipo: disc_copies (con nodo nombrado) o ram_copies (sin nombre)
    - Índices: status

  - `:beamflow_events` - Historial de eventos de cada workflow
    - Atributos: id, workflow_id, event_type, data, timestamp
    - Tipo: disc_copies (con nodo nombrado) o ram_copies (sin nombre)
    - Índices: workflow_id, event_type

  Ver ADR-001 para justificación detallada de esta decisión arquitectónica.
  """

  require Logger

  # Nombres de tablas
  @workflows_table :beamflow_workflows
  @events_table :beamflow_events
  @idempotency_table :beamflow_idempotency
  @dlq_table :beamflow_dlq

  @doc """
  Instala el schema y tablas de Mnesia.

  Debe ejecutarse una única vez antes de iniciar la aplicación.
  Crea el schema en el nodo actual y las tablas necesarias.

  ## Retorno

  Retorna `:ok` implícitamente. Los errores se registran en Logger.

  ## Ejemplo

      iex> Beamflow.Storage.MnesiaSetup.install()
      :ok

  """
  @spec install() :: :ok
  def install do
    nodes = [node()]

    # 1. Detener Mnesia si está corriendo
    :mnesia.stop()

    # 2. Asegurar que el directorio de Mnesia existe
    ensure_mnesia_dir()

    # 3. Crear schema
    case :mnesia.create_schema(nodes) do
      :ok ->
        Logger.info("Mnesia schema created successfully.")

      {:error, {_node, {:already_exists, _}}} ->
        Logger.info("Mnesia schema already exists.")

      {:error, reason} ->
        Logger.error("Failed to create Mnesia schema: #{inspect(reason)}")
    end

    # 3. Iniciar Mnesia
    :mnesia.start()

    # 4. Crear tablas
    create_workflows_table(nodes)
    create_events_table(nodes)
    create_idempotency_table(nodes)
    create_dlq_table(nodes)

    # 5. Esperar a que las tablas estén listas
    all_tables = [@workflows_table, @events_table, @idempotency_table, @dlq_table]
    :mnesia.wait_for_tables(all_tables, 5000)

    Logger.info("Mnesia setup completed. Tables: #{inspect(all_tables)}")

    # 6. Detener Mnesia para que Application lo inicie
    :mnesia.stop()

    :ok
  end

  @doc """
  Asegura que las tablas existen. Crea las que falten.

  Útil para inicialización automática durante el arranque de la aplicación.
  No requiere detener Mnesia.

  ## Retorno

    * `:ok` - Tablas disponibles
    * `{:error, reason}` - Error al crear tablas
  """
  @spec ensure_tables() :: :ok | {:error, term()}
  def ensure_tables do
    nodes = [node()]

    # Asegurar que el directorio existe (importante para disc_copies)
    ensure_mnesia_dir()

    # Si vamos a usar disc_copies, necesitamos schema en disco
    # Esto es idempotente - no falla si ya existe
    ensure_disc_schema_if_needed(nodes)

    existing_tables = :mnesia.system_info(:tables)

    # Crear tabla de workflows si no existe
    unless @workflows_table in existing_tables do
      create_workflows_table(nodes)
    end

    # Crear tabla de eventos si no existe
    unless @events_table in existing_tables do
      create_events_table(nodes)
    end

    # Crear tabla de idempotencia si no existe
    unless @idempotency_table in existing_tables do
      create_idempotency_table(nodes)
    end

    # Crear tabla de DLQ si no existe
    unless @dlq_table in existing_tables do
      create_dlq_table(nodes)
    end

    # Esperar a que estén listas
    all_tables = [@workflows_table, @events_table, @idempotency_table, @dlq_table]

    case :mnesia.wait_for_tables(all_tables, 10_000) do
      :ok ->
        Logger.info("Mnesia tables ready: #{inspect(all_tables)}")
        :ok

      {:timeout, tables} ->
        Logger.error("Timeout waiting for Mnesia tables: #{inspect(tables)}")
        {:error, {:timeout, tables}}

      {:error, reason} ->
        Logger.error("Error waiting for Mnesia tables: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Elimina todas las tablas de Beamflow.

  ⚠️ PELIGRO: Esta operación es irreversible.

  ## Retorno

    * `:ok` - Tablas eliminadas
    * `{:error, reason}` - Error al eliminar
  """
  @spec drop_tables() :: :ok | {:error, term()}
  def drop_tables do
    results =
      [@workflows_table, @events_table, @idempotency_table, @dlq_table]
      |> Enum.map(fn table ->
        case :mnesia.delete_table(table) do
          {:atomic, :ok} ->
            Logger.info("Table #{table} deleted")
            :ok

          {:aborted, {:no_exists, _}} ->
            Logger.info("Table #{table} does not exist")
            :ok

          {:aborted, reason} ->
            Logger.error("Failed to delete table #{table}: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, :partial_failure}
    end
  end

  @doc """
  Reinicia las tablas (drop + create).

  ⚠️ PELIGRO: Elimina todos los datos existentes.
  """
  @spec reset_tables() :: :ok | {:error, term()}
  def reset_tables do
    :ok = drop_tables()
    ensure_tables()
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp create_workflows_table(nodes) do
    # Atributos del registro de workflow
    attributes = [
      :id,
      :workflow_module,
      :status,
      :workflow_state,
      :current_step_index,
      :total_steps,
      :started_at,
      :completed_at,
      :error,
      :inserted_at,
      :updated_at
    ]

    # Usar ram_copies en desarrollo para evitar problemas con nodos anónimos
    # En producción, usar disc_copies con nodos nombrados
    storage_type = storage_type_for_env()

    table_opts = [
      attributes: attributes,
      type: :set
    ] ++ storage_opts(storage_type, nodes)

    case :mnesia.create_table(@workflows_table, table_opts) do
      {:atomic, :ok} ->
        Logger.info("Table '#{@workflows_table}' created with #{storage_type}")
        create_index(@workflows_table, :status)

      {:aborted, {:already_exists, _}} ->
        Logger.debug("Table '#{@workflows_table}' already exists")

      {:aborted, reason} ->
        Logger.error("Failed to create table '#{@workflows_table}': #{inspect(reason)}")
    end
  end

  defp create_events_table(nodes) do
    attributes = [
      :id,
      :workflow_id,
      :event_type,
      :data,
      :timestamp
    ]

    storage_type = storage_type_for_env()

    table_opts = [
      attributes: attributes,
      type: :bag  # Múltiples eventos por workflow_id
    ] ++ storage_opts(storage_type, nodes)

    case :mnesia.create_table(@events_table, table_opts) do
      {:atomic, :ok} ->
        Logger.info("Table '#{@events_table}' created with #{storage_type}")
        create_index(@events_table, :workflow_id)
        create_index(@events_table, :event_type)

      {:aborted, {:already_exists, _}} ->
        Logger.debug("Table '#{@events_table}' already exists")

      {:aborted, reason} ->
        Logger.error("Failed to create table '#{@events_table}': #{inspect(reason)}")
    end
  end

  defp create_idempotency_table(nodes) do
    # Tabla para garantizar idempotencia de steps
    # Almacena estado de ejecución para recuperación ante crashes
    attributes = [
      :key,           # "{workflow_id}:{step}:{attempt}"
      :status,        # :pending | :completed | :failed
      :started_at,    # DateTime inicio
      :completed_at,  # DateTime fin (nil si pending)
      :result,        # Resultado del step (map)
      :error          # Error si falló
    ]

    storage_type = storage_type_for_env()

    table_opts = [
      attributes: attributes,
      type: :set
    ] ++ storage_opts(storage_type, nodes)

    case :mnesia.create_table(@idempotency_table, table_opts) do
      {:atomic, :ok} ->
        Logger.info("Table '#{@idempotency_table}' created with #{storage_type}")
        create_index(@idempotency_table, :status)

      {:aborted, {:already_exists, _}} ->
        Logger.debug("Table '#{@idempotency_table}' already exists")

      {:aborted, reason} ->
        Logger.error("Failed to create table '#{@idempotency_table}': #{inspect(reason)}")
    end
  end

  defp create_dlq_table(nodes) do
    # Tabla para Dead Letter Queue
    # Almacena workflows que fallaron para reprocesamiento
    attributes = [
      :id,            # ID único del entry DLQ
      :data           # Map con todos los datos del entry
    ]

    storage_type = storage_type_for_env()

    table_opts = [
      attributes: attributes,
      type: :set
    ] ++ storage_opts(storage_type, nodes)

    case :mnesia.create_table(@dlq_table, table_opts) do
      {:atomic, :ok} ->
        Logger.info("Table '#{@dlq_table}' created with #{storage_type}")

      {:aborted, {:already_exists, _}} ->
        Logger.debug("Table '#{@dlq_table}' already exists")

      {:aborted, reason} ->
        Logger.error("Failed to create table '#{@dlq_table}': #{inspect(reason)}")
    end
  end

  defp create_index(table, attribute) do
    case :mnesia.add_table_index(table, attribute) do
      {:atomic, :ok} ->
        Logger.debug("Index on #{table}.#{attribute} created")

      {:aborted, {:already_exists, _, _}} ->
        :ok

      {:aborted, reason} ->
        Logger.warning("Failed to create index on #{table}.#{attribute}: #{inspect(reason)}")
    end
  end

  @doc """
  Determina el tipo de almacenamiento según el entorno.

  - `:disc_copies` - Nodo con nombre (persistencia en disco)
  - `:ram_copies` - Nodo anónimo (solo memoria, sin persistencia)

  ## Ejemplo

      iex> MnesiaSetup.storage_type_for_env()
      :ram_copies  # En nodo anónimo (nonode@nohost)

      iex> MnesiaSetup.storage_type_for_env()
      :disc_copies  # En nodo nombrado (beamflow@hostname)
  """
  @spec storage_type_for_env() :: :ram_copies | :disc_copies
  def storage_type_for_env do
    # Si el nodo no tiene nombre (nonode@nohost), usamos ram_copies
    # porque disc_copies requiere un nodo nombrado
    case node() do
      :nonode@nohost -> :ram_copies
      _ -> :disc_copies
    end
  end

  defp storage_opts(:ram_copies, nodes), do: [ram_copies: nodes]
  defp storage_opts(:disc_copies, nodes), do: [disc_copies: nodes]

  # Asegura que el directorio de Mnesia existe
  defp ensure_mnesia_dir do
    # Obtener el directorio configurado o usar el default
    dir = Application.get_env(:mnesia, :dir) || ~c".mnesia/#{node()}"
    dir_string = to_string(dir)

    case File.mkdir_p(dir_string) do
      :ok ->
        Logger.debug("Mnesia directory ensured: #{dir_string}")

      {:error, reason} ->
        Logger.warning("Could not create Mnesia directory #{dir_string}: #{inspect(reason)}")
    end
  end

  # Crea el schema en disco si es necesario para disc_copies
  # Debe llamarse ANTES de iniciar Mnesia o cuando Mnesia está detenido
  defp ensure_disc_schema_if_needed(nodes) do
    # Solo necesario para disc_copies
    if storage_type_for_env() == :disc_copies do
      # Verificar si ya existe schema en disco
      dir = Application.get_env(:mnesia, :dir) || ~c".mnesia/#{node()}"
      schema_file = Path.join(to_string(dir), "schema.DAT")

      unless File.exists?(schema_file) do
        Logger.info("Creating disc schema for Mnesia...")

        # Detener Mnesia temporalmente para crear schema
        :mnesia.stop()

        case :mnesia.create_schema(nodes) do
          :ok ->
            Logger.info("Mnesia disc schema created successfully")

          {:error, {_, {:already_exists, _}}} ->
            Logger.debug("Mnesia schema already exists")

          {:error, reason} ->
            Logger.warning("Could not create disc schema: #{inspect(reason)}")
        end

        # Reiniciar Mnesia
        :mnesia.start()
      end
    end
  end
end
