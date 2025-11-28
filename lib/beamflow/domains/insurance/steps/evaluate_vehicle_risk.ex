defmodule Beamflow.Domains.Insurance.Steps.EvaluateVehicleRisk do
  @moduledoc """
  Step 3: Evaluación del riesgo del vehículo.

  Simula verificaciones con:
  - Registro Nacional de Vehículos
  - Base de datos de vehículos robados
  - Servicios de valuación vehicular

  ## Comportamiento Simulado

  - **Latencia**: 100-1000ms (consultas a bases de datos vehiculares)
  - **Tasa de fallo del servicio**: 6.67% (1 en 15)
  - **Vehículo robado**: 1% de probabilidad
  - **Valuación**: Aleatoria entre $5,000 - $30,000
  - **Cálculo de prima**: Basado en año del vehículo y valuación

  ## Datos Agregados al Estado

  Cuando el step tiene éxito, agrega:

      %{
        vehicle_check: %{
          plate: "ABC-123",
          registration: :ok,
          stolen: false,
          valuation: 15000,
          checked_at: ~U[2025-01-15 10:30:10Z]
        },
        premium_amount: 450.0
      }

  ## Ejemplo

      iex> state = %{
      ...>   vehicle_plate: "ABC-123",
      ...>   vehicle_year: 2020,
      ...>   credit_check: %{risk_level: :low}
      ...> }
      iex> EvaluateVehicleRisk.execute(state)
      {:ok, %{...state, vehicle_check: %{...}, premium_amount: 450.0}}

  """

  @behaviour Beamflow.Workflows.Step

  require Logger

  @impl true
  def validate(%{vehicle_plate: plate, vehicle_year: year})
      when is_binary(plate) and is_integer(year) do
    :ok
  end

  def validate(_state) do
    {:error, :missing_vehicle_data}
  end

  @impl true
  def execute(%{vehicle_plate: plate, vehicle_year: year} = state) do
    Logger.info("EvaluateVehicleRisk: Evaluando vehículo #{plate} (#{year})")

    simulate_network_latency()

    # Simular diferentes escenarios
    cond do
      service_unavailable?() ->
        Logger.warning("EvaluateVehicleRisk: Servicio vehicular no disponible")
        {:error, :vehicle_service_unavailable}

      vehicle_stolen?() ->
        Logger.error("EvaluateVehicleRisk: Vehículo #{plate} reportado como robado")
        {:error, :vehicle_stolen}

      true ->
        valuation = calculate_valuation(year)
        premium = calculate_premium(year, valuation, state)

        Logger.info(
          "EvaluateVehicleRisk: Vehículo valuado en $#{valuation}, prima: $#{premium}"
        )

        updated_state =
          state
          |> Map.put(:vehicle_check, %{
            plate: plate,
            registration: :ok,
            stolen: false,
            valuation: valuation,
            checked_at: DateTime.utc_now()
          })
          |> Map.put(:premium_amount, premium)

        {:ok, updated_state}
    end
  end

  # ============================================================================
  # Funciones Privadas - Simulación
  # ============================================================================

  defp simulate_network_latency do
    delay = Enum.random(100..1000)
    Process.sleep(delay)
  end

  defp service_unavailable? do
    # 1 en 15 veces el servicio no está disponible (~6.67%)
    Enum.random(1..15) == 1
  end

  defp vehicle_stolen? do
    # 1 en 100 veces el vehículo está reportado como robado (1%)
    Enum.random(1..100) == 1
  end

  defp calculate_valuation(year) do
    current_year = DateTime.utc_now().year
    age = current_year - year

    # Base valuation entre $5,000 y $30,000
    base = Enum.random(5000..30000)

    # Depreciar según edad (5% por año)
    depreciation_factor = :math.pow(0.95, age)
    round(base * depreciation_factor)
  end

  defp calculate_premium(year, valuation, state) do
    current_year = DateTime.utc_now().year
    age = current_year - year

    # Prima base: 3% del valor del vehículo
    base_premium = valuation * 0.03

    # Ajuste por antigüedad del vehículo
    age_factor =
      cond do
        age < 3 -> 1.0
        age < 7 -> 1.2
        age < 10 -> 1.5
        true -> 2.0
      end

    # Ajuste por riesgo crediticio
    risk_factor =
      case get_in(state, [:credit_check, :risk_level]) do
        :low -> 1.0
        :medium -> 1.3
        :high -> 1.8
        _ -> 1.5
      end

    premium = base_premium * age_factor * risk_factor

    # Redondear a 2 decimales
    Float.round(premium, 2)
  end
end
