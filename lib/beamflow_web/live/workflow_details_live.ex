defmodule BeamflowWeb.WorkflowDetailsLive do
  @moduledoc """
  LiveView para visualizar los detalles de un workflow específico.

  Muestra información detallada sobre un workflow individual, incluyendo
  su estado actual, historial de ejecución y métricas.

  ## Parámetros de URL

  - `id` - Identificador único del workflow a visualizar
  """

  use BeamflowWeb, :live_view

  @doc """
  Inicializa el LiveView cargando los datos del workflow.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, page_title: "Workflow #{id}", id: id)}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl">
      <div class="mb-6">
        <.link navigate={~p"/dashboard"} class="text-blue-600 hover:underline">
          &larr; Back to Dashboard
        </.link>
      </div>

      <h1 class="text-2xl font-bold mb-4">Workflow Details: <%= @id %></h1>

      <div class="bg-white p-6 rounded shadow border">
        <p>Details for workflow <%= @id %> will appear here.</p>
      </div>
    </div>
    """
  end
end
