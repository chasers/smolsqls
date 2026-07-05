#!/usr/bin/env bash
# Phase 6 §4: cross-pod query latency in the kind cluster — re-run of
# the phase 3 measurement, now with gen_rpc over TLS. Compare against
# the plaintext numbers in RESULTS.md.
#
#   ./bench/qps/kind_latency.sh [pod]
set -euo pipefail

POD=${1:-sqlites-0}

kubectl exec -n sqlites "$POD" -- /app/bin/sqlites rpc '
  {:ok, tenant} =
    Sqlites.ControlPlane.create_tenant(%{
      "name" => "LatBench",
      "slug" => "lat-#{System.unique_integer([:positive])}"
    })

  dbs =
    for i <- 1..6 do
      {:ok, db} = Sqlites.create_database(tenant, %{"name" => "lat-#{i}"})
      {:ok, _} = Sqlites.DataPlane.query(db.id, "CREATE TABLE t (v TEXT)")
      db
    end

  owner_of = fn db ->
    {:ok, owner} = Sqlites.DataPlane.owner_node(db.id)
    owner
  end

  measure = fn label, db ->
    latencies =
      for _ <- 1..2000 do
        started = System.monotonic_time(:microsecond)
        {:ok, _} = Sqlites.DataPlane.query(db.id, "SELECT 1")
        System.monotonic_time(:microsecond) - started
      end

    sorted = Enum.sort(latencies)
    avg = div(Enum.sum(latencies), length(latencies))
    p99 = Enum.at(sorted, floor(length(sorted) * 0.99))
    IO.puts("#{label}: avg #{avg}us p99 #{p99}us (n=2000)")
  end

  local_db = Enum.find(dbs, fn db -> owner_of.(db) == Node.self() end)
  remote_db = Enum.find(dbs, fn db -> owner_of.(db) != Node.self() end)

  if local_db, do: measure.("owner-local", local_db), else: IO.puts("no locally-owned db")

  if remote_db do
    measure.("cross-pod via gen_rpc (TLS when enabled)", remote_db)
  else
    IO.puts("no remotely-owned db — placement put everything here")
  end

  {:ok, _} = Sqlites.delete_tenant(tenant)
  IO.puts("cleaned up")
'
