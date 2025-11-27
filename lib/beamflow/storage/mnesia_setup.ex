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

  ## Uso

      # Ejecutar una sola vez para crear schema y tablas
      Beamflow.Storage.MnesiaSetup.install()

  ## Tablas

  - `:workflows` - Almacena definiciones y estado de workflows
    - Atributos: id, status, data, inserted_at, updated_at
    - Tipo: disc_copies (persistencia en disco)

  Ver ADR-001 para justificación detallada de esta decisión arquitectónica.
  """

  require Logger

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
    # 1. Create the schema on this node
    nodes = [node()]

    case :mnesia.create_schema(nodes) do
      :ok -> Logger.info("Mnesia schema created successfully.")
      {:error, {node, {:already_exists, node}}} -> Logger.info("Mnesia schema already exists.")
      {:error, reason} -> Logger.error("Failed to create Mnesia schema: #{inspect(reason)}")
    end

    # 2. Start Mnesia to create tables
    :mnesia.start()

    # 3. Create tables
    create_workflow_table(nodes)

    # 4. Stop Mnesia so it can be started by the Application supervisor later
    :mnesia.stop()
  end

  defp create_workflow_table(nodes) do
    # Assuming we store workflows. Adjust attributes as per your Workflow struct.
    # For now, using a simple structure: {id, state, ...}
    # We will use :disc_copies for persistence.

    table_name = :workflows
    # Example attributes
    attributes = [:id, :status, :data, :inserted_at, :updated_at]

    case :mnesia.create_table(table_name, attributes: attributes, disc_copies: nodes) do
      {:atomic, :ok} ->
        Logger.info("Table '#{table_name}' created.")

      {:aborted, {:already_exists, _}} ->
        Logger.info("Table '#{table_name}' already exists.")

      {:aborted, reason} ->
        Logger.error("Failed to create table '#{table_name}': #{inspect(reason)}")
    end
  end
end
