defmodule Beamflow.Domains.Insurance.InsuranceWorkflow do
  @moduledoc """
  Workflow para procesamiento de solicitudes de seguro vehicular.

  Este módulo implementa el behaviour `Beamflow.Workflows.Workflow` para
  definir el pipeline completo de evaluación de una solicitud de seguro.

  ## Pipeline de Steps

  1. **ValidateIdentity** - Verificar DNI con RENIEC (simulado)
  2. **CheckCreditScore** - Consultar bureau de crédito (simulado)
  3. **EvaluateVehicleRisk** - Verificar vehículo y calcular prima
  4. **ApproveRequest** - Decisión final basada en todos los datos
  5. **SendConfirmationEmail** - Enviar email con el veredicto (idempotente)

  ## Ejemplo de Uso

      # Iniciar workflow
      {:ok, pid} = Beamflow.Engine.WorkflowSupervisor.start_workflow(
        Beamflow.Domains.Insurance.InsuranceWorkflow,
        "req-123",
        %{
          "applicant_name" => "Juan Pérez",
          "applicant_email" => "juan.perez@email.com",
          "dni" => "12345678",
          "vehicle_model" => "Toyota Corolla",
          "vehicle_year" => "2020",
          "vehicle_plate" => "ABC-123"
        }
      )

      # El workflow ejecutará automáticamente los 5 steps
      # Consultar estado:
      {:ok, state} = Beamflow.Engine.WorkflowActor.get_state("req-123")

  ## Estados del Workflow

  - `:pending` - Recién creado, aún no ejecutado
  - `:running` - Ejecutando steps
  - `:completed` - Todos los steps completados (aprobado o rechazado)
  - `:failed` - Falló algún step crítico (ej: servicio no disponible)

  Ver ADR-003 para el diseño de esta arquitectura basada en behaviours.
  """

  @behaviour Beamflow.Workflows.Workflow

  alias Beamflow.Domains.Insurance.Steps.{
    ValidateIdentity,
    CheckCreditScore,
    EvaluateVehicleRisk,
    ApproveRequest,
    SendConfirmationEmail
  }

  alias Beamflow.Workflows.Graph

  @impl true
  def steps do
    [
      ValidateIdentity,
      CheckCreditScore,
      EvaluateVehicleRisk,
      ApproveRequest,
      SendConfirmationEmail
    ]
  end

  @doc """
  Retorna el grafo del workflow con soporte para branching.

  El workflow sigue el siguiente flujo:
  1. ValidateIdentity → CheckCreditScore → EvaluateVehicleRisk → ApproveRequest
  2. Después de ApproveRequest:
     - Si approved=true → SendConfirmationEmail (con mensaje de aprobación)
     - Si approved=false → SendConfirmationEmail (con mensaje de rechazo)

  En este caso, ambos caminos llevan al mismo step (SendConfirmationEmail)
  porque el step ya maneja internamente la lógica condicional.
  En workflows más complejos, los paths podrían divergir completamente.
  """
  def graph do
    # Por ahora usamos el grafo lineal, ya que SendConfirmationEmail
    # maneja internamente la lógica de aprobado/rechazado.
    # Cuando agreguemos steps específicos para cada rama,
    # usaremos un grafo con branching real.
    Graph.from_linear_steps(steps())
  end

  @doc """
  Indica si este workflow tiene branching.

  Actualmente retorna false porque usamos lógica condicional
  dentro de SendConfirmationEmail en lugar de branches separados.
  """
  def has_branching?, do: false

  @impl true
  def initial_state(params) do
    %{
      # Datos del solicitante
      applicant_name: params["applicant_name"],
      applicant_email: params["applicant_email"] || generate_demo_email(params["applicant_name"]),
      dni: params["dni"],

      # Datos del vehículo
      vehicle_model: params["vehicle_model"],
      vehicle_year: parse_year(params["vehicle_year"]),
      vehicle_plate: params["vehicle_plate"],

      # Estado del workflow
      status: :pending,
      current_step: 0,

      # Metadatos
      started_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  @impl true
  def handle_step_success(_step_module, state) do
    state
    |> Map.put(:current_step, state.current_step + 1)
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  @impl true
  def handle_step_failure(step_module, reason, state) do
    state
    |> Map.put(:status, :failed)
    |> Map.put(:failed_at_step, step_module)
    |> Map.put(:failure_reason, format_error(reason))
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp parse_year(year) when is_integer(year), do: year

  defp parse_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_year(_), do: nil

  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  # Genera un email de demo basado en el nombre del solicitante
  defp generate_demo_email(nil), do: "demo@beamflow.dev"
  defp generate_demo_email(name) do
    slug = name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, ".")
    |> String.trim(".")

    "#{slug}@beamflow.dev"
  end
end
