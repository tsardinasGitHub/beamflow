defmodule Beamflow.Engine.Registry do
  @moduledoc """
  Registry para procesos de workflow.

  Proporciona un mecanismo de naming distribuido para los procesos
  `WorkflowActor`, permitiendo localizar workflows por su ID string
  en lugar de PID.

  ## Uso

  Este registry se inicia automáticamente como parte del árbol de
  supervisión de la aplicación. Los workflows se registran usando
  `via_tuple/1`:

      # En WorkflowActor.start_link
      GenServer.start_link(__MODULE__, args, name: Registry.via_tuple("wf-123"))

      # Para localizar un workflow
      [{pid, _value}] = Registry.lookup("wf-123")

  ## Implementación

  Utiliza el módulo `Registry` de Elixir con claves únicas (`:unique`),
  garantizando que solo puede existir un workflow con cada ID.
  """

  @doc """
  Especificación de child para el árbol de supervisión.

  Define cómo debe iniciarse el Registry bajo un Supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__
    )
  end

  @doc """
  Genera una tupla `via` para registrar o localizar un proceso.

  Esta tupla se usa como opción `:name` en `GenServer.start_link/3`
  y permite acceder al proceso por su ID de workflow.

  ## Parámetros

    * `id` - Identificador único del workflow

  ## Retorno

  Tupla en formato `{:via, Registry, {module, id}}`.

  ## Ejemplo

      iex> via_tuple("order-123")
      {:via, Registry, {Beamflow.Engine.Registry, "order-123"}}
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(id) do
    {:via, Registry, {__MODULE__, id}}
  end

  @doc """
  Busca un proceso por su ID de workflow.

  ## Parámetros

    * `id` - Identificador del workflow

  ## Retorno

    * `[{pid, value}]` - Lista con el proceso encontrado
    * `[]` - Lista vacía si no existe

  ## Ejemplo

      iex> lookup("order-123")
      [{#PID<0.123.0>, nil}]

      iex> lookup("no-existe")
      []
  """
  @spec lookup(String.t()) :: [{pid(), term()}]
  def lookup(id) do
    Registry.lookup(__MODULE__, id)
  end
end
