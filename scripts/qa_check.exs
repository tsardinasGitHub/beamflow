#!/usr/bin/env elixir
# Script de QA Semi-Automático para BEAMFlow
# Uso: mix run scripts/qa_check.exs [--verbose] [--section SECTION]
#
# Secciones disponibles:
#   all       - Ejecutar todas las verificaciones (default)
#   smoke     - Solo smoke tests
#   api       - Solo verificar API REST
#   workflows - Solo verificar workflows
#   chaos     - Solo verificar Chaos Mode
#
# Opciones:
#   --verbose, -v    Mostrar detalles de cada verificación
#   --section, -s    Ejecutar solo una sección específica
#   --help, -h       Mostrar esta ayuda

defmodule QACheck do
  @moduledoc """
  Script de QA semi-automático para verificar el estado del sistema BEAMFlow.
  Ejecuta verificaciones de endpoints, workflows, y funcionalidades.
  """

  @base_url "http://localhost:4000"

  # Colores ANSI
  @green "\e[32m"
  @red "\e[31m"
  @yellow "\e[33m"
  @blue "\e[34m"
  @reset "\e[0m"
  @bold "\e[1m"

  def run(args \\ []) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [verbose: :boolean, section: :string, help: :boolean],
      aliases: [v: :verbose, s: :section, h: :help]
    )

    if opts[:help] do
      print_help()
    else
      verbose = opts[:verbose] || false
      section = opts[:section] || "all"

      run_qa(section, verbose)
    end
  end

  defp run_qa(section, verbose) do
    print_banner()

    results = case section do
      "all" ->
        [
          run_smoke_tests(verbose),
          run_api_tests(verbose),
          run_workflow_tests(verbose),
          run_chaos_tests(verbose)
        ]

      "smoke" -> [run_smoke_tests(verbose)]
      "api" -> [run_api_tests(verbose)]
      "workflows" -> [run_workflow_tests(verbose)]
      "chaos" -> [run_chaos_tests(verbose)]
      other ->
        IO.puts("#{@red}Sección desconocida: #{other}#{@reset}")
        IO.puts("Secciones válidas: all, smoke, api, workflows, chaos")
        System.halt(1)
    end

    print_summary(List.flatten(results))
  end

  # ============================================================================
  # SMOKE TESTS
  # ============================================================================

  defp run_smoke_tests(verbose) do
    print_section("🔥 SMOKE TESTS")

    tests = [
      {"Aplicación compilada", &check_compilation/0},
      {"Mnesia disponible", &check_mnesia/0},
      {"PubSub activo", &check_pubsub/0},
      {"WorkflowSupervisor activo", &check_workflow_supervisor/0}
    ]

    run_test_suite(tests, verbose)
  end

  defp check_compilation do
    # Si llegamos aquí, la app compiló correctamente
    {:pass, "Compilación exitosa"}
  end

  defp check_mnesia do
    tables = :mnesia.system_info(:tables)
    required = [:beamflow_workflows, :beamflow_events]

    missing = Enum.filter(required, fn t -> t not in tables end)

    if Enum.empty?(missing) do
      {:pass, "Tablas Mnesia: #{inspect(required)}"}
    else
      {:fail, "Tablas faltantes: #{inspect(missing)}"}
    end
  end

  defp check_pubsub do
    case Phoenix.PubSub.subscribe(Beamflow.PubSub, "qa_test_channel") do
      :ok ->
        Phoenix.PubSub.unsubscribe(Beamflow.PubSub, "qa_test_channel")
        {:pass, "PubSub Beamflow.PubSub operativo"}
      error ->
        {:fail, "Error en PubSub: #{inspect(error)}"}
    end
  end

  defp check_workflow_supervisor do
    case DynamicSupervisor.count_children(Beamflow.Engine.WorkflowSupervisor) do
      %{specs: _, active: _, supervisors: _, workers: _} = counts ->
        {:pass, "Supervisor activo: #{counts.active} workers"}
      error ->
        {:fail, "Error: #{inspect(error)}"}
    end
  end

  # ============================================================================
  # API TESTS
  # ============================================================================

  defp run_api_tests(verbose) do
    print_section("🌐 API REST TESTS")

    tests = [
      {"GET /api/health", fn -> check_endpoint("/api/health", 200) end},
      {"GET /api/analytics/summary", fn -> check_endpoint("/api/analytics/summary", 200) end},
      {"GET /api/analytics/trends", fn -> check_endpoint("/api/analytics/trends", 200) end},
      {"GET /api/analytics/export?format=json", fn -> check_endpoint("/api/analytics/export?format=json", 200) end},
      {"Rate Limit Headers", &check_rate_limit_headers/0},
      {"Health sin Rate Limit", &check_health_no_rate_limit/0}
    ]

    run_test_suite(tests, verbose)
  end

  defp check_endpoint(path, expected_status) do
    url = @base_url <> path

    case http_get(url) do
      {:ok, status, _headers, _body} when status == expected_status ->
        {:pass, "Status #{status}"}

      {:ok, status, _headers, body} ->
        {:fail, "Esperado #{expected_status}, recibido #{status}: #{String.slice(body, 0, 100)}"}

      {:error, reason} ->
        {:fail, "Error de conexión: #{inspect(reason)}"}
    end
  end

  defp check_rate_limit_headers do
    url = @base_url <> "/api/analytics/summary"

    case http_get(url) do
      {:ok, 200, headers, _body} ->
        rate_headers = Enum.filter(headers, fn {name, _} ->
          String.downcase(name) |> String.starts_with?("x-ratelimit")
        end)

        if length(rate_headers) >= 3 do
          header_names = Enum.map(rate_headers, fn {name, _} -> name end)
          {:pass, "Headers: #{Enum.join(header_names, ", ")}"}
        else
          {:fail, "Faltan headers de rate limit"}
        end

      {:ok, status, _, _} ->
        {:fail, "Status inesperado: #{status}"}

      {:error, reason} ->
        {:fail, "Error: #{inspect(reason)}"}
    end
  end

  defp check_health_no_rate_limit do
    url = @base_url <> "/api/health"

    # Hacer 5 requests rápidos
    results = for _ <- 1..5 do
      case http_get(url) do
        {:ok, 200, _, _} -> :ok
        {:ok, 429, _, _} -> :rate_limited
        other -> {:error, other}
      end
    end

    rate_limited = Enum.count(results, fn r -> r == :rate_limited end)

    if rate_limited == 0 do
      {:pass, "5 requests sin rate limit"}
    else
      {:fail, "#{rate_limited}/5 requests bloqueados"}
    end
  end

  # ============================================================================
  # WORKFLOW TESTS
  # ============================================================================

  defp run_workflow_tests(verbose) do
    print_section("📋 WORKFLOW TESTS")

    tests = [
      {"Crear workflow", &check_create_workflow/0},
      {"Listar workflows", &check_list_workflows/0},
      {"Obtener estado de workflow", &check_get_workflow_state/0},
      {"Contar por status", &check_count_by_status/0}
    ]

    run_test_suite(tests, verbose)
  end

  defp check_create_workflow do
    alias Beamflow.Engine.WorkflowSupervisor
    alias Beamflow.Domains.Insurance.InsuranceWorkflow

    workflow_id = "qa-test-#{:rand.uniform(99999)}"

    params = %{
      "applicant_name" => "QA Test User",
      "dni" => "12345678",
      "vehicle_model" => "Test Vehicle",
      "vehicle_year" => "2023",
      "vehicle_plate" => "QA-TEST"
    }

    case WorkflowSupervisor.start_workflow(InsuranceWorkflow, workflow_id, params) do
      {:ok, pid} when is_pid(pid) ->
        # Guardar para pruebas posteriores
        Process.put(:qa_test_workflow_id, workflow_id)
        {:pass, "Workflow #{workflow_id} creado"}

      {:error, {:already_started, _}} ->
        {:pass, "Workflow ya existe (OK para re-ejecución)"}

      error ->
        {:fail, "Error: #{inspect(error)}"}
    end
  end

  defp check_list_workflows do
    alias Beamflow.Storage.WorkflowStore

    case WorkflowStore.list_workflows(limit: 10) do
      {:ok, workflows} when is_list(workflows) ->
        {:pass, "#{length(workflows)} workflows listados"}

      error ->
        {:fail, "Error: #{inspect(error)}"}
    end
  end

  defp check_get_workflow_state do
    alias Beamflow.Engine.WorkflowActor

    workflow_id = Process.get(:qa_test_workflow_id, "qa-test-missing")

    # Esperar un poco para que el workflow se ejecute
    Process.sleep(1000)

    case WorkflowActor.get_state(workflow_id) do
      {:ok, state} when is_map(state) ->
        {:pass, "Estado: #{state.status}"}

      {:error, :not_found} ->
        {:warn, "Workflow no encontrado (puede haber terminado)"}

      error ->
        {:fail, "Error: #{inspect(error)}"}
    end
  end

  defp check_count_by_status do
    alias Beamflow.Storage.WorkflowStore

    case WorkflowStore.count_by_status() do
      {:ok, counts} when is_map(counts) ->
        total = Map.values(counts) |> Enum.sum()
        {:pass, "Total: #{total}, Counts: #{inspect(counts)}"}

      error ->
        {:fail, "Error: #{inspect(error)}"}
    end
  end

  # ============================================================================
  # CHAOS TESTS
  # ============================================================================

  defp run_chaos_tests(verbose) do
    print_section("💥 CHAOS MODE TESTS")

    tests = [
      {"ChaosMonkey disponible", &check_chaos_monkey_available/0},
      {"Iniciar ChaosMonkey", &check_start_chaos_monkey/0},
      {"Obtener estadísticas", &check_chaos_stats/0},
      {"Cambiar perfil", &check_change_profile/0},
      {"Detener ChaosMonkey", &check_stop_chaos_monkey/0}
    ]

    run_test_suite(tests, verbose)
  end

  defp check_chaos_monkey_available do
    if Code.ensure_loaded?(Beamflow.Chaos.ChaosMonkey) do
      {:pass, "Módulo ChaosMonkey cargado"}
    else
      {:fail, "Módulo ChaosMonkey no disponible"}
    end
  end

  defp check_start_chaos_monkey do
    alias Beamflow.Chaos.ChaosMonkey

    # Primero detener si está activo
    ChaosMonkey.stop()

    case ChaosMonkey.start(:gentle) do
      :ok ->
        {:pass, "ChaosMonkey iniciado (gentle)"}

      {:error, reason} ->
        {:fail, "Error al iniciar: #{inspect(reason)}"}
    end
  end

  defp check_chaos_stats do
    alias Beamflow.Chaos.ChaosMonkey

    case ChaosMonkey.stats() do
      stats when is_map(stats) ->
        {:pass, "Stats: enabled=#{stats[:enabled]}, profile=#{stats[:profile]}"}

      error ->
        {:fail, "Error: #{inspect(error)}"}
    end
  end

  defp check_change_profile do
    alias Beamflow.Chaos.ChaosMonkey

    case ChaosMonkey.set_profile(:moderate) do
      :ok ->
        {:pass, "Perfil cambiado a moderate"}

      {:error, reason} ->
        {:fail, "Error: #{inspect(reason)}"}
    end
  end

  defp check_stop_chaos_monkey do
    alias Beamflow.Chaos.ChaosMonkey

    case ChaosMonkey.stop() do
      :ok ->
        {:pass, "ChaosMonkey detenido"}

      {:error, reason} ->
        {:fail, "Error: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # HELPERS
  # ============================================================================

  defp run_test_suite(tests, verbose) do
    Enum.map(tests, fn {name, test_fn} ->
      result = try do
        test_fn.()
      rescue
        e -> {:fail, "Exception: #{inspect(e)}"}
      catch
        :exit, reason -> {:fail, "Exit: #{inspect(reason)}"}
      end

      print_test_result(name, result, verbose)
      {name, result}
    end)
  end

  defp print_test_result(name, {status, details}, verbose) do
    {icon, color} = case status do
      :pass -> {"✓", @green}
      :warn -> {"⚠", @yellow}
      :fail -> {"✗", @red}
    end

    IO.puts("  #{color}#{icon}#{@reset} #{name}")

    if verbose do
      IO.puts("    #{@blue}→ #{details}#{@reset}")
    end
  end

  defp print_section(title) do
    IO.puts("\n#{@bold}#{@blue}#{title}#{@reset}")
    IO.puts("#{String.duplicate("─", 50)}")
  end

  defp print_summary(results) do
    passed = Enum.count(results, fn {_, {status, _}} -> status == :pass end)
    warned = Enum.count(results, fn {_, {status, _}} -> status == :warn end)
    failed = Enum.count(results, fn {_, {status, _}} -> status == :fail end)
    total = length(results)

    IO.puts("\n#{String.duplicate("═", 50)}")
    IO.puts("#{@bold}📊 RESUMEN DE QA#{@reset}")
    IO.puts(String.duplicate("═", 50))

    IO.puts("  #{@green}✓ Pasaron:  #{passed}#{@reset}")
    IO.puts("  #{@yellow}⚠ Warnings: #{warned}#{@reset}")
    IO.puts("  #{@red}✗ Fallaron: #{failed}#{@reset}")
    IO.puts("  Total:     #{total}")

    if failed == 0 do
      IO.puts("\n#{@green}#{@bold}🎉 ¡TODOS LOS TESTS PASARON!#{@reset}")
      System.halt(0)
    else
      IO.puts("\n#{@red}#{@bold}❌ ALGUNOS TESTS FALLARON#{@reset}")

      IO.puts("\n#{@red}Tests fallidos:#{@reset}")
      Enum.each(results, fn
        {name, {:fail, details}} ->
          IO.puts("  • #{name}: #{details}")
        _ -> :ok
      end)

      System.halt(1)
    end
  end

  defp print_banner do
    IO.puts("""

    #{@bold}#{@blue}╔════════════════════════════════════════════════════════╗
    ║                                                        ║
    ║   ██████╗  █████╗     ██████╗██╗  ██╗███████╗ ██████╗  ║
    ║  ██╔═══██╗██╔══██╗   ██╔════╝██║  ██║██╔════╝██╔════╝  ║
    ║  ██║   ██║███████║   ██║     ███████║█████╗  ██║       ║
    ║  ██║▄▄ ██║██╔══██║   ██║     ██╔══██║██╔══╝  ██║       ║
    ║  ╚██████╔╝██║  ██║   ╚██████╗██║  ██║███████╗╚██████╗  ║
    ║   ╚══▀▀═╝ ╚═╝  ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝  ║
    ║                                                        ║
    ║          BEAMFlow QA Check v1.0                        ║
    ╚════════════════════════════════════════════════════════╝#{@reset}
    """)
  end

  defp print_help do
    IO.puts("""

    BEAMFlow QA Check Script
    ========================

    Uso:
      mix run scripts/qa_check.exs [opciones]

    Opciones:
      --section, -s SECTION    Ejecutar solo una sección
      --verbose, -v            Mostrar detalles de cada test
      --help, -h               Mostrar esta ayuda

    Secciones disponibles:
      all        Todas las verificaciones (default)
      smoke      Tests básicos de infraestructura
      api        Verificar endpoints REST
      workflows  Verificar creación y estado de workflows
      chaos      Verificar Chaos Mode

    Ejemplos:
      # Ejecutar todo
      mix run scripts/qa_check.exs

      # Solo API tests con detalle
      mix run scripts/qa_check.exs -s api -v

      # Smoke tests rápidos
      mix run scripts/qa_check.exs -s smoke

    Requisitos:
      - Aplicación corriendo: mix phx.server
      - Mnesia inicializado

    Códigos de salida:
      0 = Todos los tests pasaron
      1 = Algún test falló

    """)
  end

  # HTTP Client simple usando :httpc
  defp http_get(url) do
    # Asegurar que :inets esté iniciado
    :inets.start()
    :ssl.start()

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, status, _}, headers, body}} ->
        headers_list = Enum.map(headers, fn {k, v} ->
          {List.to_string(k), List.to_string(v)}
        end)
        {:ok, status, headers_list, List.to_string(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Ejecutar el script
QACheck.run(System.argv())
