# Phase 6 §4: control-plane operations at density-target scale.
#
#   mix run bench/qps/evacuation.exs
#
# Measures:
#   - Failover.evacuate/1 against 100k placement rows on the dead node
#     (pure metadb updates — the auto-failover path's worst case)
#   - Fence.sweep/1 with thousands of hot servers on this node
#
# Rows are inserted directly (insert_all) and deleted afterwards; no
# SQLite files are involved in the evacuation half.

import Ecto.Query

alias Sqlites.ControlPlane
alias Sqlites.ControlPlane.Database
alias Sqlites.Repo

defmodule Bench do
  def measure(label, fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    elapsed_us = System.monotonic_time(:microsecond) - start
    {result, elapsed_us / 1_000_000}
    |> tap(fn {_, s} -> IO.puts("#{label}: #{Float.round(s, 3)}s") end)
  end
end

{:ok, tenant} =
  ControlPlane.create_tenant(%{
    "name" => "Bench",
    "slug" => "bench-#{System.unique_integer([:positive])}"
  })

dead_node = "sqlites@bench-dead-node"
row_count = 100_000

IO.puts("== seeding #{row_count} placement rows on #{dead_node} ==")

now = DateTime.utc_now()

{_, seconds} =
  Bench.measure("insert_all", fn ->
    1..row_count
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      rows =
        for i <- chunk do
          %{
            id: Ecto.UUID.generate(),
            tenant_id: tenant.id,
            name: "evac-#{i}",
            status: :active,
            node: dead_node,
            file_path: "/var/lib/sqlites/data/#{tenant.id}/evac-#{i}.db",
            snapshot_generation: 1,
            limits: %{},
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Database, rows)
    end)
  end)

IO.puts("  -> #{Float.round(row_count / seconds, 0)} rows/s seeded\n")

IO.puts("== evacuate #{row_count} rows to the survivors ==")

{{:ok, %{reassigned: reassigned}}, seconds} =
  Bench.measure("Failover.evacuate", fn -> Sqlites.Failover.evacuate(dead_node) end)

IO.puts("  -> #{reassigned} rows reassigned, #{Float.round(row_count / seconds, 0)} rows/s\n")

IO.puts("== fence sweep with hot servers on this node ==")

server_count = 2_000
data_dir = Application.fetch_env!(:sqlites, :data_dir)

for i <- 1..server_count do
  id = Ecto.UUID.generate()
  path = Path.join([data_dir, "fence-bench", id <> ".db"])
  {:ok, _} = Sqlites.DataPlane.Supervisor.start_database(id, path)
end

{flagged, seconds} =
  Bench.measure("Fence.sweep over #{server_count} local servers", fn ->
    Sqlites.DataPlane.Fence.sweep()
  end)

IO.puts(
  "  -> #{Float.round(server_count / seconds, 0)} servers/s checked, " <>
    "#{MapSet.size(flagged)} flagged\n"
)

IO.puts("== cleanup ==")

for pid <- Sqlites.DataPlane.Supervisor.local_servers() do
  case Sqlites.DataPlane.Database.Server.database_id(pid) do
    {:ok, id} -> Sqlites.DataPlane.Supervisor.stop_database(id)
    _ -> :ok
  end
end

File.rm_rf!(Path.join(data_dir, "fence-bench"))
Repo.delete_all(where(Database, [d], d.tenant_id == ^tenant.id))
{:ok, _} = ControlPlane.delete_tenant(ControlPlane.get_tenant(tenant.id))
IO.puts("done")
