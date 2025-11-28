defmodule Beamflow.Workflows.Step do
  @moduledoc """
  Behaviour para steps ejecutables dentro de un workflow.

  Un step representa una unidad atómica de trabajo dentro de un pipeline.
  Cada step recibe el estado actual, ejecuta su lógica, y retorna
  el estado actualizado o un error.

  ## Principios de Diseño

  1. **Idempotencia**: Un step debe poder ejecutarse múltiples veces
     con el mismo resultado (útil para retries)

  2. **Aislamiento**: Un step no debe conocer a otros steps.
     Solo trabaja con el estado que recibe.

  3. **Side Effects Controlados**: Interacciones con servicios externos
     deben manejarse con timeouts y error handling robusto.

  4. **Estado Inmutable**: Retornar nuevo mapa, no mutar el existente.

  ## Ejemplo Básico

      defmodule MyApp.Steps.ValidateEmail do
        @behaviour Beamflow.Workflows.Step

        @impl true
        def execute(%{email: email} = state) do
          if valid_email?(email) do
            {:ok, Map.put(state, :email_validated, true)}
          else
            {:error, :invalid_email}
          end
        end

        @impl true
        def validate(%{email: email}) when is_binary(email), do: :ok
        def validate(_), do: {:error, :missing_email}

        defp valid_email?(email), do: String.contains?(email, "@")
      end

  ## Ejemplo con Simulación de Servicio Externo

      defmodule MyApp.Steps.CheckInventory do
        @behaviour Beamflow.Workflows.Step

        @impl true
        def execute(%{product_id: product_id, quantity: qty} = state) do
          # Simular latencia de API externa
          Process.sleep(Enum.random(100..500))

          case InventoryService.check_stock(product_id, qty) do
            {:ok, available} ->
              {:ok, Map.put(state, :inventory_checked, %{
                available: available,
                reserved: qty
              })}

            {:error, :timeout} ->
              {:error, :inventory_service_timeout}

            {:error, reason} ->
              {:error, {:inventory_check_failed, reason}}
          end
        end

        @impl true
        def validate(%{product_id: id, quantity: qty})
            when is_binary(id) and is_integer(qty) and qty > 0 do
          :ok
        end

        def validate(_), do: {:error, :invalid_inventory_params}
      end

  ## Manejo de Errores

  Los steps deben retornar errores descriptivos que ayuden a diagnosticar
  problemas:

  - Usar átomos para tipos conocidos: `:timeout`, `:not_found`
  - Usar tuplas para contexto: `{:validation_failed, "DNI inválido"}`
  - Evitar excepciones: preferir `{:error, reason}`

  ## Testing

      test "ejecuta step exitosamente" do
        state = %{email: "user@example.com"}

        assert {:ok, updated} = ValidateEmail.execute(state)
        assert updated.email_validated == true
      end

      test "falla con email inválido" do
        state = %{email: "invalid"}

        assert {:error, :invalid_email} = ValidateEmail.execute(state)
      end

  Ver ADR-002 para estándares de testing de steps.
  """

  @type workflow_state :: map()
  @type step_result :: {:ok, workflow_state()} | {:error, term()}

  @doc """
  Ejecuta la lógica del step sobre el estado actual del workflow.

  ## Parámetros

  - `state` - Mapa con el estado actual del workflow. Puede contener:
    - Datos de entrada originales
    - Resultados de steps previos
    - Metadatos (current_step, timestamps, etc.)

  ## Retorno

  - `{:ok, updated_state}` - Step completado exitosamente.
    El estado actualizado **debe incluir** la información producida por este step.

  - `{:error, reason}` - Step falló.
    El `reason` debe ser descriptivo para facilitar debugging.

  ## Contrato

  - **NO debe mutar** el estado recibido
  - **DEBE retornar** un nuevo mapa con los cambios
  - **DEBE ser idempotente** cuando sea posible
  - **DEBE manejar** timeouts y errores de red

  ## Ejemplo

      @impl true
      def execute(%{dni: dni} = state) do
        case validate_dni(dni) do
          :ok ->
            {:ok, Map.put(state, :dni_validated, %{
              dni: dni,
              validated_at: DateTime.utc_now()
            })}

          {:error, reason} ->
            {:error, {:dni_validation_failed, reason}}
        end
      end

  """
  @callback execute(workflow_state()) :: step_result()

  @doc """
  Valida que el estado contiene los datos necesarios para ejecutar el step.

  Esta función se invoca **antes** de `execute/1` para fail-fast en caso
  de datos faltantes o inválidos.

  ## Parámetros

  - `state` - Estado del workflow a validar

  ## Retorno

  - `:ok` - Estado válido, puede ejecutarse `execute/1`
  - `{:error, reason}` - Validación falló, no ejecutar `execute/1`

  ## Ejemplo

      @impl true
      def validate(%{dni: dni, name: name})
          when is_binary(dni) and is_binary(name) do
        :ok
      end

      def validate(_), do: {:error, :invalid_input}

  ## Nota

  Este callback es **opcional**. Si no se implementa, se asume que
  toda entrada es válida y `execute/1` debe manejar validaciones internas.
  """
  @callback validate(workflow_state()) :: :ok | {:error, term()}

  @optional_callbacks validate: 1
end
