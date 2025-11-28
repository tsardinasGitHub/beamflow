defmodule Beamflow.Workflows.Graph do
  @moduledoc """
  Representa un workflow como un grafo dirigido con soporte para branching.

  Este módulo permite definir workflows no lineales con:
  - **Secuencias**: Steps que van uno tras otro
  - **Branches**: Bifurcaciones condicionales basadas en el estado
  - **Joins**: Puntos de convergencia después de branches

  ## Estructura del Grafo

  Un grafo de workflow se representa como:

  ```elixir
  %Graph{
    nodes: %{
      "validate" => %Node{id: "validate", module: ValidateIdentity, type: :step},
      "decision" => %Node{id: "decision", type: :branch, condition: &(&1.approved)},
      ...
    },
    edges: %{
      "validate" => ["check_credit"],
      "decision" => [{"approved_path", true}, {"rejected_path", false}],
      ...
    },
    start_node: "validate",
    end_nodes: ["close_case"]
  }
  ```

  ## Compatibilidad con Workflows Lineales

  Los workflows que definen `steps/0` como lista simple se convierten
  automáticamente a un grafo lineal:

  ```elixir
  [Step1, Step2, Step3]
  # Se convierte a:
  # Step1 → Step2 → Step3
  ```

  Ver ADR-005 para la justificación de este diseño.
  """

  alias __MODULE__

  defstruct nodes: %{},
            edges: %{},
            start_node: nil,
            end_nodes: []

  @type node_id :: String.t()
  @type condition :: (map() -> boolean())

  @type graph_node :: %{
          id: node_id(),
          module: module() | nil,
          type: :step | :branch | :join | :start | :end,
          condition: condition() | nil,
          label: String.t() | nil
        }

  @type edge :: node_id() | {node_id(), boolean() | atom()}

  @type t :: %Graph{
          nodes: %{node_id() => graph_node()},
          edges: %{node_id() => [edge()]},
          start_node: node_id() | nil,
          end_nodes: [node_id()]
        }

  # ============================================================================
  # Construcción del Grafo
  # ============================================================================

  @doc """
  Crea un grafo vacío.
  """
  @spec new() :: t()
  def new do
    %Graph{}
  end

  @doc """
  Convierte una lista lineal de steps a un grafo.

  Mantiene retrocompatibilidad con workflows que usan `steps/0` como lista.

  ## Ejemplo

      iex> Graph.from_linear_steps([Step1, Step2, Step3])
      %Graph{
        nodes: %{
          "step_0" => %{id: "step_0", module: Step1, type: :step},
          "step_1" => %{id: "step_1", module: Step2, type: :step},
          "step_2" => %{id: "step_2", module: Step3, type: :step}
        },
        edges: %{
          "step_0" => ["step_1"],
          "step_1" => ["step_2"]
        },
        start_node: "step_0",
        end_nodes: ["step_2"]
      }
  """
  @spec from_linear_steps([module()]) :: t()
  def from_linear_steps([]), do: new()

  def from_linear_steps(steps) when is_list(steps) do
    nodes =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {module, idx} ->
        id = "step_#{idx}"
        {id, %{id: id, module: module, type: :step, condition: nil, label: inspect(module)}}
      end)
      |> Map.new()

    edges =
      steps
      |> Enum.with_index()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{_mod1, idx1}, {_mod2, idx2}] ->
        {"step_#{idx1}", ["step_#{idx2}"]}
      end)
      |> Map.new()

    last_idx = length(steps) - 1

    %Graph{
      nodes: nodes,
      edges: edges,
      start_node: "step_0",
      end_nodes: ["step_#{last_idx}"]
    }
  end

  @doc """
  Agrega un nodo step al grafo.
  """
  @spec add_step(t(), node_id(), module(), keyword()) :: t()
  def add_step(graph, id, module, opts \\ []) do
    node = %{
      id: id,
      module: module,
      type: :step,
      condition: nil,
      label: Keyword.get(opts, :label, inspect(module))
    }

    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  @doc """
  Agrega un nodo branch (bifurcación condicional) al grafo.
  """
  @spec add_branch(t(), node_id(), condition(), keyword()) :: t()
  def add_branch(graph, id, condition, opts \\ []) do
    node = %{
      id: id,
      module: nil,
      type: :branch,
      condition: condition,
      label: Keyword.get(opts, :label, "branch:#{id}")
    }

    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  @doc """
  Agrega un nodo join (convergencia) al grafo.
  """
  @spec add_join(t(), node_id(), keyword()) :: t()
  def add_join(graph, id, opts \\ []) do
    node = %{
      id: id,
      module: nil,
      type: :join,
      condition: nil,
      label: Keyword.get(opts, :label, "join:#{id}")
    }

    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  @doc """
  Conecta dos nodos con una arista.
  """
  @spec connect(t(), node_id(), node_id()) :: t()
  def connect(graph, from_id, to_id) do
    edges = Map.update(graph.edges, from_id, [to_id], &[to_id | &1])
    %{graph | edges: edges}
  end

  @doc """
  Conecta un nodo branch a un destino con una condición.
  """
  @spec connect_branch(t(), node_id(), node_id(), boolean() | atom()) :: t()
  def connect_branch(graph, from_id, to_id, condition_result) do
    edge = {to_id, condition_result}
    edges = Map.update(graph.edges, from_id, [edge], &[edge | &1])
    %{graph | edges: edges}
  end

  @doc """
  Establece el nodo inicial del grafo.
  """
  @spec set_start(t(), node_id()) :: t()
  def set_start(graph, node_id) do
    %{graph | start_node: node_id}
  end

  @doc """
  Marca un nodo como nodo final.
  """
  @spec set_end(t(), node_id()) :: t()
  def set_end(graph, node_id) do
    %{graph | end_nodes: [node_id | graph.end_nodes] |> Enum.uniq()}
  end

  # ============================================================================
  # Navegación del Grafo
  # ============================================================================

  @doc """
  Obtiene el siguiente nodo(s) a ejecutar dado el nodo actual y el estado.

  Para nodos step: retorna el siguiente nodo en la secuencia.
  Para nodos branch: evalúa la condición y retorna el path correcto.
  Para nodos join: retorna el siguiente nodo (convergencia).
  """
  @spec next_nodes(t(), node_id(), map()) :: [node_id()]
  def next_nodes(graph, current_node_id, workflow_state) do
    node = Map.get(graph.nodes, current_node_id)
    edges = Map.get(graph.edges, current_node_id, [])

    case node.type do
      :step ->
        # Step normal: siguiente nodo en secuencia
        Enum.filter(edges, &is_binary/1)

      :branch ->
        # Branch: evaluar condición y seguir el path correcto
        condition_result = node.condition.(workflow_state)

        edges
        |> Enum.filter(fn
          {_target, result} -> result == condition_result
          _ -> false
        end)
        |> Enum.map(fn {target, _} -> target end)

      :join ->
        # Join: simplemente continuar al siguiente
        Enum.filter(edges, &is_binary/1)

      _ ->
        []
    end
  end

  @doc """
  Obtiene un nodo por su ID.
  """
  @spec get_node(t(), node_id()) :: graph_node() | nil
  def get_node(graph, node_id) do
    Map.get(graph.nodes, node_id)
  end

  @doc """
  Verifica si un nodo es terminal (fin del workflow).
  """
  @spec is_end_node?(t(), node_id()) :: boolean()
  def is_end_node?(graph, node_id) do
    node_id in graph.end_nodes or Map.get(graph.edges, node_id, []) == []
  end

  @doc """
  Retorna la lista de todos los nodos step (módulos a ejecutar).
  """
  @spec step_modules(t()) :: [module()]
  def step_modules(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :step))
    |> Enum.map(& &1.module)
  end

  @doc """
  Cuenta el número total de steps ejecutables.
  """
  @spec count_steps(t()) :: non_neg_integer()
  def count_steps(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.count(&(&1.type == :step))
  end
end
