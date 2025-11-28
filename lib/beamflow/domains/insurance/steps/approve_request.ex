defmodule Beamflow.Domains.Insurance.Steps.ApproveRequest do
  @moduledoc """
  Step 4: Decisión final de aprobación o rechazo.

  Este step NO realiza llamadas a servicios externos. Es puramente lógica
  de negocio que evalúa los resultados de los steps previos y determina
  si la solicitud debe ser aprobada o rechazada.

  ## Criterios de Aprobación

  Una solicitud es **RECHAZADA** si:
  - Score crediticio < 450 (alto riesgo)
  - Vehículo con más de 15 años de antigüedad
  - Prima calculada excede cierto umbral para el perfil

  Una solicitud es **APROBADA** si:
  - Identidad validada correctamente
  - Score crediticio >= 450
  - Vehículo no robado y registrado
  - Todos los checks previos pasaron

  ## Datos Agregados al Estado

  Agrega la decisión final:

      %{
        final_decision: %{
          status: :approved,  # o :rejected
          reason: nil,        # o razón de rechazo
          decided_at: ~U[2025-01-15 10:30:15Z]
        }
      }

  ## Ejemplo - Aprobado

      iex> state = %{
      ...>   identity_validated: %{status: :valid},
      ...>   credit_check: %{score: 700, risk_level: :low},
      ...>   vehicle_check: %{stolen: false, registration: :ok},
      ...>   vehicle_year: 2020
      ...> }
      iex> ApproveRequest.execute(state)
      {:ok, %{...state, final_decision: %{status: :approved, reason: nil}}}

  ## Ejemplo - Rechazado

      iex> state = %{credit_check: %{score: 400, risk_level: :high}}
      iex> ApproveRequest.execute(state)
      {:ok, %{...state, final_decision: %{status: :rejected, reason: "Score crediticio muy bajo"}}}

  """

  @behaviour Beamflow.Workflows.Step

  require Logger

  @impl true
  def validate(%{
        identity_validated: %{status: :valid},
        credit_check: %{},
        vehicle_check: %{}
      }) do
    :ok
  end

  def validate(_state) do
    {:error, :incomplete_previous_steps}
  end

  @impl true
  def execute(state) do
    Logger.info("ApproveRequest: Evaluando decisión final")

    decision = evaluate_approval(state)

    case decision do
      {:approved, _} ->
        policy_number = generate_policy_number()
        Logger.info("ApproveRequest: Solicitud APROBADA - Póliza #{policy_number}")

        updated_state =
          state
          |> Map.put(:final_decision, %{
            status: :approved,
            reason: nil,
            decided_at: DateTime.utc_now()
          })
          |> Map.put(:policy_number, policy_number)
          |> Map.put(:approved, true)

        {:ok, updated_state}

      {:rejected, reason} ->
        Logger.warning("ApproveRequest: Solicitud RECHAZADA - #{reason}")

        updated_state =
          state
          |> Map.put(:final_decision, %{
            status: :rejected,
            reason: reason,
            decided_at: DateTime.utc_now()
          })
          |> Map.put(:approved, false)

        {:ok, updated_state}
    end
  end

  # ============================================================================
  # Funciones Privadas - Lógica de Negocio
  # ============================================================================

  defp evaluate_approval(state) do
    with :ok <- check_identity(state),
         :ok <- check_credit_score(state),
         :ok <- check_vehicle_status(state),
         :ok <- check_vehicle_age(state),
         :ok <- check_premium_affordability(state) do
      {:approved, nil}
    else
      {:reject, reason} -> {:rejected, reason}
    end
  end

  defp check_identity(%{identity_validated: %{status: :valid}}), do: :ok

  defp check_identity(_),
    do: {:reject, "Identidad no validada"}

  defp check_credit_score(%{credit_check: %{score: score, risk_level: risk}}) do
    cond do
      score < 450 ->
        {:reject, "Score crediticio muy bajo (#{score})"}

      risk == :high ->
        {:reject, "Perfil de alto riesgo crediticio"}

      true ->
        :ok
    end
  end

  defp check_credit_score(_), do: {:reject, "Sin información crediticia"}

  defp check_vehicle_status(%{vehicle_check: %{stolen: true}}),
    do: {:reject, "Vehículo reportado como robado"}

  defp check_vehicle_status(%{vehicle_check: %{registration: :ok}}), do: :ok
  defp check_vehicle_status(_), do: {:reject, "Vehículo sin verificar"}

  defp check_vehicle_age(%{vehicle_year: year}) do
    current_year = DateTime.utc_now().year
    age = current_year - year

    if age > 15 do
      {:reject, "Vehículo muy antiguo (#{age} años)"}
    else
      :ok
    end
  end

  defp check_vehicle_age(_), do: {:reject, "Sin información del año del vehículo"}

  defp check_premium_affordability(%{
         premium_amount: premium,
         credit_check: %{score: score}
       }) do
    # Umbral máximo de prima según score
    max_premium =
      cond do
        score >= 700 -> 1000
        score >= 600 -> 700
        score >= 500 -> 500
        true -> 400
      end

    if premium > max_premium do
      {:reject, "Prima muy alta para el perfil ($#{premium} > $#{max_premium})"}
    else
      :ok
    end
  end

  defp check_premium_affordability(_), do: {:reject, "Sin cálculo de prima"}

  defp generate_policy_number do
    # Formato: POL-YYYYMMDD-XXXXX
    date_part = DateTime.utc_now() |> Calendar.strftime("%Y%m%d")
    random_part = :rand.uniform(99999) |> Integer.to_string() |> String.pad_leading(5, "0")
    "POL-#{date_part}-#{random_part}"
  end
end
