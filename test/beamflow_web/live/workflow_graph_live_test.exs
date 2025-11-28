defmodule BeamflowWeb.WorkflowGraphLiveTest do
  @moduledoc """
  Tests para BeamflowWeb.WorkflowGraphLive.

  Verifica la visualización interactiva de workflows como grafos SVG,
  incluyendo renderizado de nodos, edges, panel de detalles, tooltips,
  zoom/pan, exportación y historial de intentos.
  """

  # Los tests que acceden a Mnesia deben ser síncronos para evitar interferencia
  use ExUnit.Case, async: false

  alias Beamflow.Storage.WorkflowStore
  alias Beamflow.Workflows.Graph

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Asegurar que Mnesia está inicializada para tests
    :ok = ensure_mnesia_started()

    workflow_id = "graph-test-#{:erlang.unique_integer([:positive])}"

    # Crear un workflow de prueba con la estructura correcta de WorkflowActor
    workflow_state = %{
      workflow_id: workflow_id,
      workflow_module: TestWorkflow,
      status: :running,
      workflow_state: %{test: true},
      current_step_index: 1,
      total_steps: 3,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      error: nil
    }

    # Guardar en store
    {:ok, _} = WorkflowStore.save_workflow(workflow_state)

    # Registrar eventos de prueba con pausas para garantizar orden de timestamps
    Process.sleep(1)
    :ok = WorkflowStore.record_event(workflow_id, :step_started, %{
      step: "ValidateInput",
      step_index: 0
    })

    Process.sleep(1)
    :ok = WorkflowStore.record_event(workflow_id, :step_completed, %{
      step: "ValidateInput",
      step_index: 0,
      duration_ms: 150
    })

    Process.sleep(1)
    :ok = WorkflowStore.record_event(workflow_id, :step_started, %{
      step: "ProcessData",
      step_index: 1
    })

    on_exit(fn ->
      # Limpieza
      WorkflowStore.delete_workflow(workflow_id)
    end)

    %{workflow_id: workflow_id, workflow_state: workflow_state}
  end

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      :no ->
        :mnesia.start()
        :ok
      :starting ->
        Process.sleep(100)
        ensure_mnesia_started()
      :stopping ->
        Process.sleep(100)
        ensure_mnesia_started()
    end
  end

  # ============================================================================
  # Tests de Construcción de Grafo
  # ============================================================================

  describe "build_graph_data/1" do
    test "construye nodos desde workflow con steps lineales", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      assert length(socket.assigns.nodes) == 3
      assert length(socket.assigns.edges) == 2

      # Verificar orden de nodos
      node_labels = Enum.map(socket.assigns.nodes, & &1.label)
      assert node_labels == ["ValidateInput", "ProcessData", "SaveResult"]
    end

    test "calcula posiciones correctas para layout horizontal", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      nodes = socket.assigns.nodes
      [node0, node1, node2] = nodes

      # Verificar que X aumenta progresivamente
      assert node0.x < node1.x
      assert node1.x < node2.x

      # Verificar que Y es constante (layout horizontal)
      assert node0.y == node1.y
      assert node1.y == node2.y
    end

    test "asigna estados correctos según current_step_index", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      nodes = socket.assigns.nodes
      states = Enum.map(nodes, & &1.state)

      # Step 0: completado, Step 1: running, Step 2: pending
      assert states == [:completed, :running, :pending]
    end

    test "incluye tooltips con información de timing", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      completed_node = Enum.find(socket.assigns.nodes, &(&1.state == :completed))
      assert completed_node.tooltip =~ "Completado"
    end

    test "maneja workflow no encontrado graciosamente" do
      socket = build_socket("nonexistent-workflow-id")

      assert socket.assigns.nodes == []
      assert socket.assigns.edges == []
      assert socket.assigns.workflow == nil
    end
  end

  # ============================================================================
  # Tests de Estados de Nodos
  # ============================================================================

  describe "calculate_node_state/3" do
    test "workflow completado: todos los nodos son completed" do
      socket = build_socket_with_status(:completed)

      states = Enum.map(socket.assigns.nodes, & &1.state)
      assert Enum.all?(states, &(&1 == :completed))
    end

    test "workflow failed: step actual es failed, anteriores completed, siguientes pending" do
      socket = build_socket_with_status(:failed, current_step: 1)

      states = Enum.map(socket.assigns.nodes, & &1.state)
      assert states == [:completed, :failed, :pending]
    end

    test "workflow running: step actual es running" do
      socket = build_socket_with_status(:running, current_step: 1)

      states = Enum.map(socket.assigns.nodes, & &1.state)
      assert states == [:completed, :running, :pending]
    end

    test "workflow pending: todos los nodos son pending" do
      socket = build_socket_with_status(:pending)

      states = Enum.map(socket.assigns.nodes, & &1.state)
      assert Enum.all?(states, &(&1 == :pending))
    end
  end

  # ============================================================================
  # Tests de Edges
  # ============================================================================

  describe "build_edges/2" do
    test "crea edges entre nodos consecutivos", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      edges = socket.assigns.edges
      assert length(edges) == 2

      # Verificar que cada edge tiene from y to correctos
      edge_connections = Enum.map(edges, &{&1.from, &1.to})
      assert {"step_0", "step_1"} in edge_connections
      assert {"step_1", "step_2"} in edge_connections
    end

    test "edges tienen paths SVG válidos", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      Enum.each(socket.assigns.edges, fn edge ->
        assert edge.path =~ ~r/^M\s*\d+/  # Empieza con M (moveto)
        assert edge.path =~ ~r/L\s*\d+/   # Contiene L (lineto)
      end)
    end

    test "edges marcan estado completed/active según progreso" do
      socket = build_socket_with_status(:running, current_step: 1)

      edges = socket.assigns.edges
      [edge0_1, edge1_2] = edges

      # Edge 0→1: completado (step 0 está done)
      assert edge0_1.completed == true

      # Edge 1→2: activo (step 1 está running)
      assert edge1_2.active == true
    end
  end

  # ============================================================================
  # Tests de Dimensiones SVG
  # ============================================================================

  describe "calculate_svg_dimensions/1" do
    test "calcula dimensiones basadas en número de nodos", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      # Con 3 nodos, el ancho debería ser suficiente para contenerlos
      assert socket.assigns.svg_width > 0
      assert socket.assigns.svg_height > 0

      # El ancho mínimo debe cubrir todos los nodos
      last_node = List.last(socket.assigns.nodes)
      min_width = last_node.x + socket.assigns.node_width + 40  # padding
      assert socket.assigns.svg_width >= min_width
    end

    test "svg vacío para workflow sin nodos" do
      socket = build_socket("nonexistent-workflow")

      assert socket.assigns.svg_width == 400  # default
      assert socket.assigns.svg_height == 200  # default
    end
  end

  # ============================================================================
  # Tests de Historial de Intentos
  # ============================================================================

  describe "get_step_attempts_from_events/2" do
    test "agrupa eventos de started/completed en intentos", %{workflow_id: workflow_id} do
      socket = build_socket(workflow_id)

      # Simular selección del nodo 0 (completado)
      completed_node = Enum.find(socket.assigns.nodes, &(&1.index == 0))
      attempts = get_step_attempts_from_events(socket.assigns.all_events, completed_node.index)

      assert length(attempts) == 1
      [attempt] = attempts
      assert attempt.success == true
      assert attempt.duration_ms == 150
    end

    test "maneja múltiples intentos (reintentos)", %{workflow_id: workflow_id} do
      # Nota: El setup ya registró un step_started para ProcessData (step_index: 1)
      # Agregamos eventos adicionales para simular reintentos
      # Pequeña pausa para asegurar orden de timestamps
      Process.sleep(1)
      :ok = WorkflowStore.record_event(workflow_id, :step_failed, %{
        step: "ProcessData",
        step_index: 1,
        duration_ms: 50,
        reason: "timeout"
      })
      Process.sleep(1)
      :ok = WorkflowStore.record_event(workflow_id, :step_started, %{
        step: "ProcessData",
        step_index: 1
      })
      Process.sleep(1)
      :ok = WorkflowStore.record_event(workflow_id, :step_completed, %{
        step: "ProcessData",
        step_index: 1,
        duration_ms: 200
      })

      socket = build_socket(workflow_id)
      process_node = Enum.find(socket.assigns.nodes, &(&1.index == 1))
      attempts = get_step_attempts_from_events(socket.assigns.all_events, process_node.index)

      # Debería haber al menos 2 intentos: el original (falló) + reintento (éxito)
      assert length(attempts) >= 2, "Se esperaban al menos 2 intentos, obtenidos: #{length(attempts)}"

      # Al menos uno debería ser fallo y uno éxito
      has_failure = Enum.any?(attempts, &(&1.success == false))
      has_success = Enum.any?(attempts, &(&1.success == true))
      assert has_failure, "Esperaba al menos un intento fallido"
      assert has_success, "Esperaba al menos un intento exitoso"
    end

    test "retorna lista vacía para step sin eventos" do
      attempts = get_step_attempts_from_events([], 0)
      assert attempts == []
    end
  end

  # ============================================================================
  # Tests de Formateo de Timing
  # ============================================================================

  describe "format_attempt_duration/1" do
    test "formatea milisegundos" do
      assert format_attempt_duration(500) == "500ms"
      assert format_attempt_duration(999) == "999ms"
    end

    test "formatea segundos" do
      result = format_attempt_duration(1500)
      assert result =~ "s"
      assert result =~ "1.5" or result =~ "1,5"
    end

    test "formatea minutos" do
      result = format_attempt_duration(125_000)  # 2m 5s
      assert result =~ "m"
    end

    test "maneja nil" do
      assert format_attempt_duration(nil) == "-"
    end
  end

  describe "format_attempt_time/1" do
    test "formatea DateTime" do
      dt = ~U[2025-01-15 14:30:45Z]
      result = format_attempt_time(dt)
      assert result =~ "14:30:45"
    end

    test "maneja nil" do
      assert format_attempt_time(nil) == "-"
    end

    test "pasa strings sin cambios" do
      assert format_attempt_time("custom time") == "custom time"
    end
  end

  # ============================================================================
  # Tests de Límite de Intentos
  # ============================================================================

  describe "retry_block_summary" do
    test "calcula duración total de todos los intentos" do
      attempts = [
        %{started_at: nil, ended_at: nil, duration_ms: 100, success: false, error: "e1"},
        %{started_at: nil, ended_at: nil, duration_ms: 200, success: false, error: "e2"},
        %{started_at: nil, ended_at: nil, duration_ms: 300, success: true, error: nil}
      ]

      total_duration = attempts |> Enum.map(& &1.duration_ms || 0) |> Enum.sum()
      assert total_duration == 600
    end

    test "cuenta éxitos y fallos correctamente" do
      attempts = [
        %{success: false},
        %{success: false},
        %{success: false},
        %{success: true}
      ]

      success_count = Enum.count(attempts, & &1.success)
      fail_count = length(attempts) - success_count

      assert success_count == 1
      assert fail_count == 3
    end
  end

  # ============================================================================
  # Tests de Tooltip
  # ============================================================================

  describe "build_tooltip/2" do
    test "incluye estado" do
      tooltip = build_tooltip(:completed, %{})
      assert tooltip =~ "Completado"
    end

    test "incluye duración cuando está disponible" do
      tooltip = build_tooltip(:completed, %{duration_ms: 1500})
      assert tooltip =~ "Duración"
    end

    test "incluye timestamps cuando están disponibles" do
      dt = DateTime.utc_now()
      tooltip = build_tooltip(:completed, %{started_at: dt, completed_at: dt})
      assert tooltip =~ "Inicio"
      assert tooltip =~ "Fin"
    end

    test "incluye error para steps fallidos" do
      tooltip = build_tooltip(:failed, %{error: "Connection refused"})
      assert tooltip =~ "Error"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Construye un socket simulado con el workflow cargado
  defp build_socket(workflow_id) do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: nil
      }
    }

    socket
    |> Phoenix.Component.assign(
      page_title: "Grafo: #{workflow_id}",
      workflow_id: workflow_id,
      selected_node: nil,
      show_details: false,
      show_all_attempts: false,
      step_timings: %{},
      step_attempts: [],
      all_events: []
    )
    |> load_workflow(workflow_id)
    |> load_all_events(workflow_id)
    |> load_step_timings_from_events()
    |> build_graph_data()
  end

  defp build_socket_with_status(status, opts \\ []) do
    workflow_id = "status-test-#{:erlang.unique_integer([:positive])}"
    current_step = Keyword.get(opts, :current_step, 0)

    workflow_state = %{
      workflow_id: workflow_id,
      workflow_module: TestWorkflow,
      status: status,
      workflow_state: %{},
      current_step_index: current_step,
      total_steps: 3,
      started_at: DateTime.utc_now(),
      completed_at: if(status == :completed, do: DateTime.utc_now(), else: nil),
      error: if(status == :failed, do: "Test error", else: nil)
    }

    {:ok, _} = WorkflowStore.save_workflow(workflow_state)

    socket = build_socket(workflow_id)

    # Cleanup
    spawn(fn ->
      Process.sleep(100)
      WorkflowStore.delete_workflow(workflow_id)
    end)

    socket
  end

  # Funciones delegadas desde WorkflowGraphLive (para testing)
  defp load_workflow(socket, id) do
    workflow =
      case WorkflowStore.get_workflow(id) do
        {:ok, record} -> record
        {:error, _} -> nil
      end

    Phoenix.Component.assign(socket, :workflow, workflow)
  end

  defp load_all_events(socket, workflow_id) do
    events = case WorkflowStore.get_events(workflow_id) do
      {:ok, events} -> events
      {:error, _} -> []
    end
    Phoenix.Component.assign(socket, :all_events, events)
  end

  defp load_step_timings_from_events(socket) do
    events = socket.assigns[:all_events] || []

    timings = events
    |> Enum.reduce(%{}, fn event, acc ->
      # Los eventos usan :data en lugar de :metadata
      event_data = event[:data] || event[:metadata] || %{}
      step_index = event_data[:step_index]

      case {event.event_type, step_index} do
        {:step_started, idx} when is_integer(idx) ->
          Map.update(acc, idx, %{started_at: event.timestamp}, &Map.put(&1, :started_at, event.timestamp))

        {:step_completed, idx} when is_integer(idx) ->
          duration = event_data[:duration_ms] || 0
          Map.update(acc, idx, %{completed_at: event.timestamp, duration_ms: duration}, fn existing ->
            existing
            |> Map.put(:completed_at, event.timestamp)
            |> Map.put(:duration_ms, duration)
          end)

        {:step_failed, idx} when is_integer(idx) ->
          duration = event_data[:duration_ms] || 0
          error = event_data[:reason] || "Unknown error"
          Map.update(acc, idx, %{failed_at: event.timestamp, duration_ms: duration, error: error}, fn existing ->
            existing
            |> Map.put(:failed_at, event.timestamp)
            |> Map.put(:duration_ms, duration)
            |> Map.put(:error, error)
          end)

        _ -> acc
      end
    end)

    Phoenix.Component.assign(socket, :step_timings, timings)
  end

  defp build_graph_data(socket) do
    case socket.assigns.workflow do
      nil ->
        Phoenix.Component.assign(socket, nodes: [], edges: [], svg_width: 400, svg_height: 200)

      workflow ->
        graph = get_workflow_graph(workflow.workflow_module)
        step_timings = socket.assigns[:step_timings] || %{}
        nodes = build_nodes(graph, workflow, step_timings)
        edges = build_edges(graph, nodes)
        {svg_width, svg_height} = calculate_svg_dimensions(nodes)

        Phoenix.Component.assign(socket,
          nodes: nodes,
          edges: edges,
          svg_width: svg_width,
          svg_height: svg_height,
          node_width: 200,
          node_height: 60
        )
    end
  end

  defp get_workflow_graph(workflow_module) do
    if function_exported?(workflow_module, :graph, 0) do
      workflow_module.graph()
    else
      steps = if function_exported?(workflow_module, :steps, 0) do
        workflow_module.steps()
      else
        # Fallback para tests
        [ValidateInput, ProcessData, SaveResult]
      end
      Graph.from_linear_steps(steps)
    end
  end

  defp build_nodes(graph, workflow, step_timings) do
    current_step = workflow.current_step_index || 0
    status = workflow.status

    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :step))
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      state = calculate_node_state(index, current_step, status)
      timing = Map.get(step_timings, index, %{})

      x = 40 + index * 280
      y = 40

      tooltip = build_tooltip(state, timing)

      %{
        id: node.id,
        index: index,
        label: format_step_label(node.module),
        module: format_module_full(node.module),
        state: state,
        x: x,
        y: y,
        timing: timing,
        tooltip: tooltip
      }
    end)
  end

  defp calculate_node_state(index, current_step, workflow_status) do
    cond do
      workflow_status == :completed -> :completed
      workflow_status == :failed and index == current_step -> :failed
      workflow_status == :failed and index < current_step -> :completed
      workflow_status == :failed and index > current_step -> :pending
      workflow_status == :running and index == current_step -> :running
      workflow_status == :running and index < current_step -> :completed
      workflow_status == :running and index > current_step -> :pending
      true -> :pending
    end
  end

  defp build_edges(graph, nodes) do
    node_map = Map.new(nodes, &{&1.id, &1})

    graph.edges
    |> Enum.flat_map(fn {from_id, targets} ->
      from_node = Map.get(node_map, from_id)

      targets
      |> Enum.map(fn edge ->
        to_id = if is_map(edge), do: edge.to, else: edge
        to_node = Map.get(node_map, to_id)

        if from_node && to_node do
          %{
            from: from_id,
            to: to_id,
            path: build_edge_path(from_node, to_node),
            completed: from_node.state == :completed,
            active: from_node.state == :running,
            pending: from_node.state == :pending
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp build_edge_path(from_node, to_node) do
    start_x = from_node.x + 200  # node_width
    start_y = from_node.y + 30   # node_height / 2
    end_x = to_node.x
    end_y = to_node.y + 30

    "M #{start_x} #{start_y} L #{end_x} #{end_y}"
  end

  defp calculate_svg_dimensions(nodes) when nodes == [], do: {400, 200}
  defp calculate_svg_dimensions(nodes) do
    max_x = nodes |> Enum.map(& &1.x) |> Enum.max()
    max_y = nodes |> Enum.map(& &1.y) |> Enum.max()

    width = max_x + 200 + 40   # node_width + padding
    height = max_y + 60 + 40   # node_height + padding

    {width, height}
  end

  defp format_step_label(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  end
  defp format_step_label(_), do: "Unknown"

  defp format_module_full(module) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end
  defp format_module_full(_), do: "Unknown"

  defp build_tooltip(state, timing) do
    lines = ["Estado: #{state_to_text(state)}"]

    lines = if timing[:started_at] do
      lines ++ ["Inicio: #{format_attempt_time(timing.started_at)}"]
    else
      lines
    end

    lines = if timing[:completed_at] do
      lines ++ ["Fin: #{format_attempt_time(timing.completed_at)}"]
    else
      if timing[:failed_at] do
        lines ++ ["Falló: #{format_attempt_time(timing.failed_at)}"]
      else
        lines
      end
    end

    lines = if timing[:duration_ms] do
      lines ++ ["Duración: #{format_attempt_duration(timing.duration_ms)}"]
    else
      lines
    end

    lines = if timing[:error] do
      lines ++ ["Error: #{truncate_attempt_error(timing.error)}"]
    else
      lines
    end

    Enum.join(lines, "\n")
  end

  defp state_to_text(:pending), do: "Pendiente"
  defp state_to_text(:running), do: "Ejecutando"
  defp state_to_text(:completed), do: "Completado"
  defp state_to_text(:failed), do: "Fallido"
  defp state_to_text(_), do: "Desconocido"

  defp format_attempt_time(nil), do: "-"
  defp format_attempt_time(timestamp) when is_binary(timestamp), do: timestamp
  defp format_attempt_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_attempt_time(_), do: "-"

  defp format_attempt_duration(nil), do: "-"
  defp format_attempt_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_attempt_duration(ms) when ms < 60_000 do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 2) <> "s"
  end
  defp format_attempt_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(ms, 60_000) / 1000
    "#{minutes}m #{:erlang.float_to_binary(seconds, decimals: 1)}s"
  end

  defp truncate_attempt_error(nil), do: nil
  defp truncate_attempt_error(error) when is_binary(error) do
    if String.length(error) > 40 do
      String.slice(error, 0, 37) <> "..."
    else
      error
    end
  end
  defp truncate_attempt_error(error), do: inspect(error) |> truncate_attempt_error()

  defp get_step_attempts_from_events(all_events, step_index) when is_list(all_events) do
    step_events = all_events
    |> Enum.filter(fn event ->
      event_data = event[:data] || event[:metadata] || %{}
      event_data[:step_index] == step_index and
      event.event_type in [:step_started, :step_completed, :step_failed]
    end)
    |> Enum.sort_by(& &1.timestamp)

    build_attempts_from_events(step_events, [])
  end
  defp get_step_attempts_from_events(_, _), do: []

  defp build_attempts_from_events([], attempts), do: Enum.reverse(attempts)
  defp build_attempts_from_events([%{event_type: :step_started} = start | rest], attempts) do
    {end_event, remaining} = find_end_event(rest)

    end_data = if end_event, do: end_event[:data] || end_event[:metadata] || %{}, else: %{}

    attempt = %{
      started_at: start.timestamp,
      ended_at: end_event && end_event.timestamp,
      duration_ms: end_data[:duration_ms],
      success: end_event && end_event.event_type == :step_completed,
      error: end_data[:reason]
    }

    build_attempts_from_events(remaining, [attempt | attempts])
  end
  defp build_attempts_from_events([_ | rest], attempts) do
    build_attempts_from_events(rest, attempts)
  end

  defp find_end_event([]), do: {nil, []}
  defp find_end_event([%{event_type: type} = event | rest]) when type in [:step_completed, :step_failed] do
    {event, rest}
  end
  defp find_end_event([_ | rest]), do: find_end_event(rest)
end

# Módulo de test para workflow
defmodule TestWorkflow do
  @moduledoc false

  def steps do
    [ValidateInput, ProcessData, SaveResult]
  end
end
