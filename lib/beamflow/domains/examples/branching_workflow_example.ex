defmodule Beamflow.Domains.Examples.BranchingWorkflowExample do
  @moduledoc """
  Ejemplo de workflow con branching para demostrar el sistema de grafos.

  Este workflow ilustra cómo definir un grafo con múltiples paths
  basados en condiciones. Es un ejemplo educativo, no un workflow
  de producción.

  ## Flujo del Workflow

  ```
                    ┌─────────────────┐
                    │   Validación    │
                    │     Inicial     │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   Evaluación    │
                    │    de Riesgo    │
                    └────────┬────────┘
                             │
               ┌─────────────┼─────────────┐
               │             │             │
        [riesgo=bajo]  [riesgo=medio] [riesgo=alto]
               │             │             │
        ┌──────▼──────┐ ┌────▼────┐ ┌─────▼─────┐
        │  Aprobación │ │ Revisión │ │  Rechazo  │
        │  Automática │ │  Manual  │ │ Automático│
        └──────┬──────┘ └────┬────┘ └─────┬─────┘
               │             │             │
               └─────────────┼─────────────┘
                             │
                    ┌────────▼────────┐
                    │  Notificación   │
                    │     Final       │
                    └─────────────────┘
  ```

  Ver ADR-005 para la documentación del sistema de branching.
  """

  alias Beamflow.Workflows.Graph

  @doc """
  Define el grafo del workflow con branching basado en nivel de riesgo.

  ## Manejo de Branches

  El branch `risk_branch` evalúa `state.risk_level` y dirige el flujo:
  - `:low` → Aprobación automática
  - `:medium` → Revisión manual
  - `:high` → Rechazo automático
  - `:default` → Revisión manual (fallback si el nivel no es reconocido)

  El path `:default` garantiza que el workflow nunca falle por un
  valor inesperado de `risk_level`.
  """
  def graph do
    Graph.new()
    # Steps
    |> Graph.add_step("validate", __MODULE__.ValidateStep)
    |> Graph.add_step("evaluate_risk", __MODULE__.EvaluateRiskStep)
    |> Graph.add_step("auto_approve", __MODULE__.AutoApproveStep)
    |> Graph.add_step("manual_review", __MODULE__.ManualReviewStep)
    |> Graph.add_step("auto_reject", __MODULE__.AutoRejectStep)
    |> Graph.add_step("notify", __MODULE__.NotifyStep)
    # Branch node - retorna el nivel de riesgo para determinar el path
    |> Graph.add_branch("risk_branch", fn state ->
      Map.get(state, :risk_level, :medium)
    end)
    # Join node
    |> Graph.add_join("join_paths")
    # Edges - flujo principal
    |> Graph.set_start("validate")
    |> Graph.connect("validate", "evaluate_risk")
    |> Graph.connect("evaluate_risk", "risk_branch")
    # Edges - branching por riesgo (la condición retorna :low/:medium/:high)
    |> Graph.connect_branch("risk_branch", "auto_approve", :low)
    |> Graph.connect_branch("risk_branch", "manual_review", :medium)
    |> Graph.connect_branch("risk_branch", "auto_reject", :high)
    # Default path: si el risk_level no coincide con ninguno, va a manual_review
    |> Graph.connect_branch("risk_branch", "manual_review", :default)
    # Edges - join
    |> Graph.connect("auto_approve", "join_paths")
    |> Graph.connect("manual_review", "join_paths")
    |> Graph.connect("auto_reject", "join_paths")
    |> Graph.connect("join_paths", "notify")
    # Final nodes
    |> Graph.set_end("notify")
    # Validar estructura del grafo
    |> Graph.validate!()
  end

  @doc """
  Indica que este workflow tiene branching.
  """
  def has_branching?, do: true

  @doc """
  Retorna los steps como lista (para retrocompatibilidad).
  No se usa cuando graph/0 está definido.
  """
  def steps do
    raise "Este workflow usa branching, no lista lineal de steps"
  end

  # ============================================================================
  # Step Modules Embebidos (solo implementan callbacks requeridos)
  # ============================================================================

  defmodule ValidateStep do
    @moduledoc "Step de validación inicial"
    @behaviour Beamflow.Workflows.Step

    @impl true
    def execute(state), do: {:ok, Map.put(state, :validated, true)}
  end

  defmodule EvaluateRiskStep do
    @moduledoc "Step de evaluación de riesgo"
    @behaviour Beamflow.Workflows.Step

    @impl true
    def execute(state) do
      score = Map.get(state, :score, 50)

      risk_level =
        cond do
          score >= 80 -> :low
          score >= 50 -> :medium
          true -> :high
        end

      {:ok, Map.put(state, :risk_level, risk_level)}
    end
  end

  defmodule AutoApproveStep do
    @moduledoc "Step de aprobación automática para bajo riesgo"
    @behaviour Beamflow.Workflows.Step

    @impl true
    def execute(state) do
      {:ok,
       state
       |> Map.put(:approved, true)
       |> Map.put(:approval_type, :automatic)
       |> Map.put(:approved_at, DateTime.utc_now())}
    end
  end

  defmodule ManualReviewStep do
    @moduledoc "Step de revisión manual para riesgo medio"
    @behaviour Beamflow.Workflows.Step

    @impl true
    def execute(state) do
      {:ok,
       state
       |> Map.put(:approved, true)
       |> Map.put(:approval_type, :manual)
       |> Map.put(:reviewed_by, "system_reviewer")
       |> Map.put(:reviewed_at, DateTime.utc_now())}
    end
  end

  defmodule AutoRejectStep do
    @moduledoc "Step de rechazo automático para alto riesgo"
    @behaviour Beamflow.Workflows.Step

    @impl true
    def execute(state) do
      {:ok,
       state
       |> Map.put(:approved, false)
       |> Map.put(:rejection_type, :automatic)
       |> Map.put(:rejection_reason, "Alto riesgo detectado")
       |> Map.put(:rejected_at, DateTime.utc_now())}
    end
  end

  defmodule NotifyStep do
    @moduledoc "Step de notificación final"
    @behaviour Beamflow.Workflows.Step

    @impl true
    def execute(state) do
      notification =
        if Map.get(state, :approved) do
          "Solicitud aprobada (#{Map.get(state, :approval_type, :unknown)})"
        else
          "Solicitud rechazada: #{Map.get(state, :rejection_reason, "Sin razón")}"
        end

      {:ok,
       state
       |> Map.put(:notification_sent, true)
       |> Map.put(:notification_message, notification)
       |> Map.put(:notified_at, DateTime.utc_now())}
    end
  end
end
