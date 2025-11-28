defmodule Beamflow.Domains.Insurance.Steps.CheckCreditScore do
  @moduledoc """
  Step 2: Verificación de historial crediticio del solicitante.

  Simula una consulta a un bureau de crédito (Equifax, Experian, etc.)
  para obtener el score crediticio del solicitante.

  ## Comportamiento Simulado

  - **Latencia**: 200-1500ms (API externa generalmente más lenta)
  - **Tasa de timeout**: 5% (simula timeouts ocasionales)
  - **Score**: Aleatorio entre 300-900
  - **Clasificación de riesgo**:
    - < 450: Alto riesgo
    - 450-650: Riesgo medio
    - > 650: Bajo riesgo

  ## Datos Agregados al Estado

  Cuando el step tiene éxito, agrega:

      %{
        credit_score: 750,
        credit_check: %{
          score: 750,
          risk_level: :low,
          checked_at: ~U[2025-01-15 10:30:05Z]
        }
      }

  ## Ejemplo

      iex> state = %{dni: "12345678", identity_validated: %{status: :valid}}
      iex> CheckCreditScore.execute(state)
      {:ok, %{...state, credit_score: 750, credit_check: %{score: 750, risk_level: :low}}}

  """

  @behaviour Beamflow.Workflows.Step

  require Logger

  @impl true
  def validate(%{identity_validated: %{status: :valid}}) do
    :ok
  end

  def validate(_state) do
    {:error, :identity_not_validated}
  end

  @impl true
  def execute(%{dni: dni} = state) do
    Logger.info("CheckCreditScore: Consultando bureau de crédito para DNI #{dni}")

    # Simular latencia mayor (bureaus suelen ser más lentos)
    simulate_network_latency()

    # 5% de probabilidad de timeout
    case simulate_service_response() do
      :timeout ->
        Logger.warning("CheckCreditScore: Timeout al consultar bureau")
        {:error, :credit_bureau_timeout}

      :success ->
        score = generate_credit_score()
        risk_level = classify_risk(score)

        Logger.info("CheckCreditScore: Score #{score} - Riesgo: #{risk_level}")

        updated_state =
          state
          |> Map.put(:credit_score, score)
          |> Map.put(:credit_check, %{
            score: score,
            risk_level: risk_level,
            checked_at: DateTime.utc_now()
          })

        {:ok, updated_state}
    end
  end

  # ============================================================================
  # Funciones Privadas - Simulación
  # ============================================================================

  defp simulate_network_latency do
    # Bureaus de crédito tienden a ser más lentos (200-1500ms)
    delay = Enum.random(200..1500)
    Process.sleep(delay)
  end

  defp simulate_service_response do
    # 5% de probabilidad de timeout (1 en 20)
    case Enum.random(1..20) do
      1 -> :timeout
      _ -> :success
    end
  end

  defp generate_credit_score do
    # Score crediticio entre 300 y 900
    Enum.random(300..900)
  end

  defp classify_risk(score) when score < 450, do: :high
  defp classify_risk(score) when score < 650, do: :medium
  defp classify_risk(_score), do: :low
end
