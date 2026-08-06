#!/usr/bin/env elixir
#
# Subscribe to a smolsqls database's SSE change feed
# (GET /v1/databases/:id/changes) — the Elixir tool the skills use instead of
# a hand-rolled curl. Self-contained via Mix.install; works from the repo or a
# globally-symlinked skill.
#
#   elixir skills/query-db/smolsqls_subscribe.exs [opts]
#
# Prints one JSON object per change event to stdout (jsonl); connection
# lifecycle goes to stderr. Reconnects automatically when a connection ends
# (the server caps each connection at timeout_ms, max 10 minutes), so treat it
# as a long-running process and stop it with SIGINT/SIGTERM. NOTE: events that
# occur between connections are lost — the feed has no resume cursor yet.
#
# Options:
#   --db NAME         credential set to use (default: pm). Any name works.
#   --url URL         base URL override (non-secret)
#   --id ID           database id override (non-secret)
#   --env FILE        dotenv file to load first (default: per --db)
#   --timeout-ms N    per-connection server timeout (default 600000, the max)
#   --max-events N    exit 0 after N events (across reconnects); for tests
#   --once            single connection, exit when it ends (no reconnect)
#
# Credentials come from the environment exactly like smolsqls_query.exs:
# SMOLSQLS_<NAME>_URL / _DB_ID / _DB_TOKEN, auto-loading .claude/<name>.env
# (pm -> .claude/smolsqls-pm.env, alpha -> .claude/alpha-db.env). The token is
# only ever read from the environment.
#
# Do NOT add an `accept: text/event-stream` header if you port this to curl —
# the endpoint 406s on it; the default `*/*` works.

Mix.install([{:req, "~> 0.6"}])

defmodule SmolsqlsSubscribe do
  @default_url "https://alpha.smolsqls.com"
  @max_timeout_ms 600_000
  @receive_timeout_ms 60_000
  @reconnect_delay_ms 1_000

  def main(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          db: :string,
          url: :string,
          id: :string,
          env: :string,
          timeout_ms: :integer,
          max_events: :integer,
          once: :boolean
        ]
      )

    unless invalid == [], do: die("unknown option(s): #{inspect(invalid)}")
    unless rest == [], do: die("unexpected argument(s): #{inspect(rest)}")

    db = opts[:db] || "pm"
    prefix = prefix(db)
    load_env(opts[:env] || default_env(db))

    url = opts[:url] || System.get_env("#{prefix}_URL") || @default_url

    id =
      opts[:id] || System.get_env("#{prefix}_DB_ID") ||
        die("#{prefix}_DB_ID is not set (or pass --id)")

    token = System.get_env("#{prefix}_DB_TOKEN") || die("#{prefix}_DB_TOKEN is not set")
    timeout_ms = min(opts[:timeout_ms] || @max_timeout_ms, @max_timeout_ms)

    req =
      Req.new(
        base_url: url,
        headers: [{"authorization", "Bearer " <> token}],
        url: "/v1/databases/#{id}/changes",
        params: [timeout_ms: timeout_ms],
        receive_timeout: @receive_timeout_ms,
        retry: false
      )

    subscribe_loop(req, opts, 0)
  end

  defp subscribe_loop(req, opts, count) do
    count = connect(req, opts, count)

    cond do
      done?(opts, count) ->
        :ok

      opts[:once] ->
        :ok

      true ->
        log("reconnecting in #{@reconnect_delay_ms}ms… (events between connections are lost)")
        Process.sleep(@reconnect_delay_ms)
        subscribe_loop(req, opts, count)
    end
  end

  defp connect(req, opts, count) do
    case Req.get(req, into: :self) do
      {:ok, %{status: 200} = resp} ->
        log("connected (streaming changes)")
        drain(resp, "", opts, count)

      {:ok, %{status: status} = resp} when status in [401, 403, 404] ->
        die("HTTP #{status}: #{inspect(read_all(resp))}")

      {:ok, %{status: status} = resp} ->
        log("HTTP #{status} (#{inspect(read_all(resp))}); will retry")
        count

      {:error, e} ->
        log("connection failed: #{Exception.message(e)}; will retry")
        count
    end
  end

  defp drain(resp, buffer, opts, count) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            if :done in chunks do
              log("stream ended by server")
              count
            else
              {buffer, count} =
                chunks
                |> Enum.flat_map(fn
                  {:data, data} -> [data]
                  _ -> []
                end)
                |> Enum.reduce({buffer, count}, fn data, {buffer, count} ->
                  emit_frames(buffer <> data, count)
                end)

              if done?(opts, count) do
                Req.cancel_async_response(resp)
                count
              else
                drain(resp, buffer, opts, count)
              end
            end

          {:error, e} ->
            log("stream error: #{Exception.message(e)}")
            count

          :unknown ->
            drain(resp, buffer, opts, count)
        end
    after
      @receive_timeout_ms ->
        log("no data or keepalive for #{@receive_timeout_ms}ms; dropping connection")
        Req.cancel_async_response(resp)
        count
    end
  end

  defp emit_frames(buffer, count) do
    parts = String.split(buffer, "\n\n")
    {frames, [rest]} = Enum.split(parts, -1)

    count =
      Enum.reduce(frames, count, fn frame, count ->
        case data_lines(frame) do
          [] ->
            count

          lines ->
            IO.puts(Enum.join(lines, "\n"))
            count + 1
        end
      end)

    {rest, count}
  end

  defp data_lines(frame) do
    for "data: " <> data <- String.split(frame, "\n"), do: data
  end

  defp done?(opts, count), do: opts[:max_events] && count >= opts[:max_events]

  defp read_all(resp) do
    case Req.parse_message(resp, receive(do: (m -> m))) do
      {:ok, chunks} ->
        Enum.flat_map(chunks, fn
          {:data, d} -> [d]
          _ -> []
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp prefix(db), do: "SMOLSQLS_" <> String.replace(String.upcase(db), ~r/[^A-Z0-9]+/, "_")

  defp default_env("pm"), do: ".claude/smolsqls-pm.env"
  defp default_env("alpha"), do: ".claude/alpha-db.env"
  defp default_env(db), do: ".claude/#{db}.env"

  defp load_env(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        case Regex.run(~r/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$/, String.trim_trailing(line)) do
          [_, k, v] -> System.put_env(k, String.trim(v, "\""))
          _ -> :ok
        end
      end)
    end

    :ok
  end

  defp log(msg), do: IO.puts(:stderr, "[subscribe] #{msg}")

  defp die(msg) do
    IO.puts(:stderr, "error: #{msg}")
    System.halt(1)
  end
end

SmolsqlsSubscribe.main(System.argv())
