defmodule Beamflow.Workflows.GraphTest do
  @moduledoc """
  Tests para Beamflow.Workflows.Graph.

  Verifica el correcto funcionamiento del sistema de grafos,
  incluyendo branching, default paths y manejo de errores.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Workflows.Graph

  describe "from_linear_steps/1" do
    test "convierte lista de steps a grafo lineal" do
      steps = [StepA, StepB, StepC]
      graph = Graph.from_linear_steps(steps)

      assert graph.start_node == "step_0"
      assert graph.end_nodes == ["step_2"]
      assert map_size(graph.nodes) == 3
    end

    test "grafo vacío para lista vacía" do
      graph = Graph.from_linear_steps([])

      assert graph.nodes == %{}
      assert graph.edges == %{}
    end
  end

  describe "next_nodes/3 para branches" do
    test "retorna nodo que coincide con la condición" do
      graph = build_branch_graph()

      # Condición retorna :approved
      state = %{status: :approved}
      assert {:ok, ["approved_path"]} = Graph.next_nodes(graph, "decision", state)

      # Condición retorna :rejected
      state = %{status: :rejected}
      assert {:ok, ["rejected_path"]} = Graph.next_nodes(graph, "decision", state)
    end

    test "usa default path cuando ninguna condición coincide" do
      graph = build_branch_graph_with_default()

      # Condición retorna :unknown (no hay branch específico)
      state = %{status: :unknown}
      assert {:ok, ["default_path"]} = Graph.next_nodes(graph, "decision", state)
    end

    test "retorna error cuando no hay coincidencia ni default" do
      graph = build_branch_graph()  # Sin default

      # Condición retorna :unknown (no hay branch para esto)
      state = %{status: :unknown}
      assert {:error, :no_matching_branch} = Graph.next_nodes(graph, "decision", state)
    end

    test "prioriza coincidencia exacta sobre default" do
      graph = build_branch_graph_with_default()

      # Condición retorna :approved (hay branch específico)
      state = %{status: :approved}
      assert {:ok, ["approved_path"]} = Graph.next_nodes(graph, "decision", state)
    end
  end

  describe "next_nodes/3 para steps" do
    test "retorna siguiente nodo en secuencia" do
      graph = Graph.from_linear_steps([StepA, StepB, StepC])

      assert {:ok, ["step_1"]} = Graph.next_nodes(graph, "step_0", %{})
      assert {:ok, ["step_2"]} = Graph.next_nodes(graph, "step_1", %{})
      assert {:ok, []} = Graph.next_nodes(graph, "step_2", %{})
    end
  end

  describe "next_nodes/3 para joins" do
    test "continúa al siguiente nodo después del join" do
      graph =
        Graph.new()
        |> Graph.add_step("step_a", StepA)
        |> Graph.add_join("join")
        |> Graph.add_step("step_b", StepB)
        |> Graph.connect("step_a", "join")
        |> Graph.connect("join", "step_b")

      assert {:ok, ["step_b"]} = Graph.next_nodes(graph, "join", %{})
    end
  end

  # ============================================================================
  # Tests de Validación Estática
  # ============================================================================

  describe "validate/1" do
    test "grafo válido retorna {:ok, []}" do
      graph =
        Graph.new()
        |> Graph.add_step("start", StartStep)
        |> Graph.add_step("end", EndStep)
        |> Graph.set_start("start")
        |> Graph.set_end("end")
        |> Graph.connect("start", "end")

      assert {:ok, []} = Graph.validate(graph)
    end

    test "grafo vacío retorna error por no start node y info por vacío" do
      graph = Graph.new()

      assert {:error, issues} = Graph.validate(graph)
      assert Enum.any?(issues, &(&1.code == :empty_graph))
      assert Enum.any?(issues, &(&1.code == :no_start_node))
    end

    test "sin start node retorna error" do
      graph =
        Graph.new()
        |> Graph.add_step("step1", StepA)

      assert {:error, issues} = Graph.validate(graph)
      assert Enum.any?(issues, &(&1.code == :no_start_node))
    end

    test "start node inexistente retorna error" do
      graph =
        Graph.new()
        |> Graph.add_step("step1", StepA)
        |> Graph.set_start("nonexistent")

      assert {:error, issues} = Graph.validate(graph)
      assert Enum.any?(issues, &(&1.code == :start_node_not_found))
    end

    test "branch sin default retorna warning" do
      graph = build_branch_graph()  # Sin default

      assert {:ok, issues} = Graph.validate(graph)
      assert Enum.any?(issues, &(&1.code == :branch_without_default))
    end

    test "branch con default no genera warning" do
      graph = build_branch_graph_with_default()

      assert {:ok, issues} = Graph.validate(graph)
      refute Enum.any?(issues, &(&1.code == :branch_without_default))
    end

    test "nodos inalcanzables generan warning" do
      graph =
        Graph.new()
        |> Graph.add_step("start", StartStep)
        |> Graph.add_step("reachable", StepA)
        |> Graph.add_step("orphan", StepB)  # No conectado
        |> Graph.set_start("start")
        |> Graph.connect("start", "reachable")

      assert {:ok, issues} = Graph.validate(graph)
      assert Enum.any?(issues, fn issue ->
        issue.code == :unreachable_nodes and
          "orphan" in issue.context.unreachable_nodes
      end)
    end

    test "edges a nodos inexistentes generan warning" do
      graph =
        Graph.new()
        |> Graph.add_step("start", StartStep)
        |> Graph.set_start("start")
        |> Graph.connect("start", "nonexistent")

      assert {:ok, issues} = Graph.validate(graph)
      assert Enum.any?(issues, &(&1.code == :orphan_edges))
    end
  end

  describe "validate!/1" do
    test "retorna el grafo si es válido" do
      graph =
        Graph.new()
        |> Graph.add_step("start", StartStep)
        |> Graph.set_start("start")

      assert ^graph = Graph.validate!(graph)
    end

    test "lanza excepción si hay errores" do
      graph =
        Graph.new()
        |> Graph.add_step("step1", StepA)
        # Sin start node

      assert_raise ArgumentError, ~r/Invalid workflow graph/, fn ->
        Graph.validate!(graph)
      end
    end
  end

  # ============================================================================
  # Tests para Branch Complexity
  # ============================================================================

  describe "validate/1 - branch complexity" do
    test "warning para branch con >5 opciones pero con default" do
      graph = build_complex_branch_with_default()

      {:ok, issues} = Graph.validate(graph)

      complex_warning = Enum.find(issues, &(&1.code == :complex_branch))
      assert complex_warning != nil
      assert complex_warning.severity == :warning
      assert complex_warning.context.option_count == 7
      assert complex_warning.context.has_default == true
      assert complex_warning.message =~ "Consider refactoring"
    end

    test "error para branch con >=5 opciones sin default" do
      graph = build_complex_branch_without_default()

      {:error, issues} = Graph.validate(graph)

      complex_error = Enum.find(issues, &(&1.code == :branch_missing_default))
      assert complex_error != nil
      assert complex_error.severity == :error
      assert complex_error.context.option_count == 6
      assert complex_error.context.has_default == false
      assert complex_error.message =~ "default is required"
    end

    test "error para branch con exactamente 5 opciones sin default" do
      graph = build_branch_with_5_options()

      # 5 opciones sin default = error (umbral de escalación)
      {:error, issues} = Graph.validate(graph)

      error = Enum.find(issues, &(&1.code == :branch_missing_default))
      assert error != nil
      assert error.severity == :error
      assert error.context.option_count == 5
    end

    test "warning para branch con 4 opciones sin default" do
      graph = build_branch_with_4_options()

      # 4 opciones sin default = warning (bajo umbral de error)
      {:ok, issues} = Graph.validate(graph)

      warning = Enum.find(issues, &(&1.code == :branch_without_default))
      assert warning != nil
      assert warning.severity == :warning
    end

    test "sin warning de complejidad para branch con 5 opciones y default" do
      graph = build_branch_with_5_options_and_default()

      {:ok, issues} = Graph.validate(graph)

      # No debería haber ningún issue de branches
      refute Enum.any?(issues, &(&1.code in [:complex_branch, :branch_missing_default, :branch_without_default]))
    end

    test "validate! lanza para branch con 5+ opciones sin default" do
      graph = build_complex_branch_without_default()

      assert_raise ArgumentError, ~r/default is required/, fn ->
        Graph.validate!(graph)
      end
    end

    test "max_branch_options configurable via opciones" do
      graph = build_branch_with_4_options_and_default()

      # Con umbral por defecto (5), 4 opciones está bien
      {:ok, issues_default} = Graph.validate(graph)
      refute Enum.any?(issues_default, &(&1.code == :complex_branch))

      # Con umbral reducido (3), 4 opciones es complejo
      {:ok, issues_strict} = Graph.validate(graph, max_branch_options: 3)
      assert Enum.any?(issues_strict, &(&1.code == :complex_branch))
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_branch_graph do
    Graph.new()
    |> Graph.add_step("start", StartStep)
    |> Graph.add_branch("decision", fn state -> Map.get(state, :status) end)
    |> Graph.add_step("approved_path", ApprovedStep)
    |> Graph.add_step("rejected_path", RejectedStep)
    |> Graph.set_start("start")
    |> Graph.connect("start", "decision")
    |> Graph.connect_branch("decision", "approved_path", :approved)
    |> Graph.connect_branch("decision", "rejected_path", :rejected)
  end

  defp build_branch_graph_with_default do
    build_branch_graph()
    |> Graph.add_step("default_path", DefaultStep)
    |> Graph.connect_branch("decision", "default_path", :default)
  end

  # Branch con 7 opciones (>5) pero con :default
  defp build_complex_branch_with_default do
    Graph.new()
    |> Graph.add_step("start", StartStep)
    |> Graph.add_branch("complex_decision", fn state -> Map.get(state, :level) end)
    |> Graph.add_step("path_1", StepA)
    |> Graph.add_step("path_2", StepA)
    |> Graph.add_step("path_3", StepA)
    |> Graph.add_step("path_4", StepA)
    |> Graph.add_step("path_5", StepA)
    |> Graph.add_step("path_6", StepA)
    |> Graph.add_step("default_path", StepA)
    |> Graph.set_start("start")
    |> Graph.connect("start", "complex_decision")
    |> Graph.connect_branch("complex_decision", "path_1", :level_1)
    |> Graph.connect_branch("complex_decision", "path_2", :level_2)
    |> Graph.connect_branch("complex_decision", "path_3", :level_3)
    |> Graph.connect_branch("complex_decision", "path_4", :level_4)
    |> Graph.connect_branch("complex_decision", "path_5", :level_5)
    |> Graph.connect_branch("complex_decision", "path_6", :level_6)
    |> Graph.connect_branch("complex_decision", "default_path", :default)
  end

  # Branch con 6 opciones (>5) sin :default
  defp build_complex_branch_without_default do
    Graph.new()
    |> Graph.add_step("start", StartStep)
    |> Graph.add_branch("risky_decision", fn state -> Map.get(state, :code) end)
    |> Graph.add_step("path_a", StepA)
    |> Graph.add_step("path_b", StepA)
    |> Graph.add_step("path_c", StepA)
    |> Graph.add_step("path_d", StepA)
    |> Graph.add_step("path_e", StepA)
    |> Graph.add_step("path_f", StepA)
    |> Graph.set_start("start")
    |> Graph.connect("start", "risky_decision")
    |> Graph.connect_branch("risky_decision", "path_a", :code_a)
    |> Graph.connect_branch("risky_decision", "path_b", :code_b)
    |> Graph.connect_branch("risky_decision", "path_c", :code_c)
    |> Graph.connect_branch("risky_decision", "path_d", :code_d)
    |> Graph.connect_branch("risky_decision", "path_e", :code_e)
    |> Graph.connect_branch("risky_decision", "path_f", :code_f)
  end

  # Branch con exactamente 5 opciones sin default (umbral de error)
  defp build_branch_with_5_options do
    Graph.new()
    |> Graph.add_step("start", StartStep)
    |> Graph.add_branch("ok_decision", fn state -> Map.get(state, :tier) end)
    |> Graph.add_step("tier_1", StepA)
    |> Graph.add_step("tier_2", StepA)
    |> Graph.add_step("tier_3", StepA)
    |> Graph.add_step("tier_4", StepA)
    |> Graph.add_step("tier_5", StepA)
    |> Graph.set_start("start")
    |> Graph.connect("start", "ok_decision")
    |> Graph.connect_branch("ok_decision", "tier_1", :tier_1)
    |> Graph.connect_branch("ok_decision", "tier_2", :tier_2)
    |> Graph.connect_branch("ok_decision", "tier_3", :tier_3)
    |> Graph.connect_branch("ok_decision", "tier_4", :tier_4)
    |> Graph.connect_branch("ok_decision", "tier_5", :tier_5)
  end

  # Branch con 5 opciones totales CON default (4 + default = 5, no da warning de complejidad)
  defp build_branch_with_5_options_and_default do
    Graph.new()
    |> Graph.add_step("start", StartStep)
    |> Graph.add_branch("safe_decision", fn state -> Map.get(state, :tier) end)
    |> Graph.add_step("tier_1", StepA)
    |> Graph.add_step("tier_2", StepA)
    |> Graph.add_step("tier_3", StepA)
    |> Graph.add_step("tier_4", StepA)
    |> Graph.add_step("default_tier", StepA)
    |> Graph.set_start("start")
    |> Graph.connect("start", "safe_decision")
    |> Graph.connect_branch("safe_decision", "tier_1", :tier_1)
    |> Graph.connect_branch("safe_decision", "tier_2", :tier_2)
    |> Graph.connect_branch("safe_decision", "tier_3", :tier_3)
    |> Graph.connect_branch("safe_decision", "tier_4", :tier_4)
    |> Graph.connect_branch("safe_decision", "default_tier", :default)
  end

  # Branch con 4 opciones sin default (warning, no error)
  defp build_branch_with_4_options do
    Graph.new()
    |> Graph.add_step("start", StartStep)
    |> Graph.add_branch("four_decision", fn state -> Map.get(state, :level) end)
    |> Graph.add_step("level_1", StepA)
    |> Graph.add_step("level_2", StepA)
    |> Graph.add_step("level_3", StepA)
    |> Graph.add_step("level_4", StepA)
    |> Graph.set_start("start")
    |> Graph.connect("start", "four_decision")
    |> Graph.connect_branch("four_decision", "level_1", :l1)
    |> Graph.connect_branch("four_decision", "level_2", :l2)
    |> Graph.connect_branch("four_decision", "level_3", :l3)
    |> Graph.connect_branch("four_decision", "level_4", :l4)
  end

  # Branch con 4 opciones con default (para test de configurabilidad)
  defp build_branch_with_4_options_and_default do
    build_branch_with_4_options()
    |> Graph.add_step("default_level", StepA)
    |> Graph.connect_branch("four_decision", "default_level", :default)
  end
end
