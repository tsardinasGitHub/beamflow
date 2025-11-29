defmodule BeamflowWeb.DemoModeLive do
  @moduledoc """
  LiveView para el Modo Demo de BEAMFlow.

  Permite a evaluadores y reclutadores generar workflows de prueba
  directamente desde la interfaz, sin necesidad de usar la terminal.

  ## Funcionalidades

  - Generar workflows individuales o en lote
  - Activar/desactivar Chaos Mode
  - Ver estadísticas en tiempo real
  - Limpiar datos de demo
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Engine.WorkflowSupervisor
  alias Beamflow.Domains.Insurance.InsuranceWorkflow
  alias Beamflow.Chaos.ChaosMonkey
  alias Beamflow.Storage.WorkflowStore

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
    "Andrés Morales"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Suscribirse a actualizaciones
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflows:updates")
      # Actualizar stats cada 2 segundos
      :timer.send_interval(2000, self(), :refresh_stats)
    end

    socket =
      socket
      |> assign(
        page_title: "Modo Demo",
        workflows_created: 0,
        batch_size: 10,
        chaos_enabled: ChaosMonkey.enabled?(),
        chaos_profile: :moderate,
        creating: false,
        last_created: [],
        stats: load_stats()
      )

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, assign(socket, stats: load_stats())}
  end

  @impl true
  def handle_info({:workflow_created, _}, socket) do
    {:noreply, assign(socket, stats: load_stats())}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_single", _params, socket) do
    socket = assign(socket, creating: true)

    case create_demo_workflow() do
      {:ok, workflow_id, params} ->
        socket =
          socket
          |> assign(
            creating: false,
            workflows_created: socket.assigns.workflows_created + 1,
            last_created: [%{id: workflow_id, params: params} | Enum.take(socket.assigns.last_created, 4)],
            stats: load_stats()
          )
          |> put_flash_auto_hide(:info, "✅ Workflow #{workflow_id} creado")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(creating: false)
          |> put_flash_auto_hide(:error, "❌ Error: #{inspect(reason)}", 5_000)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create_batch", _params, socket) do
    socket = assign(socket, creating: true)
    batch_size = socket.assigns.batch_size

    results =
      for _i <- 1..batch_size do
        create_demo_workflow()
      end

    successful = Enum.count(results, fn
      {:ok, _, _} -> true
      _ -> false
    end)

    last_created =
      results
      |> Enum.filter(fn
        {:ok, _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, id, params} -> %{id: id, params: params} end)
      |> Enum.take(5)

    socket =
      socket
      |> assign(
        creating: false,
        workflows_created: socket.assigns.workflows_created + successful,
        last_created: last_created ++ Enum.take(socket.assigns.last_created, 5 - length(last_created)),
        stats: load_stats()
      )
      |> put_flash_auto_hide(:info, "✅ #{successful}/#{batch_size} workflows creados")

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_batch_size", %{"batch_size" => size}, socket) do
    batch_size = String.to_integer(size)
    {:noreply, assign(socket, batch_size: batch_size)}
  end

  @impl true
  def handle_event("toggle_chaos", _params, socket) do
    if socket.assigns.chaos_enabled do
      ChaosMonkey.stop()
      socket =
        socket
        |> assign(chaos_enabled: false)
        |> put_flash_auto_hide(:info, "🛑 Chaos Mode desactivado")

      {:noreply, socket}
    else
      profile = socket.assigns.chaos_profile
      ChaosMonkey.start(profile)

      socket =
        socket
        |> assign(chaos_enabled: true)
        |> put_flash_auto_hide(:warning, "💥 Chaos Mode activado (#{profile})")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_chaos_profile", %{"profile" => profile}, socket) do
    profile_atom = String.to_existing_atom(profile)

    socket =
      if socket.assigns.chaos_enabled do
        ChaosMonkey.set_profile(profile_atom)
        put_flash_auto_hide(socket, :info, "Perfil cambiado a #{profile}")
      else
        socket
      end

    {:noreply, assign(socket, chaos_profile: profile_atom)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900 p-6">
      <!-- Header -->
      <div class="mb-8">
        <div class="flex items-center gap-4 mb-2">
          <.link navigate={~p"/"} class="text-purple-400 hover:text-purple-300">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 19l-7-7m0 0l7-7m-7 7h18" />
            </svg>
          </.link>
          <h1 class="text-3xl font-bold text-white">🎮 Modo Demo</h1>
        </div>
        <p class="text-slate-400">
          Genera workflows de prueba para explorar las capacidades de BEAMFlow
        </p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <!-- Panel Principal: Generador -->
        <div class="lg:col-span-2 space-y-6">
          <!-- Generador de Workflows -->
          <div class="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
            <h2 class="text-xl font-semibold text-white mb-4 flex items-center gap-2">
              <span class="text-2xl">🚀</span>
              Generador de Workflows
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <!-- Crear Individual -->
              <div class="bg-white/5 rounded-lg p-4 border border-white/10">
                <h3 class="text-white font-medium mb-3">Workflow Individual</h3>
                <p class="text-slate-400 text-sm mb-4">
                  Crea un workflow con datos aleatorios
                </p>
                <button
                  phx-click="create_single"
                  disabled={@creating}
                  class="w-full px-4 py-3 bg-purple-600 hover:bg-purple-700 disabled:bg-purple-800 disabled:cursor-not-allowed text-white rounded-lg font-medium transition-colors flex items-center justify-center gap-2"
                >
                  <%= if @creating do %>
                    <svg class="animate-spin h-5 w-5" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    Creando...
                  <% else %>
                    ➕ Crear Workflow
                  <% end %>
                </button>
              </div>

              <!-- Crear en Lote -->
              <div class="bg-white/5 rounded-lg p-4 border border-white/10">
                <h3 class="text-white font-medium mb-3">Creación en Lote</h3>
                <div class="flex items-center gap-3 mb-4">
                  <input
                    type="range"
                    min="5"
                    max="50"
                    step="5"
                    value={@batch_size}
                    phx-change="update_batch_size"
                    name="batch_size"
                    class="flex-1 h-2 bg-slate-700 rounded-lg appearance-none cursor-pointer"
                  />
                  <span class="text-white font-mono w-12 text-right"><%= @batch_size %></span>
                </div>
                <button
                  phx-click="create_batch"
                  disabled={@creating}
                  class="w-full px-4 py-3 bg-green-600 hover:bg-green-700 disabled:bg-green-800 disabled:cursor-not-allowed text-white rounded-lg font-medium transition-colors flex items-center justify-center gap-2"
                >
                  <%= if @creating do %>
                    <svg class="animate-spin h-5 w-5" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    Creando <%= @batch_size %>...
                  <% else %>
                    📦 Crear <%= @batch_size %> Workflows
                  <% end %>
                </button>
              </div>
            </div>
          </div>

          <!-- Chaos Mode Control -->
          <div class="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
            <h2 class="text-xl font-semibold text-white mb-4 flex items-center gap-2">
              <span class="text-2xl">💥</span>
              Chaos Mode
            </h2>

            <div class="flex flex-col md:flex-row gap-4">
              <!-- Toggle -->
              <div class="flex-1 bg-white/5 rounded-lg p-4 border border-white/10">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="text-white font-medium">Estado</h3>
                    <p class="text-slate-400 text-sm">
                      <%= if @chaos_enabled, do: "Inyectando fallos aleatorios", else: "Desactivado" %>
                    </p>
                  </div>
                  <button
                    phx-click="toggle_chaos"
                    class={"relative inline-flex h-8 w-14 items-center rounded-full transition-colors #{if @chaos_enabled, do: "bg-red-600", else: "bg-slate-600"}"}
                  >
                    <span class={"inline-block h-6 w-6 transform rounded-full bg-white transition-transform #{if @chaos_enabled, do: "translate-x-7", else: "translate-x-1"}"} />
                  </button>
                </div>
              </div>

              <!-- Profile Selector -->
              <div class="flex-1 bg-white/5 rounded-lg p-4 border border-white/10">
                <h3 class="text-white font-medium mb-2">Perfil de Intensidad</h3>
                <div class="flex gap-2">
                  <button
                    :for={profile <- [:gentle, :moderate, :aggressive]}
                    phx-click="set_chaos_profile"
                    phx-value-profile={profile}
                    class={"flex-1 px-3 py-2 rounded-lg text-sm font-medium transition-colors #{if @chaos_profile == profile, do: profile_active_class(profile), else: "bg-slate-700 text-slate-300 hover:bg-slate-600"}"}
                  >
                    <%= profile_label(profile) %>
                  </button>
                </div>
              </div>
            </div>

            <%= if @chaos_enabled do %>
              <div class="mt-4 p-3 bg-red-500/20 border border-red-500/30 rounded-lg">
                <p class="text-red-300 text-sm flex items-center gap-2">
                  <span class="animate-pulse">⚠️</span>
                  <strong>Chaos Mode Activo:</strong> Los workflows pueden fallar intencionalmente para demostrar la resiliencia del sistema.
                </p>
              </div>
            <% end %>
          </div>

          <!-- Últimos Creados -->
          <%= if length(@last_created) > 0 do %>
            <div class="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
              <h2 class="text-xl font-semibold text-white mb-4 flex items-center gap-2">
                <span class="text-2xl">📋</span>
                Últimos Workflows Creados
              </h2>

              <div class="space-y-2">
                <div
                  :for={wf <- @last_created}
                  class="flex items-center justify-between bg-white/5 rounded-lg p-3 border border-white/10"
                >
                  <div>
                    <.link
                      navigate={~p"/workflows/#{wf.id}"}
                      class="text-purple-400 hover:text-purple-300 font-mono text-sm"
                    >
                      <%= wf.id %>
                    </.link>
                    <p class="text-slate-500 text-xs mt-1">
                      <%= wf.params["applicant_name"] %> • <%= wf.params["vehicle_model"] %>
                    </p>
                  </div>
                  <.link
                    navigate={~p"/workflows/#{wf.id}/graph"}
                    class="px-3 py-1 bg-purple-600/30 hover:bg-purple-600/50 text-purple-300 text-sm rounded-lg transition-colors"
                  >
                    Ver Grafo
                  </.link>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Panel Lateral: Stats -->
        <div class="space-y-6">
          <!-- Estadísticas de Sesión -->
          <div class="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
            <h2 class="text-lg font-semibold text-white mb-4">📊 Esta Sesión</h2>
            <div class="text-center">
              <div class="text-5xl font-bold text-purple-400 mb-2">
                <%= @workflows_created %>
              </div>
              <p class="text-slate-400">workflows creados</p>
            </div>
          </div>

          <!-- Estadísticas Globales -->
          <div class="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
            <h2 class="text-lg font-semibold text-white mb-4">🌐 Total en Sistema</h2>
            <div class="space-y-3">
              <.stat_row label="Total" value={@stats.total} color="purple" />
              <.stat_row label="Completados" value={@stats.completed} color="green" />
              <.stat_row label="Fallidos" value={@stats.failed} color="red" />
              <.stat_row label="En Ejecución" value={@stats.running} color="blue" />

              <div class="pt-3 border-t border-white/10">
                <div class="flex justify-between items-center">
                  <span class="text-slate-400">Tasa de Éxito</span>
                  <span class={"font-bold #{if @stats.success_rate >= 80, do: "text-green-400", else: "text-yellow-400"}"}>
                    <%= Float.round(@stats.success_rate, 1) %>%
                  </span>
                </div>
              </div>
            </div>
          </div>

          <!-- Accesos Rápidos -->
          <div class="bg-white/5 backdrop-blur-sm rounded-xl border border-white/10 p-6">
            <h2 class="text-lg font-semibold text-white mb-4">🔗 Accesos Rápidos</h2>
            <div class="space-y-2">
              <.link
                navigate={~p"/workflows"}
                class="block w-full px-4 py-3 bg-white/5 hover:bg-white/10 rounded-lg text-slate-300 transition-colors text-center"
              >
                📂 Explorar Workflows
              </.link>
              <.link
                navigate={~p"/analytics"}
                class="block w-full px-4 py-3 bg-white/5 hover:bg-white/10 rounded-lg text-slate-300 transition-colors text-center"
              >
                📈 Ver Analytics
              </.link>
              <.link
                navigate={~p"/resilience"}
                class="block w-full px-4 py-3 bg-white/5 hover:bg-white/10 rounded-lg text-slate-300 transition-colors text-center"
              >
                🛡️ Panel de Resiliencia
              </.link>
            </div>
          </div>

          <!-- Tips -->
          <div class="bg-amber-500/10 backdrop-blur-sm rounded-xl border border-amber-500/20 p-6">
            <h2 class="text-lg font-semibold text-amber-300 mb-3">💡 Tips</h2>
            <ul class="text-amber-200/80 text-sm space-y-2">
              <li>• Crea workflows y observa el <strong>Explorer</strong> actualizarse en tiempo real</li>
              <li>• Activa <strong>Chaos Mode</strong> para ver auto-recuperación</li>
              <li>• Usa el <strong>Modo Replay</strong> en el grafo para debugging</li>
              <li>• Revisa <strong>Analytics</strong> para ver métricas agregadas</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Componentes

  defp stat_row(assigns) do
    color_class = case assigns.color do
      "purple" -> "text-purple-400"
      "green" -> "text-green-400"
      "red" -> "text-red-400"
      "blue" -> "text-blue-400"
      _ -> "text-white"
    end

    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class="flex justify-between items-center">
      <span class="text-slate-400"><%= @label %></span>
      <span class={"font-bold #{@color_class}"}><%= @value %></span>
    </div>
    """
  end

  # Helpers

  defp create_demo_workflow do
    {vehicle_model, vehicle_year} = Enum.random(@vehicles)
    name = Enum.random(@names)
    dni = generate_dni()
    plate = generate_plate()
    workflow_id = "demo-#{timestamp()}-#{:rand.uniform(9999)}"

    params = %{
      "applicant_name" => name,
      "dni" => dni,
      "vehicle_model" => vehicle_model,
      "vehicle_year" => to_string(vehicle_year),
      "vehicle_plate" => plate
    }

    case WorkflowSupervisor.start_workflow(InsuranceWorkflow, workflow_id, params) do
      {:ok, _pid} -> {:ok, workflow_id, params}
      error -> error
    end
  end

  defp load_stats do
    case WorkflowStore.count_by_status() do
      {:ok, counts} ->
        total = Map.values(counts) |> Enum.sum()
        completed = Map.get(counts, :completed, 0)
        failed = Map.get(counts, :failed, 0)
        running = Map.get(counts, :running, 0) + Map.get(counts, :pending, 0)

        success_rate = if total > 0, do: completed / total * 100, else: 0.0

        %{
          total: total,
          completed: completed,
          failed: failed,
          running: running,
          success_rate: success_rate
        }

      _ ->
        %{total: 0, completed: 0, failed: 0, running: 0, success_rate: 0.0}
    end
  end

  defp generate_dni do
    :rand.uniform(99_999_999)
    |> Integer.to_string()
    |> String.pad_leading(8, "0")
  end

  defp generate_plate do
    letters = ~w(A B C D E F G H J K L M N P R S T V W X Y Z)
    prefix = Enum.random(letters) <> Enum.random(letters) <> Enum.random(letters)
    "#{prefix}-#{:rand.uniform(999) |> Integer.to_string() |> String.pad_leading(3, "0")}"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_unix()
    |> Integer.to_string()
    |> String.slice(-6, 6)
  end

  defp profile_label(:gentle), do: "🌱 Suave"
  defp profile_label(:moderate), do: "⚡ Moderado"
  defp profile_label(:aggressive), do: "🔥 Agresivo"

  defp profile_active_class(:gentle), do: "bg-green-600 text-white"
  defp profile_active_class(:moderate), do: "bg-yellow-600 text-white"
  defp profile_active_class(:aggressive), do: "bg-red-600 text-white"
end
