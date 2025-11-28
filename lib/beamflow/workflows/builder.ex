defmodule Beamflow.Workflows.Builder do
  @moduledoc """
  Constructor de grafos de workflow desde definiciones declarativas.

  Este módulo transforma las definiciones de workflow (lineales o con branching)
  en estructuras de grafo ejecutables por el `WorkflowActor`.

  ## Funcionalidad Principal

  - Detecta si un workflow usa branching o es lineal
  - Construye el grafo apropiado para cada caso
  - Provee utilidades para navegación del workflow

  ## Ejemplo

      # Workflow lineal
      graph = Builder.build(LinearWorkflow)
      # => Grafo secuencial simple

      # Workflow con branching
      graph = Builder.build(BranchingWorkflow)
      # => Grafo con nodos de decisión y múltiples paths

  Ver ADR-005 para la justificación de este diseño.
  """

  alias Beamflow.Workflows.Graph

  @doc """
  Construye el grafo de un workflow.

  Detecta automáticamente si el workflow usa branching o es lineal.
  """
  @spec build(module()) :: Graph.t()
  def build(workflow_module) do
    # Asegurar que el módulo esté cargado antes de verificar funciones
    Code.ensure_loaded!(workflow_module)

    cond do
      # Nuevo estilo: tiene función graph/0
      function_exported?(workflow_module, :graph, 0) ->
        workflow_module.graph()

      # Estilo legacy: solo tiene steps/0 como lista
      function_exported?(workflow_module, :steps, 0) ->
        steps = workflow_module.steps()
        Graph.from_linear_steps(steps)

      true ->
        raise ArgumentError, "#{inspect(workflow_module)} must implement steps/0 or graph/0"
    end
  end

  @doc """
  Verifica si un workflow tiene branching.
  """
  @spec has_branching?(module()) :: boolean()
  def has_branching?(workflow_module) do
    Code.ensure_loaded!(workflow_module)

    if function_exported?(workflow_module, :has_branching?, 0) do
      workflow_module.has_branching?()
    else
      false
    end
  end

  @doc """
  Obtiene el siguiente nodo a ejecutar en un workflow.

  Para workflows lineales: simplemente el siguiente índice.
  Para workflows con branching: evalúa condiciones para determinar el path.
  """
  @spec get_next_step(Graph.t(), String.t(), map()) :: {:ok, Graph.graph_node()} | :end | {:error, term()}
  def get_next_step(graph, current_node_id, workflow_state) do
    next_nodes = Graph.next_nodes(graph, current_node_id, workflow_state)

    case next_nodes do
      [] ->
        :end

      [next_id] ->
        node = Graph.get_node(graph, next_id)

        case node.type do
          :step ->
            {:ok, node}

          :branch ->
            # Evaluar branch y obtener siguiente step
            evaluate_branch_and_continue(graph, node, workflow_state)

          :join ->
            # Skip join node, ir al siguiente
            get_next_step(graph, next_id, workflow_state)

          _ ->
            {:error, :unknown_node_type}
        end

      multiple when is_list(multiple) ->
        # Múltiples siguientes (error en diseño o paralelo futuro)
        {:error, {:multiple_next_nodes, multiple}}
    end
  end

  @doc """
  Obtiene el step inicial de un workflow.
  """
  @spec get_start_step(Graph.t()) :: {:ok, Graph.graph_node()} | {:error, term()}
  def get_start_step(graph) do
    case graph.start_node do
      nil ->
        {:error, :no_start_node}

      start_id ->
        node = Graph.get_node(graph, start_id)

        if node do
          {:ok, node}
        else
          {:error, :start_node_not_found}
        end
    end
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp evaluate_branch_and_continue(graph, branch_node, workflow_state) do
    next_nodes = Graph.next_nodes(graph, branch_node.id, workflow_state)

    case next_nodes do
      [] ->
        {:error, {:no_branch_path_matched, branch_node.id}}

      [next_id] ->
        node = Graph.get_node(graph, next_id)

        case node.type do
          :step -> {:ok, node}
          :branch -> evaluate_branch_and_continue(graph, node, workflow_state)
          :join -> get_next_step(graph, next_id, workflow_state)
          _ -> {:error, :unknown_node_type}
        end

      _ ->
        {:error, :multiple_branch_paths}
    end
  end
end
