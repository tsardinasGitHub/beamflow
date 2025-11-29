defmodule BeamflowWeb.WorkflowExplorerLive do
  @moduledoc """
  Explorador de Workflows con filtros avanzados y actualizaciones en tiempo real.

  ## Características

  - **Streams**: Actualizaciones incrementales eficientes
  - **Filtros**: Por estado, módulo, fecha
  - **Búsqueda**: Por ID de workflow
  - **Ordenamiento**: Por fecha, estado
  - **Paginación**: Virtual scroll con streams
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Storage.WorkflowStore
  alias Beamflow.Engine.WorkflowSupervisor
  alias Beamflow.Domains.Insurance.InsuranceWorkflow

  @default_filters %{
    status: nil,
    module: nil,
    search: "",
    date_from: nil,
    date_to: nil
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflows")
      # Batch updates cada 300ms
      :timer.send_interval(300, self(), :process_updates)
    end

    socket =
      socket
      |> assign(page_title: "Workflows")
      |> assign(filters: @default_filters)
      |> assign(sort_by: :updated_at)
      |> assign(sort_order: :desc)
      |> assign(pending_updates: MapSet.new())
      |> assign(stats: %{total: 0, filtered: 0})
      |> assign(available_modules: [])
      |> stream(:workflows, [], reset: true)
      |> load_workflows()
      |> load_available_modules()

    {:ok, socket}
  end

  @impl true
  def handle_info({:workflow_updated, %{workflow_id: workflow_id}}, socket) when is_binary(workflow_id) do
    # Acumular IDs para batch update
    pending = MapSet.put(socket.assigns.pending_updates, workflow_id)
    {:noreply, assign(socket, pending_updates: pending)}
  end

  @impl true
  def handle_info({:workflow_updated, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_info({:refresh_for_new_workflow, workflow_id}, socket) do
    # Buscar el workflow recién creado y añadirlo al stream
    socket =
      case WorkflowStore.get_workflow(workflow_id) do
        {:ok, workflow} ->
          if matches_filters?(workflow, socket.assigns.filters) do
            socket
            |> stream_insert(:workflows, workflow, at: 0)
            |> update_stats()
          else
            socket
          end

        _ ->
          # Si no está listo todavía, reintentar una vez más
          Process.send_after(self(), {:refresh_for_new_workflow_retry, workflow_id}, 200)
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:refresh_for_new_workflow_retry, workflow_id}, socket) do
    # Último intento de buscar el workflow
    socket =
      case WorkflowStore.get_workflow(workflow_id) do
        {:ok, workflow} ->
          if matches_filters?(workflow, socket.assigns.filters) do
            socket
            |> stream_insert(:workflows, workflow, at: 0)
            |> update_stats()
          else
            socket
          end

        _ ->
          # Si aún no está, el PubSub batch update lo capturará
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:process_updates, socket) do
    pending = socket.assigns.pending_updates

    socket =
      if MapSet.size(pending) > 0 do
        # Obtener workflows actualizados
        updated_workflows =
          pending
          |> MapSet.to_list()
          |> Enum.map(&WorkflowStore.get_workflow/1)
          |> Enum.filter(fn
            {:ok, wf} -> matches_filters?(wf, socket.assigns.filters)
            _ -> false
          end)
          |> Enum.map(fn {:ok, wf} -> wf end)

        # Actualizar stream
        socket =
          Enum.reduce(updated_workflows, socket, fn wf, acc ->
            stream_insert(acc, :workflows, wf, at: 0)
          end)

        socket
        |> assign(pending_updates: MapSet.new())
        |> update_stats()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      status: parse_status(params["status"]),
      module: parse_module(params["module"]),
      search: params["search"] || "",
      date_from: parse_date(params["date_from"]),
      date_to: parse_date(params["date_to"])
    }

    socket =
      socket
      |> assign(filters: filters)
      |> stream(:workflows, [], reset: true)
      |> load_workflows()

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(filters: @default_filters)
      |> stream(:workflows, [], reset: true)
      |> load_workflows()

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"by" => field}, socket) do
    field = String.to_existing_atom(field)

    {sort_by, sort_order} =
      if socket.assigns.sort_by == field do
        # Toggle order
        order = if socket.assigns.sort_order == :asc, do: :desc, else: :asc
        {field, order}
      else
        {field, :desc}
      end

    socket =
      socket
      |> assign(sort_by: sort_by, sort_order: sort_order)
      |> stream(:workflows, [], reset: true)
      |> load_workflows()

    {:noreply, socket}
  end

  @impl true
  def handle_event("create_workflow", _params, socket) do
    workflow_id = "wf-#{:rand.uniform(9999)}"
    user_num = :rand.uniform(100)

    params = %{
      "applicant_name" => "User #{user_num}",
      "applicant_email" => "user.#{user_num}@test.com",
      "dni" => "#{:rand.uniform(99_999_999)}",
      "vehicle_model" => "Test Vehicle",
      "vehicle_year" => "2024",
      "vehicle_plate" => "TST-#{:rand.uniform(999)}"
    }

    case WorkflowSupervisor.start_workflow(InsuranceWorkflow, workflow_id, params) do
      {:ok, _pid} ->
        # Programar actualización después de que el workflow se persista
        Process.send_after(self(), {:refresh_for_new_workflow, workflow_id}, 100)
        # Auto-hide flash después de 3 segundos
        Process.send_after(self(), :clear_flash, 3_000)
        {:noreply, put_flash(socket, :info, "Workflow #{workflow_id} creado")}

      {:error, reason} ->
        Process.send_after(self(), :clear_flash, 5_000)
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("retry_workflow", %{"id" => id}, socket) do
    # TODO: Implementar retry
    {:noreply, put_flash(socket, :info, "Retry de #{id} programado")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-900">
      <!-- Header -->
      <header class="bg-slate-800/50 border-b border-slate-700/50 sticky top-0 z-10 backdrop-blur-sm">
        <div class="max-w-7xl mx-auto px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <.link navigate="/" class="text-slate-400 hover:text-white transition">
                ← Dashboard
              </.link>
              <h1 class="text-xl font-bold text-white">📋 Workflow Explorer</h1>
            </div>

            <button
              phx-click="create_workflow"
              class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition flex items-center gap-2"
            >
              <span>+</span>
              <span>Nuevo Workflow</span>
            </button>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto px-6 py-6 space-y-6">
        <!-- Filters -->
        <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
          <form phx-change="filter" class="flex flex-wrap gap-4 items-end">
            <!-- Search -->
            <div class="flex-1 min-w-[200px]">
              <label class="block text-sm text-slate-400 mb-1">Buscar</label>
              <input
                type="text"
                name="filters[search]"
                value={@filters.search}
                placeholder="ID del workflow..."
                class="w-full px-3 py-2 bg-slate-900 border border-slate-700 rounded-lg text-white placeholder-slate-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                phx-debounce="300"
              />
            </div>

            <!-- Status Filter -->
            <div class="w-40">
              <label class="block text-sm text-slate-400 mb-1">Estado</label>
              <select
                name="filters[status]"
                class="w-full px-3 py-2 bg-slate-900 border border-slate-700 rounded-lg text-white"
              >
                <option value="">Todos</option>
                <option value="pending" selected={@filters.status == :pending}>Pendiente</option>
                <option value="running" selected={@filters.status == :running}>Ejecutando</option>
                <option value="completed" selected={@filters.status == :completed}>Completado</option>
                <option value="failed" selected={@filters.status == :failed}>Fallido</option>
              </select>
            </div>

            <!-- Module Filter -->
            <div class="w-48">
              <label class="block text-sm text-slate-400 mb-1">Módulo</label>
              <select
                name="filters[module]"
                class="w-full px-3 py-2 bg-slate-900 border border-slate-700 rounded-lg text-white"
              >
                <option value="">Todos</option>
                <option :for={mod <- @available_modules} value={mod} selected={@filters.module == mod}>
                  <%= format_module_name(mod) %>
                </option>
              </select>
            </div>

            <!-- Date From -->
            <div class="w-40">
              <label class="block text-sm text-slate-400 mb-1">Desde</label>
              <input
                type="date"
                name="filters[date_from]"
                value={@filters.date_from}
                class="w-full px-3 py-2 bg-slate-900 border border-slate-700 rounded-lg text-white"
              />
            </div>

            <!-- Date To -->
            <div class="w-40">
              <label class="block text-sm text-slate-400 mb-1">Hasta</label>
              <input
                type="date"
                name="filters[date_to]"
                value={@filters.date_to}
                class="w-full px-3 py-2 bg-slate-900 border border-slate-700 rounded-lg text-white"
              />
            </div>

            <!-- Clear Filters -->
            <button
              type="button"
              phx-click="clear_filters"
              class="px-4 py-2 text-slate-400 hover:text-white transition"
            >
              Limpiar
            </button>
          </form>
        </section>

        <!-- Stats Bar -->
        <div class="flex items-center justify-between text-sm text-slate-400">
          <div>
            Mostrando <span class="text-white font-medium"><%= @stats.filtered %></span>
            de <span class="text-white font-medium"><%= @stats.total %></span> workflows
          </div>
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
            Actualizaciones en vivo
          </div>
        </div>

        <!-- Workflow Table -->
        <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 overflow-hidden">
          <table class="w-full">
            <thead class="bg-slate-900/50">
              <tr>
                <th class="px-4 py-3 text-left">
                  <button
                    phx-click="sort"
                    phx-value-by="id"
                    class="flex items-center gap-1 text-sm font-semibold text-slate-400 hover:text-white"
                  >
                    ID
                    <.sort_icon field={:id} current={@sort_by} order={@sort_order} />
                  </button>
                </th>
                <th class="px-4 py-3 text-left text-sm font-semibold text-slate-400">Módulo</th>
                <th class="px-4 py-3 text-left">
                  <button
                    phx-click="sort"
                    phx-value-by="status"
                    class="flex items-center gap-1 text-sm font-semibold text-slate-400 hover:text-white"
                  >
                    Estado
                    <.sort_icon field={:status} current={@sort_by} order={@sort_order} />
                  </button>
                </th>
                <th class="px-4 py-3 text-left text-sm font-semibold text-slate-400">Progreso</th>
                <th class="px-4 py-3 text-left">
                  <button
                    phx-click="sort"
                    phx-value-by="updated_at"
                    class="flex items-center gap-1 text-sm font-semibold text-slate-400 hover:text-white"
                  >
                    Actualizado
                    <.sort_icon field={:updated_at} current={@sort_by} order={@sort_order} />
                  </button>
                </th>
                <th class="px-4 py-3 text-right text-sm font-semibold text-slate-400">Acciones</th>
              </tr>
            </thead>
            <tbody id="workflows-stream" phx-update="stream" class="divide-y divide-slate-700/50">
              <tr
                :for={{dom_id, wf} <- @streams.workflows}
                id={dom_id}
                class="hover:bg-slate-700/30 transition-colors"
              >
                <td class="px-4 py-3">
                  <.link
                    navigate={~p"/workflows/#{wf.id}"}
                    class="font-mono text-sm text-blue-400 hover:text-blue-300"
                  >
                    <%= wf.id %>
                  </.link>
                </td>
                <td class="px-4 py-3 text-sm text-slate-300">
                  <%= format_module_name(wf.workflow_module) %>
                </td>
                <td class="px-4 py-3">
                  <.status_badge status={wf.status} />
                </td>
                <td class="px-4 py-3 w-48">
                  <.progress_bar current={wf.current_step_index || 0} total={wf.total_steps || 1} />
                </td>
                <td class="px-4 py-3 text-sm text-slate-400">
                  <%= format_datetime(wf.updated_at) %>
                </td>
                <td class="px-4 py-3 text-right">
                  <div class="flex items-center justify-end gap-2">
                    <.link
                      navigate={~p"/workflows/#{wf.id}"}
                      class="p-2 text-slate-400 hover:text-white hover:bg-slate-700 rounded transition"
                      title="Ver detalles"
                    >
                      👁️
                    </.link>
                    <.link
                      navigate={~p"/workflows/#{wf.id}/graph"}
                      class="p-2 text-slate-400 hover:text-purple-400 hover:bg-slate-700 rounded transition"
                      title="Ver grafo"
                    >
                      📊
                    </.link>
                    <button
                      :if={wf.status == :failed}
                      phx-click="retry_workflow"
                      phx-value-id={wf.id}
                      class="p-2 text-slate-400 hover:text-green-400 hover:bg-slate-700 rounded transition"
                      title="Reintentar"
                    >
                      🔄
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <div
            :if={@stats.filtered == 0}
            class="p-12 text-center text-slate-500"
          >
            <div class="text-5xl mb-4">🔍</div>
            <p class="text-lg">No se encontraron workflows</p>
            <p class="text-sm mt-2">Intenta ajustar los filtros o crear un nuevo workflow</p>
          </div>
        </section>
      </main>
    </div>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  attr :field, :atom, required: true
  attr :current, :atom, required: true
  attr :order, :atom, required: true

  defp sort_icon(assigns) do
    ~H"""
    <span :if={@field == @current} class="text-blue-400">
      <%= if @order == :asc, do: "↑", else: "↓" %>
    </span>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    {text, classes} =
      case assigns.status do
        :pending -> {"Pendiente", "bg-yellow-500/20 text-yellow-400 border-yellow-500/30"}
        :running -> {"Ejecutando", "bg-blue-500/20 text-blue-400 border-blue-500/30"}
        :completed -> {"Completado", "bg-green-500/20 text-green-400 border-green-500/30"}
        :failed -> {"Fallido", "bg-red-500/20 text-red-400 border-red-500/30"}
        _ -> {"Desconocido", "bg-slate-500/20 text-slate-400 border-slate-500/30"}
      end

    assigns = assign(assigns, text: text, classes: classes)

    ~H"""
    <span class={"px-2 py-1 text-xs font-medium rounded-full border #{@classes}"}>
      <%= @text %>
    </span>
    """
  end

  attr :current, :integer, required: true
  attr :total, :integer, required: true

  defp progress_bar(assigns) do
    percentage = if assigns.total > 0, do: assigns.current / assigns.total * 100, else: 0
    assigns = assign(assigns, :percentage, percentage)

    ~H"""
    <div class="flex items-center gap-2">
      <div class="flex-1 h-2 bg-slate-700 rounded-full overflow-hidden">
        <div
          class="h-full bg-gradient-to-r from-blue-500 to-blue-400 transition-all duration-300"
          style={"width: #{@percentage}%"}
        >
        </div>
      </div>
      <span class="text-xs text-slate-500 w-10 text-right"><%= @current %>/<%= @total %></span>
    </div>
    """
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_workflows(socket) do
    filters = socket.assigns.filters
    sort_by = socket.assigns.sort_by
    sort_order = socket.assigns.sort_order

    case WorkflowStore.list_workflows(limit: 100) do
      {:ok, workflows} ->
        filtered =
          workflows
          |> filter_workflows(filters)
          |> sort_workflows(sort_by, sort_order)

        socket
        |> stream(:workflows, filtered, reset: true)
        |> assign(stats: %{total: length(workflows), filtered: length(filtered)})

      {:error, _} ->
        assign(socket, stats: %{total: 0, filtered: 0})
    end
  end

  defp load_available_modules(socket) do
    case WorkflowStore.list_workflows(limit: 500) do
      {:ok, workflows} ->
        modules =
          workflows
          |> Enum.map(& &1.workflow_module)
          |> Enum.uniq()
          |> Enum.filter(&is_atom/1)
          |> Enum.map(&Atom.to_string/1)

        assign(socket, available_modules: modules)

      _ ->
        assign(socket, available_modules: [])
    end
  end

  defp update_stats(socket) do
    case WorkflowStore.list_workflows(limit: 500) do
      {:ok, workflows} ->
        filtered = filter_workflows(workflows, socket.assigns.filters)
        assign(socket, stats: %{total: length(workflows), filtered: length(filtered)})

      _ ->
        socket
    end
  end

  defp filter_workflows(workflows, filters) do
    workflows
    |> filter_by_status(filters.status)
    |> filter_by_module(filters.module)
    |> filter_by_search(filters.search)
    |> filter_by_date_range(filters.date_from, filters.date_to)
  end

  defp filter_by_status(workflows, nil), do: workflows
  defp filter_by_status(workflows, status) do
    Enum.filter(workflows, &(&1.status == status))
  end

  defp filter_by_module(workflows, nil), do: workflows
  defp filter_by_module(workflows, ""), do: workflows
  defp filter_by_module(workflows, module) when is_binary(module) do
    Enum.filter(workflows, fn wf ->
      Atom.to_string(wf.workflow_module) == module
    end)
  end

  defp filter_by_search(workflows, ""), do: workflows
  defp filter_by_search(workflows, nil), do: workflows
  defp filter_by_search(workflows, search) do
    search_lower = String.downcase(search)
    Enum.filter(workflows, fn wf ->
      String.contains?(String.downcase(wf.id), search_lower)
    end)
  end

  defp filter_by_date_range(workflows, nil, nil), do: workflows
  defp filter_by_date_range(workflows, date_from, date_to) do
    Enum.filter(workflows, fn wf ->
      in_date_range?(wf.updated_at, date_from, date_to)
    end)
  end

  defp in_date_range?(nil, _, _), do: true
  defp in_date_range?(%DateTime{} = dt, date_from, date_to) do
    date = DateTime.to_date(dt)

    from_ok = is_nil(date_from) or Date.compare(date, date_from) in [:gt, :eq]
    to_ok = is_nil(date_to) or Date.compare(date, date_to) in [:lt, :eq]

    from_ok and to_ok
  end
  defp in_date_range?(_, _, _), do: true

  defp sort_workflows(workflows, sort_by, sort_order) do
    sorted = Enum.sort_by(workflows, &Map.get(&1, sort_by), fn a, b ->
      case {a, b} do
        {%DateTime{} = da, %DateTime{} = db} -> DateTime.compare(da, db) == :lt
        {a, b} when is_atom(a) and is_atom(b) -> Atom.to_string(a) < Atom.to_string(b)
        {a, b} -> a < b
      end
    end)

    if sort_order == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp matches_filters?(workflow, filters) do
    (is_nil(filters.status) or workflow.status == filters.status) and
      (is_nil(filters.module) or filters.module == "" or
         Atom.to_string(workflow.workflow_module) == filters.module) and
      (filters.search == "" or String.contains?(workflow.id, filters.search))
  end

  defp parse_status(""), do: nil
  defp parse_status(nil), do: nil
  defp parse_status(status), do: String.to_existing_atom(status)

  defp parse_module(""), do: nil
  defp parse_module(nil), do: nil
  defp parse_module(module), do: module

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil
  defp parse_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp format_module_name(nil), do: "Unknown"
  defp format_module_name(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  end
  defp format_module_name(module) when is_binary(module) do
    module |> String.split(".") |> List.last()
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
  defp format_datetime(_), do: "-"
end
