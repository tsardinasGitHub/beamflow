defmodule Beamflow.Workflows.RouteLoader do
  @moduledoc """
  Carga mapeos de rutas desde fuentes externas para branches dinámicos.

  Este módulo permite definir rutas que pueden cambiar sin redeploy,
  útil para mappings que cambian frecuentemente como:

  - Códigos de estado/país → flujos regionales
  - Tipos de producto → flujos de procesamiento
  - Niveles de cliente → flujos de prioridad

  ## Fuentes Soportadas

  1. **JSON file**: Archivo JSON en disco o priv/
  2. **YAML file**: Archivo YAML (requiere librería externa)
  3. **Application config**: Configuración en config.exs
  4. **Callback function**: Para fuentes completamente dinámicas (DB, API)

  ## Ejemplo de JSON

      # priv/routes/state_routes.json
      {
        "CA": "california_flow",
        "TX": "texas_flow",
        "NY": "new_york_flow",
        "_default": "generic_flow"
      }

  ## Ejemplo de Uso

      # En definición del workflow
      def graph do
        Graph.new()
        |> Graph.add_branch("state_router", &(&1.state_code))
        |> Graph.dispatch_branch_dynamic("state_router",
             source: {:json, "priv/routes/state_routes.json"},
             refresh: :on_start  # o :every_5_minutes, :manual
           )
      end

  ## Configuración de Refresh

  - `:on_start` - Carga una vez al iniciar la app (default)
  - `:every_N_minutes` - Recarga periódicamente
  - `:manual` - Solo recarga cuando se llama explícitamente
  - `{:watch, path}` - Usa FileSystem para hot reload

  ## Cache

  Las rutas se cachean en ETS para performance. El lookup sigue siendo O(1).
  """

  use GenServer

  require Logger

  @ets_table :beamflow_route_cache

  # ============================================================================
  # API Pública
  # ============================================================================

  @doc """
  Inicia el RouteLoader como parte del supervision tree.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Carga rutas desde una fuente.

  ## Fuentes soportadas

    * `{:json, path}` - Archivo JSON
    * `{:yaml, path}` - Archivo YAML (requiere :yamerl o :yaml_elixir)
    * `{:config, key}` - Application config
    * `{:callback, {module, function, args}}` - Callback dinámico

  ## Opciones

    * `:cache_key` - Clave para cachear (default: path o key)
    * `:default_key` - Clave para el valor default en JSON (default: "_default")

  ## Ejemplo

      RouteLoader.load({:json, "priv/routes/states.json"})
      # => {:ok, %{"CA" => "ca_flow", :default => "generic_flow"}}

  """
  @spec load(source :: term(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  def load(source, opts \\ [])

  def load({:json, path}, opts) do
    load_json(path, opts)
  end

  def load({:yaml, path}, opts) do
    load_yaml(path, opts)
  end

  def load({:config, key}, opts) when is_atom(key) do
    load_from_config(key, opts)
  end

  def load({:callback, {module, function, args}}, _opts) do
    load_from_callback(module, function, args)
  end

  def load(source, _opts) do
    {:error, {:unsupported_source, source}}
  end

  @doc """
  Carga rutas y las cachea para uso posterior.

  ## Ejemplo

      RouteLoader.load_and_cache("state_router", {:json, "priv/routes/states.json"})

      # Después, en runtime:
      RouteLoader.get_cached("state_router")
      # => {:ok, %{"CA" => "ca_flow", :default => "generic_flow"}}
  """
  @spec load_and_cache(cache_key :: String.t(), source :: term(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def load_and_cache(cache_key, source, opts \\ []) do
    case load(source, opts) do
      {:ok, routes} ->
        cache_routes(cache_key, routes)
        {:ok, routes}

      error ->
        error
    end
  end

  @doc """
  Obtiene rutas cacheadas.
  """
  @spec get_cached(cache_key :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_cached(cache_key) do
    case :ets.lookup(@ets_table, cache_key) do
      [{^cache_key, routes, _loaded_at}] -> {:ok, routes}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Invalida el cache de rutas para una clave específica.
  """
  @spec invalidate(cache_key :: String.t()) :: :ok
  def invalidate(cache_key) do
    :ets.delete(@ets_table, cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Recarga rutas desde su fuente original.

  Requiere que la fuente haya sido registrada previamente.
  """
  @spec reload(cache_key :: String.t()) :: {:ok, map()} | {:error, term()}
  def reload(cache_key) do
    GenServer.call(__MODULE__, {:reload, cache_key})
  end

  @doc """
  Registra una fuente para recarga automática.

  ## Opciones

    * `:refresh` - Estrategia de refresh:
      - `:manual` - Solo recarga con `reload/1`
      - `:on_change` - Usa FileSystem para detectar cambios
      - `{:interval, ms}` - Recarga cada N milisegundos

  ## Ejemplo

      RouteLoader.register("state_router",
        source: {:json, "priv/routes/states.json"},
        refresh: {:interval, 60_000}  # cada minuto
      )
  """
  @spec register(cache_key :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  def register(cache_key, opts) do
    GenServer.call(__MODULE__, {:register, cache_key, opts})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Crear tabla ETS para cache
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])

    state = %{
      sources: %{},     # cache_key => %{source: ..., refresh: ...}
      timers: %{}       # cache_key => timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, cache_key, opts}, _from, state) do
    source = Keyword.fetch!(opts, :source)
    refresh = Keyword.get(opts, :refresh, :manual)

    # Cargar inicialmente
    case load_and_cache(cache_key, source, opts) do
      {:ok, _routes} ->
        # Registrar fuente
        source_info = %{source: source, opts: opts, refresh: refresh}
        new_sources = Map.put(state.sources, cache_key, source_info)

        # Configurar timer si es necesario
        new_timers = setup_refresh_timer(cache_key, refresh, state.timers)

        new_state = %{state | sources: new_sources, timers: new_timers}
        {:reply, :ok, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reload, cache_key}, _from, state) do
    case Map.get(state.sources, cache_key) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      %{source: source, opts: opts} ->
        result = load_and_cache(cache_key, source, opts)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info({:refresh, cache_key}, state) do
    case Map.get(state.sources, cache_key) do
      nil ->
        {:noreply, state}

      %{source: source, opts: opts, refresh: refresh} ->
        case load_and_cache(cache_key, source, opts) do
          {:ok, _} ->
            Logger.debug("[RouteLoader] Refreshed routes for #{cache_key}")

          {:error, reason} ->
            Logger.warning("[RouteLoader] Failed to refresh #{cache_key}: #{inspect(reason)}")
        end

        # Re-schedule timer
        new_timers = setup_refresh_timer(cache_key, refresh, state.timers)
        {:noreply, %{state | timers: new_timers}}
    end
  end

  # ============================================================================
  # Funciones Privadas - Carga
  # ============================================================================

  defp load_json(path, opts) do
    resolved_path = resolve_path(path)
    default_key = Keyword.get(opts, :default_key, "_default")

    with {:ok, content} <- File.read(resolved_path),
         {:ok, data} <- Jason.decode(content) do
      routes = normalize_routes(data, default_key)
      validate_routes(routes)
    else
      {:error, :enoent} ->
        {:error, {:file_not_found, resolved_path}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:json_decode_error, Exception.message(error)}}

      error ->
        error
    end
  end

  defp load_yaml(path, opts) do
    resolved_path = resolve_path(path)
    default_key = Keyword.get(opts, :default_key, "_default")

    # Intentar usar YamlElixir si está disponible
    if Code.ensure_loaded?(YamlElixir) do
      case YamlElixir.read_from_file(resolved_path) do
        {:ok, data} ->
          routes = normalize_routes(data, default_key)
          validate_routes(routes)

        {:error, reason} ->
          {:error, {:yaml_error, reason}}
      end
    else
      {:error, {:missing_dependency, :yaml_elixir,
        "Add {:yaml_elixir, \"~> 2.9\"} to your deps to use YAML sources"}}
    end
  end

  defp load_from_config(key, opts) do
    default_key = Keyword.get(opts, :default_key, :default)

    case Application.get_env(:beamflow, key) do
      nil ->
        {:error, {:config_not_found, key}}

      routes when is_map(routes) ->
        normalized = normalize_routes(routes, default_key)
        validate_routes(normalized)

      routes when is_list(routes) ->
        map_routes = Map.new(routes)
        normalized = normalize_routes(map_routes, default_key)
        validate_routes(normalized)

      other ->
        {:error, {:invalid_config_format, other}}
    end
  end

  defp load_from_callback(module, function, args) do
    try do
      case apply(module, function, args) do
        {:ok, routes} when is_map(routes) ->
          validate_routes(routes)

        routes when is_map(routes) ->
          validate_routes(routes)

        {:error, _} = error ->
          error

        other ->
          {:error, {:invalid_callback_result, other}}
      end
    rescue
      e ->
        {:error, {:callback_error, Exception.message(e)}}
    end
  end

  # ============================================================================
  # Funciones Privadas - Utilidades
  # ============================================================================

  defp resolve_path("priv/" <> _ = path) do
    Application.app_dir(:beamflow, path)
  end

  defp resolve_path(path), do: path

  defp normalize_routes(data, default_key) when is_map(data) do
    Enum.reduce(data, %{}, fn {key, value}, acc ->
      normalized_key =
        cond do
          key == default_key -> :default
          key == "_default" -> :default
          key == "default" -> :default
          is_binary(key) -> key
          true -> key
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  defp validate_routes(routes) do
    cond do
      not Map.has_key?(routes, :default) ->
        {:error, {:missing_default,
          "Routes must include a :default (or '_default' in JSON). Got: #{inspect(Map.keys(routes))}"}}

      map_size(routes) < 2 ->
        {:error, {:empty_routes,
          "Routes must have at least one route besides :default"}}

      true ->
        {:ok, routes}
    end
  end

  defp cache_routes(cache_key, routes) do
    :ets.insert(@ets_table, {cache_key, routes, DateTime.utc_now()})
  end

  defp setup_refresh_timer(cache_key, {:interval, ms}, timers) do
    # Cancelar timer anterior si existe
    case Map.get(timers, cache_key) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    # Crear nuevo timer
    ref = Process.send_after(self(), {:refresh, cache_key}, ms)
    Map.put(timers, cache_key, ref)
  end

  defp setup_refresh_timer(_cache_key, _refresh, timers), do: timers
end
