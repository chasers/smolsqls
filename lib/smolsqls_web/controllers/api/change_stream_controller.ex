defmodule SmolsqlsWeb.Api.ChangeStreamController do
  use SmolsqlsWeb, :controller

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane.ChangeStream

  action_fallback SmolsqlsWeb.Api.FallbackController

  @keepalive_interval :timer.seconds(15)
  @default_duration :timer.minutes(5)
  @max_duration :timer.minutes(10)

  def show(conn, %{"database_id" => database_id} = params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, database} <- ControlPlane.authenticate_database(database_id, token),
         :ok <- check_stream_enabled(database),
         {:ok, limits} <- Smolsqls.Limits.resolve(database),
         :ok <- check_rate_limit(database, limits) do
      stream_changes(conn, database.id, max_events(params), duration_ms(params))
    end
  end

  defp stream_changes(conn, database_id, max_events, duration_ms) do
    :ok = ChangeStream.subscribe(database_id)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    deadline = System.monotonic_time(:millisecond) + duration_ms
    loop(conn, database_id, max_events, deadline)
  after
    ChangeStream.unsubscribe(database_id)
  end

  defp loop(conn, _database_id, 0, _deadline), do: conn

  defp loop(conn, database_id, remaining, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      conn
    else
      receive do
        {:smolsqls_change, ^database_id, event} ->
          continue(conn, encode_event(event), database_id, decrement(remaining), deadline)
      after
        min(remaining_ms, @keepalive_interval) ->
          continue(conn, ": keepalive\n\n", database_id, remaining, deadline)
      end
    end
  end

  defp continue(conn, frame, database_id, remaining, deadline) do
    case chunk(conn, frame) do
      {:ok, conn} -> loop(conn, database_id, remaining, deadline)
      {:error, _closed} -> conn
    end
  end

  defp decrement(:infinity), do: :infinity
  defp decrement(remaining), do: remaining - 1

  defp encode_event(event) do
    body =
      Jason.encode!(%{
        action: event.action,
        table: event.table,
        rowid: event.rowid,
        record: event.record
      })

    "event: change\ndata: " <> body <> "\n\n"
  end

  defp max_events(params) do
    case Integer.parse(Map.get(params, "max_events", "")) do
      {count, ""} when count > 0 -> count
      _other -> :infinity
    end
  end

  defp duration_ms(params) do
    case Integer.parse(Map.get(params, "timeout_ms", "")) do
      {ms, ""} when ms > 0 -> min(ms, @max_duration)
      _other -> @default_duration
    end
  end

  defp check_stream_enabled(%{change_stream_enabled: true}), do: :ok
  defp check_stream_enabled(_database), do: {:error, :change_stream_disabled}

  defp check_rate_limit(database, limits) do
    if Smolsqls.RateLimiter.allow?(database.id, limits.rate_limit_rps) do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end
end
