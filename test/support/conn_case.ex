defmodule BeamflowWeb.ConnCase do
  @moduledoc """
  Test case para tests que requieren conexiones HTTP.

  Proporciona helpers y configuración para testing de controllers
  y endpoints HTTP.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Importar helpers de Phoenix.ConnTest
      import Plug.Conn
      import Phoenix.ConnTest
      alias BeamflowWeb.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint BeamflowWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
