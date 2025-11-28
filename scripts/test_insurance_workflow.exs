#!/usr/bin/env elixir

# Script para probar el workflow de seguros manualmente
# Uso: mix run scripts/test_insurance_workflow.exs

alias Beamflow.Engine.WorkflowSupervisor
alias Beamflow.Engine.WorkflowActor
alias Beamflow.Domains.Insurance.InsuranceWorkflow
alias Beamflow.Storage.WorkflowStore

IO.puts("\n🚗 === Prueba de Workflow de Seguro Vehicular ===\n")

# Parámetros de la solicitud
params = %{
  "applicant_name" => "Juan Pérez García",
  "dni" => "12345678",
  "vehicle_model" => "Toyota Corolla 2020",
  "vehicle_year" => "2020",
  "vehicle_plate" => "ABC-123"
}

IO.puts("📋 Creando solicitud de seguro con:")
IO.puts("   Solicitante: #{params["applicant_name"]}")
IO.puts("   DNI: #{params["dni"]}")
IO.puts("   Vehículo: #{params["vehicle_model"]}")
IO.puts("   Placa: #{params["vehicle_plate"]}")
IO.puts("")

# Generar ID único para el workflow
workflow_id = "req-#{:rand.uniform(9999)}"
IO.puts("🆔 Workflow ID: #{workflow_id}\n")

# Iniciar el workflow
IO.puts("🚀 Iniciando workflow...\n")

case WorkflowSupervisor.start_workflow(InsuranceWorkflow, workflow_id, params) do
  {:ok, pid} ->
    IO.puts("✅ Workflow iniciado correctamente (PID: #{inspect(pid)})")
    IO.puts("\n⏳ Ejecutando steps (esto puede tomar 5-10 segundos)...\n")

    # Esperar a que se ejecuten los steps
    Process.sleep(6000)

    # Consultar estado final
    case WorkflowActor.get_state(workflow_id) do
      {:ok, state} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("📊 RESULTADO FINAL")
        IO.puts(String.duplicate("=", 60))

        IO.puts("\n🔹 Estado General:")
        IO.puts("   Status: #{inspect(state.status)}")
        IO.puts("   Steps completados: #{state.current_step_index}/#{state.total_steps}")

        workflow_state = state.workflow_state

        if workflow_state[:identity_validated] do
          IO.puts("\n✓ Identidad Validada:")
          IO.puts("   DNI: #{workflow_state.identity_validated.dni}")
          IO.puts("   Status: #{workflow_state.identity_validated.status}")
        end

        if workflow_state[:credit_check] do
          IO.puts("\n✓ Verificación Crediticia:")
          IO.puts("   Score: #{workflow_state.credit_check.score}")
          IO.puts("   Nivel de Riesgo: #{workflow_state.credit_check.risk_level}")
        end

        if workflow_state[:vehicle_check] do
          IO.puts("\n✓ Verificación Vehicular:")
          IO.puts("   Placa: #{workflow_state.vehicle_check.plate}")
          IO.puts("   Robado: #{workflow_state.vehicle_check.stolen}")
          IO.puts("   Valuación: $#{workflow_state.vehicle_check.valuation}")
        end

        if workflow_state[:premium_amount] do
          IO.puts("\n💰 Prima Calculada: $#{workflow_state.premium_amount}")
        end

        if workflow_state[:final_decision] do
          decision = workflow_state.final_decision
          IO.puts("\n" <> String.duplicate("-", 60))

          case decision.status do
            :approved ->
              IO.puts("🎉 SOLICITUD APROBADA")
              IO.puts("\n   El cliente puede proceder con la contratación del seguro.")

            :rejected ->
              IO.puts("❌ SOLICITUD RECHAZADA")
              IO.puts("\n   Razón: #{decision.reason}")
          end

          IO.puts(String.duplicate("-", 60))
        end

        if state.error do
          IO.puts("\n⚠️  Error: #{inspect(state.error)}")
        end

        IO.puts("\n" <> String.duplicate("=", 60) <> "\n")

      {:error, :not_found} ->
        IO.puts("\n❌ No se pudo encontrar el workflow #{workflow_id}")
    end

    # =========================================================================
    # VERIFICAR PERSISTENCIA EN MNESIA
    # =========================================================================
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("💾 VERIFICACIÓN DE PERSISTENCIA (Mnesia)")
    IO.puts(String.duplicate("=", 60))

    # Verificar si las tablas están disponibles
    if WorkflowStore.tables_available?() do
      IO.puts("\n✓ Tablas de Mnesia disponibles")

      # Obtener workflow desde Mnesia
      case WorkflowStore.get_workflow(workflow_id) do
        {:ok, record} ->
          IO.puts("\n📦 Workflow recuperado desde Mnesia:")
          IO.puts("   ID: #{record.id}")
          IO.puts("   Status: #{inspect(record.status)}")
          IO.puts("   Módulo: #{inspect(record.workflow_module)}")
          IO.puts("   Steps: #{record.current_step_index}/#{record.total_steps}")
          IO.puts("   Insertado: #{record.inserted_at}")
          IO.puts("   Actualizado: #{record.updated_at}")

        {:error, :not_found} ->
          IO.puts("\n⚠️  Workflow no encontrado en Mnesia (puede que las tablas no existan)")
      end

      # Obtener historial de eventos
      case WorkflowStore.get_events(workflow_id) do
        {:ok, events} when events != [] ->
          IO.puts("\n📜 Historial de Eventos (#{length(events)} eventos):")

          Enum.each(events, fn event ->
            emoji = case event.event_type do
              :workflow_started -> "🚀"
              :step_started -> "▶️"
              :step_completed -> "✅"
              :step_failed -> "❌"
              :workflow_completed -> "🏁"
              :workflow_failed -> "💥"
              _ -> "📌"
            end

            IO.puts("   #{emoji} #{event.event_type}")

            if event.data[:step] do
              IO.puts("      Step: #{event.data.step}")
            end

            if event.data[:duration_ms] do
              IO.puts("      Duración: #{event.data.duration_ms}ms")
            end
          end)

        {:ok, []} ->
          IO.puts("\n📜 No hay eventos registrados")

        {:error, reason} ->
          IO.puts("\n⚠️  Error al obtener eventos: #{inspect(reason)}")
      end

      # Estadísticas generales
      stats = WorkflowStore.count_by_status()
      IO.puts("\n📈 Estadísticas Generales:")
      IO.puts("   Pendientes: #{stats.pending}")
      IO.puts("   En ejecución: #{stats.running}")
      IO.puts("   Completados: #{stats.completed}")
      IO.puts("   Fallidos: #{stats.failed}")

    else
      IO.puts("\n⚠️  Tablas de Mnesia no disponibles")
      IO.puts("   Ejecuta: Beamflow.Storage.MnesiaSetup.ensure_tables()")
    end

    IO.puts("\n" <> String.duplicate("=", 60) <> "\n")

  {:error, reason} ->
    IO.puts("\n❌ Error al iniciar workflow: #{inspect(reason)}")
end

IO.puts("\n✨ Prueba completada\n")
