defmodule Beamflow.Workflows.Graph do
  @moduledoc """
  Representa un workflow como un grafo dirigido con soporte para branching.

  Este módulo permite definir workflows no lineales con:
  - **Secuencias**: Steps que van uno tras otro
  - **Branches**: Bifurcaciones condicionales basadas en el estado
  - **Joins**: Puntos de convergencia después de branches

  ## Estructura del Grafo

  Un grafo de workflow se representa como:

  ```elixir
  %Graph{
    nodes: %{
      "validate" => %Node{id: "validate", module: ValidateIdentity, type: :step},
      "decision" => %Node{id: "decision", type: :branch, condition: &(&1.approved)},
      ...
    },
    edges: %{
      "validate" => ["check_credit"],
      "decision" => [{"approved_path", true}, {"rejected_path", false}],
      ...
    },
    start_node: "validate",
    end_nodes: ["close_case"]
  }
  ```

  ## Compatibilidad con Workflows Lineales

  Los workflows que definen `steps/0` como lista simple se convierten
  automáticamente a un grafo lineal:

  ```elixir
  [Step1, Step2, Step3]
  # Se convierte a:
  # Step1 → Step2 → Step3
  ```

  Ver ADR-005 para la justificación de este diseño.
  """

  alias __MODULE__

  defstruct nodes: %{},
            edges: %{},
            start_node: nil,
            end_nodes: []

  @type node_id :: String.t()
  @type condition :: (map() -> boolean())

  @type graph_node :: %{
          id: node_id(),
          module: module() | nil,
          type: :step | :branch | :join | :start | :end,
          condition: condition() | nil,
          label: String.t() | nil
        }

  @type edge :: node_id() | {node_id(), boolean() | atom()}

  @type t :: %Graph{
          nodes: %{node_id() => graph_node()},
          edges: %{node_id() => [edge()]},
          start_node: node_id() | nil,
          end_nodes: [node_id()]
        }

  # ============================================================================
  # Constantes de Validación
  # ============================================================================

  # Umbral por defecto para considerar un branch como "complejo" (configurable)
  @default_max_branch_options 5

  # Umbral FIJO para escalar a error cuando un branch no tiene default.
  # Esta es una "regla de oro" de seguridad que NO es configurable.
  #
  # Justificación:
  # - Con 5+ opciones sin default, la probabilidad de olvidar un caso es alta
  # - Estudios de code review muestran que humanos detectan ~60% de bugs en
  #   switch/case con >4 ramas (McConnell, Code Complete)
  # - Forzar default reduce defectos en producción significativamente
  #
  # Si tu dominio requiere branches grandes sin default, considera:
  # 1. Usar una lookup table (Map) en lugar de branches
  # 2. Refactorizar a sub-workflows
  # 3. Agregar un :default path que loguee casos inesperados
  @error_threshold_no_default 5

  # ============================================================================
  # Construcción del Grafo
  # ============================================================================

  @doc """
  Crea un grafo vacío.
  """
  @spec new() :: t()
  def new do
    %Graph{}
  end

  @doc """
  Convierte una lista lineal de steps a un grafo.

  Mantiene retrocompatibilidad con workflows que usan `steps/0` como lista.

  ## Ejemplo

      iex> Graph.from_linear_steps([Step1, Step2, Step3])
      %Graph{
        nodes: %{
          "step_0" => %{id: "step_0", module: Step1, type: :step},
          "step_1" => %{id: "step_1", module: Step2, type: :step},
          "step_2" => %{id: "step_2", module: Step3, type: :step}
        },
        edges: %{
          "step_0" => ["step_1"],
          "step_1" => ["step_2"]
        },
        start_node: "step_0",
        end_nodes: ["step_2"]
      }
  """
  @spec from_linear_steps([module()]) :: t()
  def from_linear_steps([]), do: new()

  def from_linear_steps(steps) when is_list(steps) do
    nodes =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {module, idx} ->
        id = "step_#{idx}"
        {id, %{id: id, module: module, type: :step, condition: nil, label: inspect(module)}}
      end)
      |> Map.new()

    edges =
      steps
      |> Enum.with_index()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{_mod1, idx1}, {_mod2, idx2}] ->
        {"step_#{idx1}", ["step_#{idx2}"]}
      end)
      |> Map.new()

    last_idx = length(steps) - 1

    %Graph{
      nodes: nodes,
      edges: edges,
      start_node: "step_0",
      end_nodes: ["step_#{last_idx}"]
    }
  end

  @doc """
  Agrega un nodo step al grafo.
  """
  @spec add_step(t(), node_id(), module(), keyword()) :: t()
  def add_step(graph, id, module, opts \\ []) do
    node = %{
      id: id,
      module: module,
      type: :step,
      condition: nil,
      label: Keyword.get(opts, :label, inspect(module))
    }

    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  @doc """
  Agrega un nodo branch (bifurcación condicional) al grafo.

  > #### Deprecation Warning {: .warning}
  >
  > Considera usar `safe_branch/4` o `dispatch_branch/3` en su lugar.
  > Estos garantizan `:default` path en compile-time.
  """
  @spec add_branch(t(), node_id(), condition(), keyword()) :: t()
  def add_branch(graph, id, condition, opts \\ []) do
    node = %{
      id: id,
      module: nil,
      type: :branch,
      condition: condition,
      label: Keyword.get(opts, :label, "branch:#{id}")
    }

    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  @doc """
  Agrega un branch seguro que requiere definir todas las rutas incluyendo `:default`.

  A diferencia de `add_branch/4`, esta función toma las rutas en la misma llamada
  y **falla en compile-time** si no incluye `:default`.

  ## Parámetros

    * `graph` - El grafo
    * `id` - ID único del nodo branch
    * `condition` - Función que evalúa el estado y retorna el valor a matchear
    * `routes` - Map de `valor => node_id`. **Debe incluir `:default`**

  ## Ejemplo

      graph
      |> Graph.add_step("start", StartStep)
      |> Graph.safe_branch("decision", &(&1.status), %{
        :approved => "approve_flow",
        :rejected => "reject_flow",
        :default => "review_flow"  # OBLIGATORIO
      })
      |> Graph.add_step("approve_flow", ApproveStep)
      |> Graph.add_step("reject_flow", RejectStep)
      |> Graph.add_step("review_flow", ReviewStep)

  ## vs `add_branch` + `connect_branch`

  | Aspecto | `add_branch` | `safe_branch` |
  |---------|--------------|---------------|
  | `:default` | Opcional (runtime warning/error) | Obligatorio (compile-time) |
  | Definición | Separada de rutas | Todo junto |
  | Seguridad | Depende de validación | Garantizada |

  ## Errores

    * Lanza `ArgumentError` si falta `:default`
    * Lanza `ArgumentError` si `routes` está vacío
  """
  @spec safe_branch(t(), node_id(), condition(), %{required(:default) => node_id(), optional(any()) => node_id()}) :: t()
  def safe_branch(graph, id, condition, routes) when is_map(routes) do
    # Validar que :default existe
    unless Map.has_key?(routes, :default) do
      raise ArgumentError, """
      safe_branch requires a :default key.

      Got routes: #{inspect(Map.keys(routes))}

      Add a :default route:
        %{
          :approved => "approve_flow",
          :rejected => "reject_flow",
          :default => "fallback_flow"  # <- Required
        }
      """
    end

    # Validar que hay al menos una ruta además de :default
    if map_size(routes) < 2 do
      raise ArgumentError, """
      safe_branch requires at least one route besides :default.

      If you only have a default, use Graph.connect/3 instead.
      """
    end

    # Crear el nodo branch marcado como safe
    node = %{
      id: id,
      module: nil,
      type: :branch,
      condition: condition,
      label: "safe_branch:#{id}",
      safe: true,
      dispatch: true  # También excluir del complexity check
    }

    graph = %{graph | nodes: Map.put(graph.nodes, id, node)}

    # Crear edges para cada ruta
    Enum.reduce(routes, graph, fn {condition_value, target_id}, acc ->
      connect_branch(acc, id, target_id, condition_value)
    end)
  end

  @doc """
  Agrega un nodo join (convergencia) al grafo.
  """
  @spec add_join(t(), node_id(), keyword()) :: t()
  def add_join(graph, id, opts \\ []) do
    node = %{
      id: id,
      module: nil,
      type: :join,
      condition: nil,
      label: Keyword.get(opts, :label, "join:#{id}")
    }

    %{graph | nodes: Map.put(graph.nodes, id, node)}
  end

  @doc """
  Conecta dos nodos con una arista.
  """
  @spec connect(t(), node_id(), node_id()) :: t()
  def connect(graph, from_id, to_id) do
    edges = Map.update(graph.edges, from_id, [to_id], &[to_id | &1])
    %{graph | edges: edges}
  end

  @doc """
  Conecta un nodo branch a un destino con una condición.

  ## Parámetros

    * `condition_result` - El valor que debe retornar la función de condición
      para tomar este path. Usar `:default` para el path por defecto.

  ## Ejemplo

      graph
      |> Graph.connect_branch("decision", "path_a", :approved)
      |> Graph.connect_branch("decision", "path_b", :rejected)
      |> Graph.connect_branch("decision", "path_fallback", :default)  # Default path
  """
  @spec connect_branch(t(), node_id(), node_id(), boolean() | atom()) :: t()
  def connect_branch(graph, from_id, to_id, condition_result) do
    edge = {to_id, condition_result}
    edges = Map.update(graph.edges, from_id, [edge], &[edge | &1])
    %{graph | edges: edges}
  end

  @doc """
  Crea un branch con dispatch basado en lookup table.

  Ideal para branches con muchas opciones (ej: estados, países, códigos).
  El `:default` key es **obligatorio** - falla en compile-time si falta.

  ## Ventajas sobre múltiples `connect_branch`

    * **Escalable**: Un Map en lugar de N edges
    * **Seguro**: `:default` obligatorio garantiza que siempre hay salida
    * **Performante**: Lookup O(1)
    * **Bypasses complexity check**: No cuenta como N opciones separadas

  ## Parámetros

    * `graph` - El grafo
    * `from_id` - ID del nodo branch origen
    * `routes` - Map de `condición => node_id`. Debe incluir `:default`

  ## Ejemplo

      # En lugar de 50 connect_branch:
      graph
      |> Graph.add_branch("state_router", &(&1.state_code))
      |> Graph.dispatch_branch("state_router", %{
        "CA" => "california_flow",
        "TX" => "texas_flow",
        "NY" => "new_york_flow",
        # ... más estados
        :default => "generic_state_flow"  # OBLIGATORIO
      })

  ## Errores

    * Lanza `ArgumentError` si falta `:default`
    * Lanza `ArgumentError` si `routes` está vacío
  """
  @spec dispatch_branch(t(), node_id(), %{required(:default) => node_id(), optional(any()) => node_id()}) :: t()
  def dispatch_branch(graph, from_id, routes) when is_map(routes) do
    # Validar que :default existe
    unless Map.has_key?(routes, :default) do
      raise ArgumentError, """
      dispatch_branch requires a :default key.

      Got routes: #{inspect(Map.keys(routes))}

      Add a :default route:
        %{
          "CA" => "california_flow",
          :default => "fallback_flow"  # <- Required
        }
      """
    end

    # Validar que no está vacío (solo :default no cuenta)
    if map_size(routes) < 2 do
      raise ArgumentError, """
      dispatch_branch requires at least one route besides :default.

      Got only: #{inspect(Map.keys(routes))}
      """
    end

    # Marcar el nodo como dispatch (para que validate lo trate diferente)
    graph = mark_as_dispatch(graph, from_id)

    # Crear edges para cada ruta
    Enum.reduce(routes, graph, fn {condition, target_id}, acc ->
      connect_branch(acc, from_id, target_id, condition)
    end)
  end

  defp mark_as_dispatch(graph, node_id) do
    case Map.get(graph.nodes, node_id) do
      nil ->
        graph
      node ->
        updated_node = Map.put(node, :dispatch, true)
        %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}
    end
  end

  @doc """
  Crea un branch con dispatch dinámico cargado desde fuente externa.

  Similar a `dispatch_branch/3` pero las rutas se cargan desde JSON, YAML,
  configuración o un callback. Ideal para mappings que cambian sin redeploy.

  ## Fuentes Soportadas

    * `{:json, path}` - Archivo JSON (ej: "priv/routes/states.json")
    * `{:yaml, path}` - Archivo YAML (requiere yaml_elixir)
    * `{:config, key}` - Application.get_env(:beamflow, key)
    * `{:callback, {module, function, args}}` - Función dinámica

  ## Opciones

    * `:cache_key` - Clave para cachear (default: from_id)
    * `:refresh` - Estrategia de recarga:
      - `:manual` - Solo con RouteLoader.reload/1 (default)
      - `{:interval, ms}` - Recarga cada N milisegundos
    * `:default_key` - Clave del default en JSON (default: "_default")

  ## Formato JSON

      {
        "CA": "california_flow",
        "TX": "texas_flow",
        "_default": "generic_flow"
      }

  ## Ejemplo

      graph
      |> Graph.add_branch("state_router", &(&1.state_code))
      |> Graph.dispatch_branch_dynamic("state_router",
           {:json, "priv/routes/states.json"},
           refresh: {:interval, 60_000}  # Recarga cada minuto
         )

  ## Nota

  Las rutas se cargan al definir el grafo. Para hot-reload en runtime,
  usa `RouteLoader.reload/1` o configura `:refresh`.
  """
  @spec dispatch_branch_dynamic(t(), node_id(), source :: term(), opts :: keyword()) :: t()
  def dispatch_branch_dynamic(graph, from_id, source, opts \\ []) do
    alias Beamflow.Workflows.RouteLoader

    cache_key = Keyword.get(opts, :cache_key, from_id)

    # Cargar rutas desde la fuente
    case RouteLoader.load(source, opts) do
      {:ok, routes} ->
        # Registrar para posible recarga
        if Keyword.has_key?(opts, :refresh) do
          # Solo registrar si RouteLoader está corriendo
          if Process.whereis(RouteLoader) do
            RouteLoader.register(cache_key, Keyword.put(opts, :source, source))
          end
        end

        # Cachear para uso en runtime
        RouteLoader.load_and_cache(cache_key, source, opts)

        # Usar dispatch_branch normal con las rutas cargadas
        dispatch_branch(graph, from_id, routes)

      {:error, reason} ->
        raise ArgumentError, """
        Failed to load routes for dispatch_branch_dynamic.

        Source: #{inspect(source)}
        Error: #{inspect(reason)}

        Make sure the source file exists and has valid format:
        - JSON: {"CA": "flow_a", "_default": "fallback"}
        - Config: config :beamflow, :my_routes, %{"CA" => "flow_a", :default => "fallback"}
        """
    end
  end

  @doc """
  Establece el nodo inicial del grafo.
  """
  @spec set_start(t(), node_id()) :: t()
  def set_start(graph, node_id) do
    %{graph | start_node: node_id}
  end

  @doc """
  Marca un nodo como nodo final.
  """
  @spec set_end(t(), node_id()) :: t()
  def set_end(graph, node_id) do
    %{graph | end_nodes: [node_id | graph.end_nodes] |> Enum.uniq()}
  end

  # ============================================================================
  # Navegación del Grafo
  # ============================================================================

  @doc """
  Obtiene el siguiente nodo(s) a ejecutar dado el nodo actual y el estado.

  Para nodos step: retorna el siguiente nodo en la secuencia.
  Para nodos branch: evalúa la condición y retorna el path correcto.
  Para nodos join: retorna el siguiente nodo (convergencia).

  ## Manejo de Branches

  Cuando se evalúa un nodo branch:
  1. Se ejecuta la función de condición con el estado actual
  2. Se busca un edge que coincida con el resultado
  3. Si no hay coincidencia, se busca un edge con `:default`
  4. Si no hay default, retorna `{:error, :no_matching_branch}`

  ## Retorno

    * `{:ok, [node_id()]}` - Lista de siguientes nodos
    * `{:error, :no_matching_branch}` - Ninguna condición de branch coincidió
  """
  @spec next_nodes(t(), node_id(), map()) :: {:ok, [node_id()]} | {:error, :no_matching_branch}
  def next_nodes(graph, current_node_id, workflow_state) do
    node = Map.get(graph.nodes, current_node_id)
    edges = Map.get(graph.edges, current_node_id, [])

    case node.type do
      :step ->
        # Step normal: siguiente nodo en secuencia
        {:ok, Enum.filter(edges, &is_binary/1)}

      :branch ->
        # Branch: evaluar condición y seguir el path correcto
        evaluate_branch(node, edges, workflow_state)

      :join ->
        # Join: simplemente continuar al siguiente
        {:ok, Enum.filter(edges, &is_binary/1)}

      _ ->
        {:ok, []}
    end
  end

  # Evalúa un branch y retorna el siguiente nodo o error
  defp evaluate_branch(node, edges, workflow_state) do
    condition_result = node.condition.(workflow_state)

    # Buscar edge que coincida con el resultado de la condición
    matching_edges =
      edges
      |> Enum.filter(fn
        {_target, result} -> result == condition_result
        _ -> false
      end)
      |> Enum.map(fn {target, _} -> target end)

    cond do
      # Encontramos coincidencia exacta
      matching_edges != [] ->
        {:ok, matching_edges}

      # No hay coincidencia, buscar default
      true ->
        default_edges =
          edges
          |> Enum.filter(fn
            {_target, :default} -> true
            _ -> false
          end)
          |> Enum.map(fn {target, _} -> target end)

        if default_edges != [] do
          {:ok, default_edges}
        else
          # Fail-fast: ninguna condición coincidió y no hay default
          {:error, :no_matching_branch}
        end
    end
  end

  @doc """
  Obtiene un nodo por su ID.
  """
  @spec get_node(t(), node_id()) :: graph_node() | nil
  def get_node(graph, node_id) do
    Map.get(graph.nodes, node_id)
  end

  @doc """
  Verifica si un nodo es terminal (fin del workflow).
  """
  @spec is_end_node?(t(), node_id()) :: boolean()
  def is_end_node?(graph, node_id) do
    node_id in graph.end_nodes or Map.get(graph.edges, node_id, []) == []
  end

  @doc """
  Retorna la lista de todos los nodos step (módulos a ejecutar).
  """
  @spec step_modules(t()) :: [module()]
  def step_modules(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :step))
    |> Enum.map(& &1.module)
  end

  @doc """
  Cuenta el número total de steps ejecutables.
  """
  @spec count_steps(t()) :: non_neg_integer()
  def count_steps(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.count(&(&1.type == :step))
  end

  # ============================================================================
  # Validación Estática del Grafo
  # ============================================================================

  @typedoc """
  Representa un issue encontrado durante la validación.

  - `:error` - Problema crítico que impedirá la ejecución
  - `:warning` - Problema potencial que podría causar fallos
  - `:info` - Sugerencia de mejora
  """
  @type validation_issue :: %{
          severity: :error | :warning | :info,
          code: atom(),
          message: String.t(),
          context: map()
        }

  @doc """
  Valida la estructura del grafo y retorna una lista de issues.

  Esta función realiza validación estática para detectar problemas
  de diseño antes de que el workflow se ejecute.

  ## Validaciones Realizadas

  | Código | Severidad | Descripción |
  |--------|-----------|-------------|
  | `:no_start_node` | error | No hay nodo inicial definido |
  | `:start_node_not_found` | error | El nodo inicial no existe |
  | `:no_end_nodes` | warning | No hay nodos finales definidos |
  | `:unreachable_nodes` | warning | Nodos sin edges entrantes |
  | `:branch_without_default` | warning | Branch sin path default |
  | `:empty_graph` | info | Grafo sin nodos |
  | `:orphan_edges` | warning | Edges a nodos inexistentes |

  ## Ejemplo

      iex> Graph.validate(my_graph)
      {:ok, []}  # Sin problemas

      iex> Graph.validate(incomplete_graph)
      {:error, [
        %{severity: :error, code: :no_start_node, message: "...", context: %{}},
        %{severity: :warning, code: :branch_without_default, ...}
      ]}

  ## Retorno

    * `{:ok, []}` - Grafo válido sin issues
    * `{:ok, warnings}` - Grafo válido con warnings/info
    * `{:error, issues}` - Grafo inválido (contiene errores)

  ## Opciones

    * `:max_branch_options` - Umbral para considerar un branch como complejo (default: 5)
    * `:strict_mode` - Si es `true`, reduce umbrales a 3 para equipos que quieren máxima seguridad

      Se puede configurar globalmente en `config/config.exs`:
      ```elixir
      config :beamflow, :validation,
        max_branch_options: 5,
        strict_mode: false
      ```

  ## Nota sobre `error_threshold_no_default`

  El umbral para escalar a error cuando un branch no tiene default (5) es **fijo y no configurable**.
  Esta es una decisión de diseño intencional basada en estudios de code review que muestran
  que la detección humana de casos faltantes decrece significativamente con >4 ramas.
  Ver ADR-006 para más detalles.

  Si necesitas branches grandes sin default, considera usar lookup tables o sub-workflows.

  ## Modos de Validación

  | Modo | `max_branch_options` | `error_threshold_no_default` | Caso de uso |
  |------|---------------------|------------------------------|-------------|
  | Normal | 5 | 5 | Desarrollo día a día |
  | Strict | 3 | 3 | Proyectos de alta confiabilidad |
  | Paranoid | 2 | 2 | Sistemas críticos (financiero, salud) |
  | Pedantic | 1 | 1 | Zero tolerance - todo branch requiere default |

  > #### Tip: safe_branch {: .tip}
  >
  > En lugar de usar `pedantic_mode`, considera usar `safe_branch/4` o `dispatch_branch/3`
  > que garantizan `:default` en compile-time sin necesidad de modos de validación.

  """
  @spec validate(t(), keyword()) :: {:ok, [validation_issue()]} | {:error, [validation_issue()]}
  def validate(graph, opts \\ []) do
    pedantic_mode = opts[:pedantic_mode] || get_config(:pedantic_mode) || false
    paranoid_mode = opts[:paranoid_mode] || get_config(:paranoid_mode) || false
    strict_mode = opts[:strict_mode] || get_config(:strict_mode) || false

    # Determinar umbrales según modo (orden de precedencia: pedantic > paranoid > strict > normal)
    # pedantic_mode: cualquier branch sin default es error
    # paranoid_mode: branch binario sin default es error
    # strict_mode: 3+ opciones sin default es error
    {default_max, error_threshold} =
      cond do
        pedantic_mode -> {1, 1}
        paranoid_mode -> {2, 2}
        strict_mode -> {3, 3}
        true -> {@default_max_branch_options, @error_threshold_no_default}
      end

    max_branch_options =
      opts[:max_branch_options] ||
        get_config(:max_branch_options) ||
        default_max

    validation_opts = %{
      max_branch_options: max_branch_options,
      error_threshold_no_default: error_threshold,
      strict_mode: strict_mode,
      paranoid_mode: paranoid_mode,
      pedantic_mode: pedantic_mode
    }

    issues =
      []
      |> validate_not_empty(graph)
      |> validate_start_node(graph)
      |> validate_end_nodes(graph)
      |> validate_branch_safety(graph, validation_opts)
      |> validate_reachability(graph)
      |> validate_edges_target_existing_nodes(graph)
      |> Enum.reverse()

    has_errors = Enum.any?(issues, &(&1.severity == :error))

    if has_errors do
      {:error, issues}
    else
      {:ok, issues}
    end
  end

  defp get_config(key) do
    Application.get_env(:beamflow, :validation, [])
    |> Keyword.get(key)
  end

  @doc """
  Valida el grafo y lanza excepción si hay errores.

  Útil para validar durante la compilación o startup.

  ## Ejemplo

      # En un módulo de workflow
      def graph do
        Graph.new()
        |> Graph.add_step(...)
        |> Graph.validate!()  # Lanza si hay errores
      end
  """
  @spec validate!(t(), keyword()) :: t()
  def validate!(graph, opts \\ []) do
    case validate(graph, opts) do
      {:ok, warnings} ->
        # Log warnings si hay
        Enum.each(warnings, fn issue ->
          if issue.severity == :warning do
            require Logger
            Logger.warning("[Graph] #{issue.message}")
          end
        end)

        graph

      {:error, issues} ->
        error_messages =
          issues
          |> Enum.filter(&(&1.severity == :error))
          |> Enum.map(& &1.message)
          |> Enum.join("\n  - ")

        raise ArgumentError, """
        Invalid workflow graph:
          - #{error_messages}
        """
    end
  end

  # ---------------------------------------------------------------------------
  # Validaciones Individuales
  # ---------------------------------------------------------------------------

  defp validate_not_empty(issues, graph) do
    if map_size(graph.nodes) == 0 do
      [build_issue(:info, :empty_graph, "Graph has no nodes defined", %{}) | issues]
    else
      issues
    end
  end

  defp validate_start_node(issues, graph) do
    cond do
      is_nil(graph.start_node) ->
        [build_issue(:error, :no_start_node, "No start node defined. Use Graph.set_start/2", %{}) | issues]

      not Map.has_key?(graph.nodes, graph.start_node) ->
        [
          build_issue(
            :error,
            :start_node_not_found,
            "Start node '#{graph.start_node}' does not exist in the graph",
            %{start_node: graph.start_node}
          )
          | issues
        ]

      true ->
        issues
    end
  end

  defp validate_end_nodes(issues, graph) do
    if graph.end_nodes == [] do
      # Detectar nodos terminales implícitos (sin edges salientes)
      implicit_ends =
        graph.nodes
        |> Map.keys()
        |> Enum.filter(fn node_id ->
          edges = Map.get(graph.edges, node_id, [])
          edges == []
        end)

      if implicit_ends == [] and map_size(graph.nodes) > 0 do
        [
          build_issue(
            :warning,
            :no_end_nodes,
            "No end nodes defined and no implicit terminal nodes found. This may cause infinite loops.",
            %{}
          )
          | issues
        ]
      else
        issues
      end
    else
      issues
    end
  end

  @doc false
  # Validación unificada de branches: severidad escalada según opciones y presencia de default
  #
  # | Opciones        | Default? | Severidad | Código                       |
  # |-----------------|----------|-----------|------------------------------|
  # | < threshold     | No       | Warning   | :branch_without_default      |
  # | >= threshold    | No       | Error     | :branch_missing_default      |
  # | > max_options   | Sí       | Warning   | :complex_branch              |
  # | <= max_options  | Sí       | OK        | (sin issue)                  |
  #
  # NOTA: Nodos con :dispatch => true (creados via dispatch_branch) se excluyen
  # del complexity check porque ya garantizan :default en compile-time.
  defp validate_branch_safety(issues, graph, opts) do
    max_options = opts.max_branch_options
    error_threshold = opts.error_threshold_no_default

    graph.nodes
    |> Enum.filter(fn {_id, node} -> node.type == :branch end)
    |> Enum.filter(fn {_id, node} -> not Map.get(node, :dispatch, false) end)  # Excluir dispatch
    |> Enum.reduce(issues, fn {node_id, _node}, acc ->
      edges = Map.get(graph.edges, node_id, [])
      option_count = length(edges)

      has_default =
        Enum.any?(edges, fn
          {_target, :default} -> true
          _ -> false
        end)

      cond do
        # Sin default y muchas opciones → Error (muy riesgoso)
        not has_default and option_count >= error_threshold ->
          [
            build_issue(
              :error,
              :branch_missing_default,
              "Branch '#{node_id}' has #{option_count} options but no default path. " <>
                "With #{error_threshold}+ options, a default is required.",
              %{branch_id: node_id, option_count: option_count, has_default: false}
            )
            | acc
          ]

        # Sin default pero pocas opciones → Warning
        not has_default ->
          [
            build_issue(
              :warning,
              :branch_without_default,
              "Branch '#{node_id}' has no default path. If no condition matches, the workflow will fail.",
              %{branch_id: node_id, option_count: option_count, has_default: false}
            )
            | acc
          ]

        # Con default pero demasiadas opciones → Warning de complejidad
        has_default and option_count > max_options ->
          [
            build_issue(
              :warning,
              :complex_branch,
              "Branch '#{node_id}' has #{option_count} options (>#{max_options}). " <>
                "Consider refactoring into a lookup table or sub-workflows for maintainability.",
              %{branch_id: node_id, option_count: option_count, has_default: true}
            )
            | acc
          ]

        # Con default y opciones razonables → OK
        true ->
          acc
      end
    end)
  end

  defp validate_reachability(issues, graph) do
    if is_nil(graph.start_node) or map_size(graph.nodes) == 0 do
      issues
    else
      reachable = find_reachable_nodes(graph, graph.start_node, MapSet.new())

      unreachable =
        graph.nodes
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(reachable, &1))

      if unreachable != [] do
        [
          build_issue(
            :warning,
            :unreachable_nodes,
            "The following nodes are unreachable from start: #{Enum.join(unreachable, ", ")}",
            %{unreachable_nodes: unreachable}
          )
          | issues
        ]
      else
        issues
      end
    end
  end

  defp validate_edges_target_existing_nodes(issues, graph) do
    orphan_edges =
      graph.edges
      |> Enum.flat_map(fn {from_id, edges} ->
        edges
        |> Enum.map(fn
          {target, _condition} -> target
          target when is_binary(target) -> target
        end)
        |> Enum.reject(&Map.has_key?(graph.nodes, &1))
        |> Enum.map(&{from_id, &1})
      end)

    if orphan_edges != [] do
      edge_descriptions =
        orphan_edges
        |> Enum.map(fn {from, to} -> "#{from} -> #{to}" end)
        |> Enum.join(", ")

      [
        build_issue(
          :warning,
          :orphan_edges,
          "Edges point to non-existent nodes: #{edge_descriptions}",
          %{orphan_edges: orphan_edges}
        )
        | issues
      ]
    else
      issues
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_issue(severity, code, message, context) do
    %{
      severity: severity,
      code: code,
      message: message,
      context: context
    }
  end

  defp find_reachable_nodes(graph, current, visited) do
    if MapSet.member?(visited, current) do
      visited
    else
      visited = MapSet.put(visited, current)
      edges = Map.get(graph.edges, current, [])

      targets =
        Enum.map(edges, fn
          {target, _condition} -> target
          target when is_binary(target) -> target
        end)

      Enum.reduce(targets, visited, fn target, acc ->
        find_reachable_nodes(graph, target, acc)
      end)
    end
  end
end
