defmodule Mix.Tasks.Beamflow.Audit do
  @shortdoc "Audita todos los workflows del proyecto y genera un reporte de validación"

  @moduledoc """
  Analiza todos los workflows del proyecto y genera un reporte de issues de validación.

  Similar a Credo, este comando escanea todos los módulos que implementan
  `Beamflow.Workflows.Workflow` y ejecuta validaciones sobre sus grafos.

  ## Uso

      $ mix beamflow.audit
      $ mix beamflow.audit --strict
      $ mix beamflow.audit --paranoid
      $ mix beamflow.audit --pedantic
      $ mix beamflow.audit --format json
      $ mix beamflow.audit --only-errors

  ## Opciones

    * `--strict` - Modo estricto: reduce umbrales de complejidad a 3
    * `--paranoid` - Modo paranoico: reduce umbrales a 2
    * `--pedantic` - Modo pedante: cualquier branch sin default es error
    * `--format` - Formato de salida: `text` (default) o `json`
    * `--only-errors` - Solo mostrar errores, ignorar warnings
    * `--quiet` - No mostrar output, solo exit code

  ## Exit Codes

    * `0` - Sin errores (puede tener warnings)
    * `1` - Uno o más errores encontrados
    * `2` - Error al ejecutar el audit (configuración inválida, etc.)

  ## Ejemplo de Output

      $ mix beamflow.audit

      Beamflow Workflow Audit
      ═══════════════════════

      Checking 3 workflows...

      ✗ Beamflow.Domains.Insurance.InsuranceWorkflow
        [E] branch "decision" has 6 options without :default path
            → Consider adding a :default handler for unexpected states

      ✓ Beamflow.Domains.Examples.BranchingWorkflowExample

      ✓ MyApp.OrderWorkflow
        [W] branch "status_check" has 4 options (approaching complexity threshold of 5)

      ───────────────────────
      Summary: 1 error, 1 warning in 3 workflows

  """

  use Mix.Task

  alias Beamflow.Workflows.Graph

  @recursive true

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          strict: :boolean,
          paranoid: :boolean,
          pedantic: :boolean,
          format: :string,
          only_errors: :boolean,
          quiet: :boolean,
          help: :boolean
        ]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      exit_with_code(0)
    end

    # Compilar el proyecto para asegurar que todos los módulos estén disponibles
    Mix.Task.run("compile", ["--no-warnings"])

    # Encontrar todos los workflows
    workflows = discover_workflows()

    if Enum.empty?(workflows) do
      unless opts[:quiet] do
        Mix.shell().info([
          :yellow,
          "No se encontraron workflows en el proyecto.\n",
          :reset,
          "Asegúrate de que tus módulos implementen ",
          :cyan,
          "@behaviour Beamflow.Workflows.Workflow",
          :reset
        ])
      end

      exit_with_code(0)
    end

    # Validar cada workflow
    validation_opts = build_validation_opts(opts)
    results = Enum.map(workflows, &validate_workflow(&1, validation_opts))

    # Generar reporte
    format = opts[:format] || "text"
    only_errors = opts[:only_errors] || false

    report = generate_report(results, format, only_errors)

    unless opts[:quiet] do
      Mix.shell().info(report)
    end

    # Determinar exit code
    has_errors = Enum.any?(results, fn {_module, issues} ->
      Enum.any?(issues, &(&1.severity == :error))
    end)

    if has_errors do
      exit_with_code(1)
    else
      exit_with_code(0)
    end
  end

  # Exit con código apropiado.
  # En tests, esto será capturado; en producción, terminará el proceso.
  defp exit_with_code(code) do
    if Mix.env() == :test do
      throw({:exit_code, code})
    else
      System.halt(code)
    end
  end

  # ============================================================================
  # Descubrimiento de Workflows
  # ============================================================================

  defp discover_workflows do
    # Obtener todas las aplicaciones cargadas
    apps = get_project_apps()

    apps
    |> Enum.flat_map(&get_app_modules/1)
    |> Enum.filter(&is_workflow?/1)
    |> Enum.sort()
  end

  defp get_project_apps do
    # Obtener la app principal del proyecto
    case Mix.Project.config()[:app] do
      nil -> []
      app -> [app]
    end
  end

  defp get_app_modules(app) do
    # Asegurar que la app esté cargada
    Application.load(app)

    case Application.spec(app, :modules) do
      nil -> []
      modules -> modules
    end
  end

  defp is_workflow?(module) do
    # Un workflow válido tiene graph/0 que retorna un Graph struct
    # Puede implementar el behaviour Workflow o solo definir graph/0
    Code.ensure_loaded?(module) &&
      function_exported?(module, :graph, 0) &&
      (implements_workflow_behaviour?(module) || has_valid_graph?(module))
  end

  defp implements_workflow_behaviour?(module) do
    behaviours = module.module_info(:attributes)[:behaviour] || []
    Beamflow.Workflows.Workflow in behaviours
  rescue
    _ -> false
  end

  defp has_valid_graph?(module) do
    # Verificar si graph/0 retorna un struct Graph válido
    try do
      graph = module.graph()
      is_struct(graph, Beamflow.Workflows.Graph)
    rescue
      _ -> false
    end
  end

  # ============================================================================
  # Validación
  # ============================================================================

  defp build_validation_opts(cli_opts) do
    [
      strict_mode: cli_opts[:strict] || false,
      paranoid_mode: cli_opts[:paranoid] || false,
      pedantic_mode: cli_opts[:pedantic] || false
    ]
  end

  defp validate_workflow(module, opts) do
    try do
      graph = module.graph()

      case Graph.validate(graph, opts) do
        {:ok, warnings} -> {module, warnings}
        {:error, errors} -> {module, errors}
      end
    rescue
      e ->
        error_issue = %{
          severity: :error,
          message: "Error al obtener el grafo: #{Exception.message(e)}",
          node_id: nil
        }
        {module, [error_issue]}
    end
  end

  # ============================================================================
  # Generación de Reportes
  # ============================================================================

  defp generate_report(results, "json", only_errors) do
    filtered_results =
      if only_errors do
        Enum.map(results, fn {module, issues} ->
          {module, Enum.filter(issues, &(&1.severity == :error))}
        end)
      else
        results
      end

    data = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      workflows: Enum.map(filtered_results, &format_json_result/1),
      summary: build_summary(results)
    }

    Jason.encode!(data, pretty: true)
  end

  defp generate_report(results, _format, only_errors) do
    filtered_results =
      if only_errors do
        Enum.map(results, fn {module, issues} ->
          {module, Enum.filter(issues, &(&1.severity == :error))}
        end)
      else
        results
      end

    lines = [
      "",
      format_header(),
      "",
      format_progress(results),
      "",
      Enum.map(filtered_results, &format_text_result/1),
      "",
      format_separator(),
      format_summary(results),
      ""
    ]

    lines
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_header do
    [
      [:bright, :cyan, "Beamflow Workflow Audit", :reset],
      [:cyan, "═══════════════════════", :reset]
    ]
    |> Enum.map(&IO.ANSI.format/1)
  end

  defp format_progress(results) do
    count = length(results)
    IO.ANSI.format([:faint, "Checking #{count} workflow#{if count == 1, do: "", else: "s"}...", :reset])
  end

  defp format_separator do
    IO.ANSI.format([:faint, "───────────────────────", :reset])
  end

  defp format_text_result({module, []}) do
    [
      IO.ANSI.format([:green, "✓ ", :reset, :bright, inspect(module), :reset]),
      ""
    ]
  end

  defp format_text_result({module, issues}) do
    has_errors = Enum.any?(issues, &(&1.severity == :error))

    header = if has_errors do
      IO.ANSI.format([:red, "✗ ", :reset, :bright, inspect(module), :reset])
    else
      IO.ANSI.format([:yellow, "⚠ ", :reset, :bright, inspect(module), :reset])
    end

    issue_lines = Enum.map(issues, &format_issue/1)

    [header | issue_lines] ++ [""]
  end

  defp format_issue(%{severity: :error, message: msg, node_id: node_id}) do
    node_info = if node_id, do: " (#{node_id})", else: ""
    IO.ANSI.format([:faint, "  ", :reset, :red, "[E]", :reset, " #{msg}#{node_info}"])
  end

  defp format_issue(%{severity: :warning, message: msg, node_id: node_id}) do
    node_info = if node_id, do: " (#{node_id})", else: ""
    IO.ANSI.format([:faint, "  ", :reset, :yellow, "[W]", :reset, " #{msg}#{node_info}"])
  end

  defp format_issue(%{severity: severity, message: msg}) do
    IO.ANSI.format([:faint, "  [#{severity}] #{msg}", :reset])
  end

  defp format_summary(results) do
    summary = build_summary(results)

    color = cond do
      summary.error_count > 0 -> :red
      summary.warning_count > 0 -> :yellow
      true -> :green
    end

    parts = []
    parts = if summary.error_count > 0, do: parts ++ ["#{summary.error_count} error#{if summary.error_count == 1, do: "", else: "s"}"], else: parts
    parts = if summary.warning_count > 0, do: parts ++ ["#{summary.warning_count} warning#{if summary.warning_count == 1, do: "", else: "s"}"], else: parts

    issues_text = if Enum.empty?(parts), do: "no issues", else: Enum.join(parts, ", ")

    IO.ANSI.format([color, "Summary: #{issues_text} in #{summary.workflow_count} workflow#{if summary.workflow_count == 1, do: "", else: "s"}", :reset])
  end

  defp build_summary(results) do
    all_issues = Enum.flat_map(results, fn {_mod, issues} -> issues end)

    %{
      workflow_count: length(results),
      error_count: Enum.count(all_issues, &(&1.severity == :error)),
      warning_count: Enum.count(all_issues, &(&1.severity == :warning))
    }
  end

  defp format_json_result({module, issues}) do
    %{
      module: inspect(module),
      issues: Enum.map(issues, fn issue ->
        %{
          severity: issue.severity,
          message: issue.message,
          node_id: issue[:node_id]
        }
      end)
    }
  end
end
