defmodule Beamflow.Database.Setup do
  @moduledoc """
  Módulo de inicialización para la base de datos Amnesia.

  Este módulo maneja la creación y configuración de tablas,
  incluyendo lógica de inicialización y verificación.

  ## Uso en Producción

      # En Application.start/2
      Beamflow.Database.Setup.init()

  ## Desarrollo / Tests

      # Forzar recreación
      Beamflow.Database.Setup.reset!()
  """

  use Amnesia
  require Logger

  alias Beamflow.Database.Workflow
  alias Beamflow.Database.Event
  alias Beamflow.Database.Idempotency
  alias Beamflow.Database.DeadLetterEntry

  @tables [Workflow, Event, Idempotency, DeadLetterEntry]

  # ============================================================================
  # Inicialización Principal
  # ============================================================================

  @doc """
  Inicializa la base de datos Amnesia.

  Crea el schema y las tablas si no existen.
  Esta función es idempotente y segura para llamar múltiples veces.

  ## Opciones

    - `:force` - Borra y recrea tablas existentes (default: false)
    - `:disk` - Usa disc_copies en lugar de ram_copies (default: false)

  ## Ejemplo

      Beamflow.Database.Setup.init()
      Beamflow.Database.Setup.init(disk: true)
      Beamflow.Database.Setup.init(force: true)
  """
  @spec init(keyword()) :: :ok | {:error, term()}
  def init(opts \\ []) do
    force = Keyword.get(opts, :force, false)
    disk = Keyword.get(opts, :disk, false) or named_node?()

    Logger.info("[Database.Setup] Iniciando setup (force=#{force}, disk=#{disk})")

    # Paso 1: Iniciar Mnesia si no está corriendo
    :ok = ensure_mnesia_running()

    # Paso 2: Crear schema en disco si es necesario
    if disk do
      create_disk_schema()
    end

    # Paso 3: Crear tablas
    result = if force do
      create_tables_force(disk)
    else
      create_tables_if_missing(disk)
    end

    # Paso 4: Esperar a que las tablas estén listas
    wait_for_tables()

    Logger.info("[Database.Setup] Setup completado: #{inspect(result)}")
    :ok
  rescue
    e ->
      Logger.error("[Database.Setup] Error en inicialización: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Resetea la base de datos borrando todas las tablas y recreándolas.

  ¡PELIGRO! Esto borra todos los datos.
  """
  @spec reset!(keyword()) :: :ok
  def reset!(opts \\ []) do
    Logger.warning("[Database.Setup] ⚠️  Reseteando base de datos...")

    # Detener Mnesia
    :mnesia.stop()

    # Borrar schema
    :mnesia.delete_schema([node()])

    # Reiniciar e inicializar
    init(Keyword.put(opts, :force, true))
  end

  @doc """
  Verifica el estado de la base de datos.
  """
  @spec status() :: map()
  def status do
    running = :mnesia.system_info(:is_running) == :yes

    tables_status = if running do
      @tables
      |> Enum.map(fn table ->
        exists = table_exists?(table)
        count = if exists, do: table_count(table), else: 0
        {table, %{exists: exists, count: count}}
      end)
      |> Map.new()
    else
      %{}
    end

    %{
      mnesia_running: running,
      node: node(),
      directory: :mnesia.system_info(:directory),
      tables: tables_status
    }
  end

  @doc """
  Lista las tablas configuradas.
  """
  @spec tables() :: [module()]
  def tables, do: @tables

  # ============================================================================
  # Funciones de Inicialización
  # ============================================================================

  defp ensure_mnesia_running do
    case :mnesia.system_info(:is_running) do
      :yes ->
        Logger.debug("[Database.Setup] Mnesia ya está corriendo")
        :ok

      :no ->
        Logger.info("[Database.Setup] Iniciando Mnesia...")
        :ok = :mnesia.start()
        :ok

      :stopping ->
        Process.sleep(100)
        ensure_mnesia_running()

      :starting ->
        Process.sleep(100)
        ensure_mnesia_running()
    end
  end

  defp create_disk_schema do
    case :mnesia.create_schema([node()]) do
      :ok ->
        Logger.info("[Database.Setup] Schema de disco creado")
        :ok

      {:error, {_, {:already_exists, _}}} ->
        Logger.debug("[Database.Setup] Schema ya existe")
        :ok

      {:error, reason} ->
        Logger.warning("[Database.Setup] No se pudo crear schema: #{inspect(reason)}")
        :ok
    end
  end

  defp create_tables_if_missing(disk) do
    @tables
    |> Enum.map(fn table ->
      if table_exists?(table) do
        Logger.debug("[Database.Setup] Tabla #{inspect(table)} ya existe")
        {:ok, :exists}
      else
        create_table(table, disk)
      end
    end)
  end

  defp create_tables_force(disk) do
    # Borrar tablas existentes
    Enum.each(@tables, fn table ->
      if table_exists?(table) do
        :mnesia.delete_table(table)
        Logger.debug("[Database.Setup] Tabla #{inspect(table)} eliminada")
      end
    end)

    # Crear nuevas
    Enum.map(@tables, fn table ->
      create_table(table, disk)
    end)
  end

  defp create_table(table, disk) do
    storage_type = if disk, do: :disc_copies, else: :ram_copies

    # Usar create de Amnesia
    case table.create([{storage_type, [node()]}]) do
      :ok ->
        Logger.info("[Database.Setup] Tabla #{inspect(table)} creada (#{storage_type})")
        {:ok, :created}

      {:error, {:already_exists, _}} ->
        Logger.debug("[Database.Setup] Tabla #{inspect(table)} ya existía")
        {:ok, :exists}

      {:error, reason} ->
        Logger.error("[Database.Setup] Error creando #{inspect(table)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp wait_for_tables do
    tables = Enum.map(@tables, & &1)
    timeout = 30_000

    Logger.debug("[Database.Setup] Esperando tablas: #{inspect(tables)}")

    case :mnesia.wait_for_tables(tables, timeout) do
      :ok ->
        Logger.debug("[Database.Setup] Todas las tablas listas")
        :ok

      {:timeout, pending} ->
        Logger.warning("[Database.Setup] Timeout esperando tablas: #{inspect(pending)}")
        {:error, {:timeout, pending}}

      {:error, reason} ->
        Logger.error("[Database.Setup] Error esperando tablas: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp table_exists?(table) do
    table in :mnesia.system_info(:tables)
  end

  defp table_count(table) do
    :mnesia.table_info(table, :size)
  rescue
    _ -> 0
  end

  defp named_node? do
    node_name = node() |> Atom.to_string()
    not String.starts_with?(node_name, "nonode@")
  end
end
