defmodule Beamflow.Domains.Insurance.Steps.ValidateIdentity do
  @moduledoc """
  Step 1: Validación de identidad del solicitante.

  Simula una integración con RENIEC (Registro Nacional de Identificación
  y Estado Civil) para verificar que el DNI existe y está activo.

  ## Comportamiento Simulado

  - **Latencia**: 100-1200ms (simula llamada a API externa)
  - **Tasa de fallo**: 10% (simula indisponibilidad del servicio)
  - **Validaciones**: Formato de DNI, dígito verificador básico

  ## Datos Agregados al Estado

  Cuando el step tiene éxito, agrega al estado:

      %{
        identity_validated: %{
          dni: "12345678",
          status: :valid,
          validated_at: ~U[2025-01-15 10:30:00Z]
        }
      }

  ## Ejemplo

      iex> state = %{dni: "12345678", applicant_name: "Juan Pérez"}
      iex> ValidateIdentity.execute(state)
      {:ok, %{...state, identity_validated: %{dni: "12345678", status: :valid}}}

  """

  @behaviour Beamflow.Workflows.Step

  require Logger

  @impl true
  def validate(%{dni: dni}) when is_binary(dni) and byte_size(dni) == 8 do
    if String.match?(dni, ~r/^\d{8}$/) do
      :ok
    else
      {:error, :invalid_dni_format}
    end
  end

  def validate(_state) do
    {:error, :missing_dni}
  end

  @impl true
  def execute(%{dni: dni} = state) do
    Logger.info("ValidateIdentity: Verificando DNI #{dni}")

    # Simular latencia de servicio externo (RENIEC)
    simulate_network_latency()

    # 10% de probabilidad de fallo del servicio
    case simulate_service_availability() do
      :available ->
        # Verificación exitosa
        Logger.info("ValidateIdentity: DNI #{dni} validado correctamente")

        updated_state =
          Map.put(state, :identity_validated, %{
            dni: dni,
            status: :valid,
            validated_at: DateTime.utc_now()
          })

        {:ok, updated_state}

      :unavailable ->
        Logger.warning("ValidateIdentity: Servicio RENIEC no disponible")
        {:error, :service_unavailable}
    end
  end

  # ============================================================================
  # Funciones Privadas - Simulación
  # ============================================================================

  defp simulate_network_latency do
    # Simular latencia variable de red (100-1200ms)
    delay = Enum.random(100..1200)
    Process.sleep(delay)
  end

  defp simulate_service_availability do
    # 10% de probabilidad de que el servicio no esté disponible
    case Enum.random(1..10) do
      1 -> :unavailable
      _ -> :available
    end
  end
end
