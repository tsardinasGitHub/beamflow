#!/usr/bin/env elixir
# Script de Demo Setup para BEAMFlow
# Uso: mix run scripts/demo_setup.exs [--chaos] [--count N]
#
# Opciones:
#   --chaos    Activa Chaos Mode después de crear workflows
#   --count N  Número de workflows a crear (default: 10)
#   --help     Muestra esta ayuda

defmodule DemoSetup do
  @moduledoc """
  Script para configurar una demo de BEAMFlow con datos de prueba.
  Crea workflows variados para demostrar las capacidades del sistema.
  """

  alias Beamflow.Engine.WorkflowSupervisor
  alias Beamflow.Domains.Insurance.InsuranceWorkflow

  @default_count 10
  @vehicles [
    {"Toyota Corolla", 2020},
    {"Honda Civic", 2019},
    {"Ford Mustang", 2022},
    {"Chevrolet Camaro", 2021},
    {"BMW 320i", 2023},
    {"Mercedes C200", 2022},
    {"Audi A4", 2021},
    {"Volkswagen Jetta", 2020},
    {"Nissan Sentra", 2018},
    {"Hyundai Elantra", 2019},
    {"Kia Forte", 2020},
    {"Mazda 3", 2021},
    {"Subaru Impreza", 2022},
    {"Tesla Model 3", 2023},
    {"Porsche 911", 2024}
  ]

  @names [
    "María García",
    "Juan Rodríguez",
    "Ana Martínez",
    "Carlos López",
    "Laura Hernández",
    "Pedro Sánchez",
    "Sofía Ramírez",
    "Diego Torres",
    "Valentina Cruz",
    "Andrés Morales",
    "Camila Ortiz",
    "Sebastián Vargas",
    "Isabella Mendoza",
    "Mateo Jiménez",
    "Luciana Castro"
  ]

  def run(args \\ []) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [chaos: :boolean, count: :integer, help: :boolean],
      aliases: [c: :chaos, n: :count, h: :help]
    )

    if opts[:help] do
      print_help()
    else
      count = opts[:count] || @default_count
      chaos = opts[:chaos] || false

      run_demo(count, chaos)
    end
  end

  defp run_demo(count, chaos) do
    print_banner()

    IO.puts("\n🚀 Iniciando Demo Setup...")
    IO.puts("   • Workflows a crear: #{count}")
    IO.puts("   • Chaos Mode: #{if chaos, do: "SÍ", else: "NO"}\n")

    # Crear workflows
    workflows = create_workflows(count)

    # Mostrar resumen
    print_summary(workflows)

    # Activar chaos mode si se solicitó
    if chaos do
      activate_chaos()
    end

    # Instrucciones finales
    print_next_steps()
  end

  defp create_workflows(count) do
    IO.puts("📋 Creando #{count} workflows de seguro vehicular...\n")

    workflows = for i <- 1..count do
      {vehicle_model, vehicle_year} = Enum.random(@vehicles)
      name = Enum.random(@names)
      dni = generate_dni()
      plate = generate_plate(i)

      workflow_id = "demo-#{timestamp()}-#{i}"

      params = %{
        "applicant_name" => name,
        "dni" => dni,
        "vehicle_model" => vehicle_model,
        "vehicle_year" => to_string(vehicle_year),
        "vehicle_plate" => plate
      }

      case WorkflowSupervisor.start_workflow(InsuranceWorkflow, workflow_id, params) do
        {:ok, _pid} ->
          IO.puts("   ✅ #{workflow_id}")
          IO.puts("      └─ #{name} | #{vehicle_model} #{vehicle_year} | #{plate}")
          {:ok, workflow_id, params}

        {:error, reason} ->
          IO.puts("   ❌ #{workflow_id} - Error: #{inspect(reason)}")
          {:error, workflow_id, reason}
      end
    end

    # Pequeña pausa para que los workflows empiecen a ejecutarse
    IO.puts("\n⏳ Esperando a que los workflows inicien ejecución...")
    Process.sleep(2000)

    workflows
  end

  defp print_summary(workflows) do
    successful = Enum.count(workflows, fn
      {:ok, _, _} -> true
      _ -> false
    end)

    failed = Enum.count(workflows, fn
      {:error, _, _} -> true
      _ -> false
    end)

    IO.puts("""

    ╔════════════════════════════════════════════════════════════╗
    ║                    📊 RESUMEN DE DEMO                      ║
    ╠════════════════════════════════════════════════════════════╣
    ║  Workflows creados exitosamente: #{String.pad_leading(to_string(successful), 3)}                       ║
    ║  Workflows con error:            #{String.pad_leading(to_string(failed), 3)}                       ║
    ╚════════════════════════════════════════════════════════════╝
    """)
  end

  defp activate_chaos do
    IO.puts("💥 Activando Chaos Mode (perfil: moderate)...\n")

    case Beamflow.Chaos.ChaosMonkey.start(:moderate) do
      :ok ->
        IO.puts("   ✅ ChaosMonkey activado!")
        IO.puts("   ⚠️  Los workflows pueden experimentar fallos aleatorios")
        IO.puts("   💡 Para detener: Beamflow.Chaos.ChaosMonkey.stop()\n")

      {:error, reason} ->
        IO.puts("   ❌ Error activando ChaosMonkey: #{inspect(reason)}\n")
    end
  end

  defp print_next_steps do
    IO.puts("""

    ╔════════════════════════════════════════════════════════════╗
    ║                   🎯 PRÓXIMOS PASOS                        ║
    ╠════════════════════════════════════════════════════════════╣
    ║                                                            ║
    ║  1. Abre el Dashboard:                                     ║
    ║     http://localhost:4000                                  ║
    ║                                                            ║
    ║  2. Explora los workflows en el Explorer                   ║
    ║                                                            ║
    ║  3. Click en un workflow para ver el Timeline              ║
    ║                                                            ║
    ║  4. Click en "Ver Grafo" para visualización SVG            ║
    ║                                                            ║
    ║  5. Activa el "Modo Replay" para debugger visual           ║
    ║                                                            ║
    ║  6. Revisa Analytics para métricas en tiempo real          ║
    ║                                                            ║
    ╚════════════════════════════════════════════════════════════╝

    💡 Comandos útiles en IEx:

       # Ver estado de un workflow
       Beamflow.Engine.WorkflowActor.get_state("demo-xxx-1")

       # Activar/desactivar chaos
       Beamflow.Chaos.ChaosMonkey.start(:aggressive)
       Beamflow.Chaos.ChaosMonkey.stop()

       # Ver estadísticas de chaos
       Beamflow.Chaos.ChaosMonkey.stats()

       # Crear más workflows
       mix run scripts/demo_setup.exs --count 20

    """)
  end

  defp print_banner do
    IO.puts("""

    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║   ██████╗ ███████╗ █████╗ ███╗   ███╗███████╗██╗      ██████╗ ║
    ║   ██╔══██╗██╔════╝██╔══██╗████╗ ████║██╔════╝██║     ██╔═══██╗║
    ║   ██████╔╝█████╗  ███████║██╔████╔██║█████╗  ██║     ██║   ██║║
    ║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║██╔══╝  ██║     ██║   ██║║
    ║   ██████╔╝███████╗██║  ██║██║ ╚═╝ ██║██║     ███████╗╚██████╔╝║
    ║   ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚══════╝ ╚═════╝ ║
    ║                                                               ║
    ║                    Demo Setup Script v1.0                     ║
    ╚═══════════════════════════════════════════════════════════════╝
    """)
  end

  defp print_help do
    IO.puts("""

    BEAMFlow Demo Setup Script
    ==========================

    Uso:
      mix run scripts/demo_setup.exs [opciones]

    Opciones:
      --count N, -n N    Número de workflows a crear (default: 10)
      --chaos, -c        Activar Chaos Mode después de crear workflows
      --help, -h         Mostrar esta ayuda

    Ejemplos:
      # Crear 10 workflows (default)
      mix run scripts/demo_setup.exs

      # Crear 25 workflows
      mix run scripts/demo_setup.exs --count 25

      # Crear 15 workflows y activar chaos mode
      mix run scripts/demo_setup.exs -n 15 --chaos

      # Demo completa con chaos
      mix run scripts/demo_setup.exs -n 20 -c

    """)
  end

  # Helpers

  defp generate_dni do
    :rand.uniform(99_999_999)
    |> Integer.to_string()
    |> String.pad_leading(8, "0")
  end

  defp generate_plate(index) do
    letters = ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P", "R", "S", "T", "V", "W", "X", "Y", "Z"]
    prefix = Enum.random(letters) <> Enum.random(letters) <> Enum.random(letters)
    "#{prefix}-#{String.pad_leading(to_string(index * 100 + :rand.uniform(99)), 3, "0")}"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_unix()
    |> Integer.to_string()
    |> String.slice(-6, 6)
  end
end

# Ejecutar el script
DemoSetup.run(System.argv())
