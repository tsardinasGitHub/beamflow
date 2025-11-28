defmodule Beamflow.Workflows.RouteLoaderTest do
  @moduledoc """
  Tests para el RouteLoader
  """
  use ExUnit.Case, async: false

  alias Beamflow.Workflows.RouteLoader

  # Asegurar que RouteLoader está corriendo antes de cada test
  setup do
    # Si no está corriendo, lo iniciamos para el test
    case Process.whereis(RouteLoader) do
      nil ->
        {:ok, _pid} = RouteLoader.start_link([])
        on_exit(fn -> GenServer.stop(RouteLoader, :normal) end)

      _pid ->
        :ok
    end

    :ok
  end

  describe "load/2 con JSON" do
    test "carga rutas desde archivo JSON" do
      path = Path.join([Application.app_dir(:beamflow), "priv", "routes", "example_states.json"])

      assert {:ok, routes} = RouteLoader.load({:json, path})
      assert routes[:default] == "generic_state_flow"
      assert routes["CA"] == "california_flow"
      assert routes["TX"] == "texas_flow"
    end

    test "resuelve paths con priv/" do
      assert {:ok, routes} = RouteLoader.load({:json, "priv/routes/example_states.json"})
      assert routes[:default] == "generic_state_flow"
    end

    test "error si archivo no existe" do
      assert {:error, {:file_not_found, _}} = RouteLoader.load({:json, "nonexistent.json"})
    end

    test "error si JSON es inválido" do
      # Crear archivo temporal con JSON inválido
      path = Path.join(System.tmp_dir!(), "invalid_#{:rand.uniform(1000)}.json")
      File.write!(path, "not valid json {")

      on_exit(fn -> File.rm(path) end)

      assert {:error, {:json_decode_error, _}} = RouteLoader.load({:json, path})
    end

    test "error si falta _default" do
      path = Path.join(System.tmp_dir!(), "no_default_#{:rand.uniform(1000)}.json")
      File.write!(path, ~s({"CA": "flow_a"}))

      on_exit(fn -> File.rm(path) end)

      assert {:error, {:missing_default, _}} = RouteLoader.load({:json, path})
    end

    test "error si solo tiene _default" do
      path = Path.join(System.tmp_dir!(), "only_default_#{:rand.uniform(1000)}.json")
      File.write!(path, ~s({"_default": "fallback"}))

      on_exit(fn -> File.rm(path) end)

      assert {:error, {:empty_routes, _}} = RouteLoader.load({:json, path})
    end
  end

  describe "load/2 con config" do
    test "carga rutas desde Application config" do
      # Configurar temporalmente
      Application.put_env(:beamflow, :test_routes, %{
        "A" => "flow_a",
        "B" => "flow_b",
        :default => "default_flow"
      })

      on_exit(fn -> Application.delete_env(:beamflow, :test_routes) end)

      assert {:ok, routes} = RouteLoader.load({:config, :test_routes})
      assert routes[:default] == "default_flow"
      assert routes["A"] == "flow_a"
    end

    test "error si config no existe" do
      assert {:error, {:config_not_found, :nonexistent_key}} =
               RouteLoader.load({:config, :nonexistent_key})
    end
  end

  describe "load/2 con callback" do
    test "carga rutas desde función" do
      defmodule TestRouteProvider do
        def get_routes do
          %{"X" => "x_flow", :default => "fallback"}
        end
      end

      assert {:ok, routes} =
               RouteLoader.load({:callback, {TestRouteProvider, :get_routes, []}})

      assert routes[:default] == "fallback"
      assert routes["X"] == "x_flow"
    end

    test "maneja {:ok, routes} del callback" do
      defmodule TestRouteProvider2 do
        def get_routes do
          {:ok, %{"Y" => "y_flow", :default => "fallback"}}
        end
      end

      assert {:ok, routes} =
               RouteLoader.load({:callback, {TestRouteProvider2, :get_routes, []}})

      assert routes["Y"] == "y_flow"
    end

    test "propaga errores del callback" do
      defmodule TestRouteProvider3 do
        def get_routes do
          {:error, :database_unavailable}
        end
      end

      assert {:error, :database_unavailable} =
               RouteLoader.load({:callback, {TestRouteProvider3, :get_routes, []}})
    end
  end

  describe "cache" do
    test "load_and_cache guarda en ETS" do
      assert {:ok, _} =
               RouteLoader.load_and_cache(
                 "test_cache_key",
                 {:json, "priv/routes/example_states.json"}
               )

      assert {:ok, cached} = RouteLoader.get_cached("test_cache_key")
      assert cached[:default] == "generic_state_flow"
    end

    test "get_cached retorna :not_found si no existe" do
      assert {:error, :not_found} = RouteLoader.get_cached("nonexistent_cache_key")
    end

    test "invalidate elimina del cache" do
      RouteLoader.load_and_cache("to_invalidate", {:json, "priv/routes/example_states.json"})

      assert {:ok, _} = RouteLoader.get_cached("to_invalidate")

      RouteLoader.invalidate("to_invalidate")

      assert {:error, :not_found} = RouteLoader.get_cached("to_invalidate")
    end
  end

  describe "register y reload" do
    test "register carga y cachea rutas" do
      assert :ok =
               RouteLoader.register("registered_key",
                 source: {:json, "priv/routes/example_states.json"}
               )

      assert {:ok, routes} = RouteLoader.get_cached("registered_key")
      assert routes["CA"] == "california_flow"
    end

    test "reload recarga rutas registradas" do
      RouteLoader.register("reload_key",
        source: {:json, "priv/routes/example_states.json"}
      )

      assert {:ok, _} = RouteLoader.reload("reload_key")
    end

    test "reload falla si no está registrado" do
      assert {:error, :not_registered} = RouteLoader.reload("not_registered_key")
    end
  end
end
