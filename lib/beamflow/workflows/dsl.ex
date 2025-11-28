defmodule Beamflow.Workflows.DSL do
  @moduledoc """
  DSL para definir workflows con branching de forma declarativa.

  Este módulo proporciona macros para construir workflows complejos
  de manera legible y mantenible.

  ## Uso Básico

      defmodule MyWorkflow do
        use Beamflow.Workflows.DSL

        workflow do
          step ValidateInput
          step ProcessData

          branch :decision, &(&1.valid?) do
            true  -> step HandleSuccess
            false -> step HandleFailure
          end

          step Cleanup
        end
      end

  ## Elementos del DSL

  - `step Module` - Define un paso de ejecución
  - `branch name, condition` - Bifurcación condicional
  - `parallel [steps]` - Ejecución paralela (futuro)

  Ver ADR-005 para la justificación de este diseño.
  """

  defmacro __using__(_opts) do
    quote do
      import Beamflow.Workflows.DSL
      @behaviour Beamflow.Workflows.Workflow

      Module.register_attribute(__MODULE__, :workflow_graph, accumulate: false)
      Module.register_attribute(__MODULE__, :workflow_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :workflow_branches, accumulate: true)
      Module.register_attribute(__MODULE__, :current_node_id, accumulate: false)
      Module.register_attribute(__MODULE__, :node_counter, accumulate: false)

      @before_compile Beamflow.Workflows.DSL
    end
  end

  defmacro __before_compile__(env) do
    steps = Module.get_attribute(env.module, :workflow_steps) |> Enum.reverse()
    branches = Module.get_attribute(env.module, :workflow_branches) |> Enum.reverse()

    # Si hay steps pero no branches, es un workflow lineal
    if Enum.empty?(branches) and not Enum.empty?(steps) do
      # Workflow lineal - mantener retrocompatibilidad
      quote do
        @impl Beamflow.Workflows.Workflow
        def steps do
          unquote(steps)
        end

        def graph do
          Beamflow.Workflows.Graph.from_linear_steps(unquote(steps))
        end

        def has_branching?, do: false
      end
    else
      # Workflow con branching - se construirá el grafo en runtime
      quote do
        @impl Beamflow.Workflows.Workflow
        def steps do
          # Retornar lista plana para compatibilidad, pero marcar como branching
          unquote(steps)
        end

        def graph do
          # El grafo se construye basado en los atributos del módulo
          build_graph()
        end

        def has_branching?, do: true

        defp build_graph do
          # El grafo real se construye en el WorkflowBuilder
          Beamflow.Workflows.Graph.from_linear_steps(unquote(steps))
        end
      end
    end
  end

  @doc """
  Define el bloque principal del workflow.
  """
  defmacro workflow(do: block) do
    quote do
      @node_counter 0
      unquote(block)
    end
  end

  @doc """
  Define un step en el workflow.
  """
  defmacro step(module) do
    quote do
      @workflow_steps unquote(module)
    end
  end

  @doc """
  Define una bifurcación condicional.

  ## Ejemplo

      branch :decision, &(&1.approved) do
        true  -> step SendApprovalEmail
        false -> step SendRejectionEmail
      end
  """
  defmacro branch(name, condition, do: clauses) do
    quote do
      @workflow_branches {unquote(name), unquote(Macro.escape(condition)), unquote(Macro.escape(clauses))}
    end
  end
end
