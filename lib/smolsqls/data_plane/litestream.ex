defmodule Smolsqls.DataPlane.Litestream do
  @moduledoc """
  Hot-set replication: only databases with a running server are
  registered with the node's Litestream sidecar (dynamic registration
  over its control socket). `stop/1` performs a final sync before
  returning, so a cleanly idled database's replica is current — the
  replica is the single restore source for failover.

  Replica URLs are database-addressed (`<prefix>/<tenant>/<db>`), never
  node-addressed, so any node can restore any database.

  Disabled outside Kubernetes (`enabled: false`); all functions no-op.
  The `:binary` is configurable so tests can substitute a stub.
  """

  require Logger

  alias Smolsqls.ControlPlane.Database

  @spec enabled?() :: boolean()
  def enabled? do
    config()[:enabled] || false
  end

  @spec register(Database.t()) :: :ok | {:error, term()}
  def register(%Database{} = database) do
    if enabled?() do
      run([
        "register",
        "-socket",
        socket(),
        "-replica",
        replica_url(database),
        database.file_path
      ])
    else
      :ok
    end
  end

  @spec stop(Path.t()) :: :ok | {:error, term()}
  def stop(file_path) do
    if enabled?() do
      run(["stop", "-socket", socket(), file_path])
    else
      :ok
    end
  end

  @doc """
  Restores a database's replica to `dest_path`.

  The source (`database`) and the destination (`dest_path`) are decoupled,
  so this serves both the failover path (restore a database onto its own
  file on a fresh volume) and seeding a *different* file from a parent's
  replica — the substrate for branching.

  Options:

    * `:timestamp` — a `DateTime` or RFC3339 string; restores the replica to
      that point in time (litestream `-timestamp`) instead of the latest.
  """
  @spec restore(Database.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def restore(%Database{} = database, dest_path, opts \\ []) do
    if enabled?() do
      File.mkdir_p!(Path.dirname(dest_path))
      run(["restore", "-o", dest_path] ++ timestamp_args(opts) ++ [replica_url(database)])
    else
      {:error, :litestream_disabled}
    end
  end

  defp timestamp_args(opts) do
    case Keyword.get(opts, :timestamp) do
      nil -> []
      %DateTime{} = at -> ["-timestamp", DateTime.to_iso8601(at)]
      at when is_binary(at) -> ["-timestamp", at]
    end
  end

  @doc """
  The replica's available point-in-time range, from `litestream ltx`: the
  earliest and latest transaction timestamps across all compaction levels. Used
  to clamp a branch's requested point-in-time to what the replica actually
  holds. Reads the object store only.

  Returns `{:error, :no_replica}` when the replica has no LTX files yet, and
  `{:error, :litestream_disabled}` when litestream is off.
  """
  @spec replica_range(Database.t()) ::
          {:ok, %{earliest: DateTime.t(), latest: DateTime.t()}} | {:error, term()}
  def replica_range(%Database{} = database) do
    if enabled?() do
      with {:ok, output} <-
             cmd(["ltx", "-level", "all", "-json", replica_url(database)],
               stderr_to_stdout: false
             ) do
        parse_ltx_range(output)
      end
    else
      {:error, :litestream_disabled}
    end
  end

  defp parse_ltx_range(output) do
    with {:ok, entries} when is_list(entries) <- Jason.decode(output),
         stamps =
           for(
             %{"timestamp" => ts} <- entries,
             {:ok, dt, _} <- [DateTime.from_iso8601(ts)],
             do: dt
           ),
         [_ | _] <- stamps do
      {:ok, %{earliest: Enum.min(stamps, DateTime), latest: Enum.max(stamps, DateTime)}}
    else
      _ -> {:error, :no_replica}
    end
  end

  @spec replica_url(Database.t()) :: String.t()
  def replica_url(%Database{} = database) do
    "#{config()[:replica_url_prefix]}/#{database.tenant_id}/#{database.id}"
  end

  defp run(args) do
    case cmd(args) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp cmd(args, opts \\ []) do
    merge_stderr = Keyword.get(opts, :stderr_to_stdout, true)

    case System.cmd(config()[:binary] || "litestream", args,
           stderr_to_stdout: merge_stderr,
           env: env()
         ) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        Logger.warning(
          "litestream #{hd(args)} failed (#{status}): #{String.slice(output, 0, 500)}"
        )

        {:error, {:litestream, status}}
    end
  end

  defp env do
    store = Application.get_env(:smolsqls, Smolsqls.ObjectStore, [])

    [
      {"LITESTREAM_ACCESS_KEY_ID", store[:access_key_id] || ""},
      {"LITESTREAM_SECRET_ACCESS_KEY", store[:secret_access_key] || ""}
    ]
  end

  defp socket do
    config()[:socket] || "/var/run/litestream/litestream.sock"
  end

  defp config do
    Application.get_env(:smolsqls, __MODULE__, [])
  end
end
