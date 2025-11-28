defmodule BeamflowWeb.Plugs.RateLimiter do
  @moduledoc """
  Plug para rate limiting basado en IP usando ETS.

  ## Configuración

  - `:max_requests` - Máximo de requests permitidos (default: 60)
  - `:window_ms` - Ventana de tiempo en milisegundos (default: 60_000 = 1 minuto)

  ## Uso

      plug BeamflowWeb.Plugs.RateLimiter, max_requests: 100, window_ms: 60_000

  ## Headers de Respuesta

  - `X-RateLimit-Limit` - Límite máximo de requests
  - `X-RateLimit-Remaining` - Requests restantes en la ventana actual
  - `X-RateLimit-Reset` - Timestamp Unix cuando se reinicia la ventana

  ## Bypass

  Se puede desactivar en tests configurando `Application.put_env(:beamflow, :rate_limit_enabled, false)`
  """

  import Plug.Conn

  @behaviour Plug

  @default_max_requests 60
  @default_window_ms 60_000
  @ets_table :beamflow_rate_limiter

  @impl true
  def init(opts) do
    ensure_table_exists()
    %{
      max_requests: Keyword.get(opts, :max_requests, @default_max_requests),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms)
    }
  end

  @impl true
  def call(conn, opts) do
    if rate_limit_enabled?() do
      check_rate_limit(conn, opts)
    else
      conn
    end
  end

  defp rate_limit_enabled? do
    Application.get_env(:beamflow, :rate_limit_enabled, true)
  end

  defp check_rate_limit(conn, %{max_requests: max_requests, window_ms: window_ms}) do
    client_ip = get_client_ip(conn)
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    # Limpiar entradas antiguas y contar requests recientes
    {count, entries} = get_and_clean_entries(client_ip, window_start)

    reset_at = calculate_reset_time(entries, now, window_ms)
    remaining = max(0, max_requests - count - 1)

    conn = conn
    |> put_resp_header("x-ratelimit-limit", to_string(max_requests))
    |> put_resp_header("x-ratelimit-remaining", to_string(max(0, remaining)))
    |> put_resp_header("x-ratelimit-reset", to_string(div(reset_at, 1000)))

    if count >= max_requests do
      retry_after = max(1, div(reset_at - now, 1000))

      conn
      |> put_resp_header("retry-after", to_string(retry_after))
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{
        error: "rate_limit_exceeded",
        message: "Has excedido el límite de #{max_requests} requests por minuto",
        retry_after_seconds: retry_after
      }))
      |> halt()
    else
      # Registrar este request
      record_request(client_ip, now)
      conn
    end
  end

  defp get_client_ip(conn) do
    # Intentar obtener IP real detrás de proxy
    forwarded_for = get_req_header(conn, "x-forwarded-for")

    case forwarded_for do
      [ip_list | _] ->
        ip_list
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> Tuple.to_list()
        |> Enum.join(".")
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:named_table, :public, :bag, {:read_concurrency, true}])

      _ ->
        :ok
    end
  end

  defp get_and_clean_entries(client_ip, window_start) do
    ensure_table_exists()

    # Obtener todas las entradas para esta IP
    entries = try do
      :ets.lookup(@ets_table, client_ip)
    rescue
      ArgumentError -> []
    end

    # Filtrar solo las que están dentro de la ventana
    valid_entries = Enum.filter(entries, fn
      {_ip, {timestamp, _id}} -> timestamp >= window_start
      {_ip, timestamp} when is_integer(timestamp) -> timestamp >= window_start
    end)

    # Limpiar entradas antiguas
    stale_entries = entries -- valid_entries
    Enum.each(stale_entries, fn entry ->
      try do
        :ets.delete_object(@ets_table, entry)
      rescue
        ArgumentError -> :ok
      end
    end)

    {length(valid_entries), valid_entries}
  end

  defp record_request(client_ip, timestamp) do
    ensure_table_exists()
    # Usar un identificador único para evitar colisiones de timestamp
    unique_id = :erlang.unique_integer([:monotonic])
    try do
      :ets.insert(@ets_table, {client_ip, {timestamp, unique_id}})
    rescue
      ArgumentError -> :ok
    end
  end

  defp calculate_reset_time(entries, now, window_ms) do
    case entries do
      [] ->
        now + window_ms

      entries ->
        oldest = entries
        |> Enum.map(fn
          {_ip, {ts, _id}} -> ts
          {_ip, ts} when is_integer(ts) -> ts
        end)
        |> Enum.min()

        oldest + window_ms
    end
  end

  @doc """
  Limpia todas las entradas del rate limiter.
  Útil para tests.
  """
  @spec clear_all() :: :ok
  def clear_all do
    ensure_table_exists()
    try do
      :ets.delete_all_objects(@ets_table)
    rescue
      ArgumentError -> :ok
    end
    :ok
  end

  @doc """
  Obtiene estadísticas del rate limiter.
  """
  @spec stats() :: map()
  def stats do
    ensure_table_exists()
    entries = try do
      :ets.tab2list(@ets_table)
    rescue
      ArgumentError -> []
    end

    unique_ips = entries
    |> Enum.map(fn {ip, _} -> ip end)
    |> Enum.uniq()
    |> length()

    %{
      total_entries: length(entries),
      unique_clients: unique_ips
    }
  end
end
