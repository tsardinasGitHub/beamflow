defmodule Beamflow.Domains.Insurance.InsuranceRequest do
  @moduledoc """
  Struct que representa una solicitud de seguro vehicular.

  Este struct almacena toda la información relacionada con una solicitud
  de seguro desde su creación hasta su aprobación o rechazo.

  ## Campos

  ### Datos del Solicitante
  - `applicant_name` - Nombre completo del solicitante
  - `dni` - Documento Nacional de Identidad (8 dígitos)

  ### Datos del Vehículo
  - `vehicle_model` - Marca y modelo del vehículo
  - `vehicle_year` - Año de fabricación
  - `vehicle_plate` - Placa de matrícula

  ### Resultados de Evaluación
  - `credit_score` - Puntaje crediticio (300-900)
  - `risk_level` - Nivel de riesgo calculado (`:low`, `:medium`, `:high`)
  - `premium_amount` - Monto de la prima calculada (en USD)

  ### Estado de la Solicitud
  - `status` - Estado actual del procesamiento
  - `rejection_reason` - Razón de rechazo si aplica

  ## Ejemplo

      %InsuranceRequest{
        applicant_name: "Juan Pérez",
        dni: "12345678",
        vehicle_model: "Toyota Corolla",
        vehicle_year: 2020,
        vehicle_plate: "ABC-123",
        status: :pending
      }
  """

  @type status ::
          :pending
          | :validating_identity
          | :checking_credit
          | :evaluating_risk
          | :approved
          | :rejected

  @type risk_level :: :low | :medium | :high | nil

  @type t :: %__MODULE__{
          # Datos del solicitante
          applicant_name: String.t(),
          dni: String.t(),

          # Datos del vehículo
          vehicle_model: String.t(),
          vehicle_year: integer(),
          vehicle_plate: String.t(),

          # Resultados de evaluación
          credit_score: integer() | nil,
          risk_level: risk_level(),
          premium_amount: float() | nil,

          # Estado
          status: status(),
          rejection_reason: String.t() | nil,

          # Metadatos
          current_step: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:applicant_name, :dni, :vehicle_model, :vehicle_year, :vehicle_plate]

  defstruct [
    # Datos del solicitante
    :applicant_name,
    :dni,

    # Datos del vehículo
    :vehicle_model,
    :vehicle_year,
    :vehicle_plate,

    # Resultados de evaluación
    credit_score: nil,
    risk_level: nil,
    premium_amount: nil,

    # Estado
    status: :pending,
    rejection_reason: nil,

    # Metadatos
    current_step: 0,
    inserted_at: nil,
    updated_at: nil
  ]

  @doc """
  Crea una nueva solicitud de seguro a partir de parámetros.

  ## Parámetros

  Mapa con strings como keys (típicamente desde un formulario):
  - `"applicant_name"` - Nombre del solicitante
  - `"dni"` - DNI (8 dígitos)
  - `"vehicle_model"` - Modelo del vehículo
  - `"vehicle_year"` - Año (integer o string)
  - `"vehicle_plate"` - Placa

  ## Ejemplo

      iex> InsuranceRequest.new(%{
      ...>   "applicant_name" => "Juan Pérez",
      ...>   "dni" => "12345678",
      ...>   "vehicle_model" => "Toyota Corolla",
      ...>   "vehicle_year" => "2020",
      ...>   "vehicle_plate" => "ABC-123"
      ...> })
      {:ok, %InsuranceRequest{applicant_name: "Juan Pérez", ...}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(params) do
    with {:ok, validated} <- validate_params(params) do
      request = %__MODULE__{
        applicant_name: validated.applicant_name,
        dni: validated.dni,
        vehicle_model: validated.vehicle_model,
        vehicle_year: validated.vehicle_year,
        vehicle_plate: validated.vehicle_plate,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, request}
    end
  end

  defp validate_params(params) do
    with {:ok, name} <- get_required_string(params, "applicant_name"),
         {:ok, dni} <- validate_dni(params["dni"]),
         {:ok, model} <- get_required_string(params, "vehicle_model"),
         {:ok, year} <- validate_year(params["vehicle_year"]),
         {:ok, plate} <- get_required_string(params, "vehicle_plate") do
      {:ok,
       %{
         applicant_name: name,
         dni: dni,
         vehicle_model: model,
         vehicle_year: year,
         vehicle_plate: plate
       }}
    end
  end

  defp get_required_string(params, key) do
    case params[key] do
      nil -> {:error, "#{key} es requerido"}
      "" -> {:error, "#{key} no puede estar vacío"}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, "#{key} debe ser texto"}
    end
  end

  defp validate_dni(dni) when is_binary(dni) do
    trimmed = String.trim(dni)

    cond do
      String.length(trimmed) != 8 ->
        {:error, "DNI debe tener 8 dígitos"}

      not String.match?(trimmed, ~r/^\d{8}$/) ->
        {:error, "DNI debe contener solo números"}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_dni(_), do: {:error, "DNI es requerido"}

  defp validate_year(year) when is_integer(year) do
    current_year = DateTime.utc_now().year

    cond do
      year < 1900 -> {:error, "Año del vehículo inválido"}
      year > current_year + 1 -> {:error, "Año del vehículo no puede ser futuro"}
      true -> {:ok, year}
    end
  end

  defp validate_year(year) when is_binary(year) do
    case Integer.parse(year) do
      {int, ""} -> validate_year(int)
      _ -> {:error, "Año del vehículo debe ser un número"}
    end
  end

  defp validate_year(_), do: {:error, "Año del vehículo es requerido"}
end
