defmodule BeamflowWeb.PageController do
  @moduledoc """
  Controller para páginas estáticas de la aplicación.

  Maneja las rutas de páginas que no requieren lógica de negocio
  compleja, como la página principal.
  """

  use BeamflowWeb, :controller

  @doc """
  Renderiza la página de inicio de Beamflow.
  """
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    render(conn, :home)
  end
end
