#!/usr/bin/env bash
# End-to-end smoke test against the kind cluster: agent lifecycle over
# the NodePort, cluster placement across pods, and operator-reported
# SqliteNode status.
set -euo pipefail

BASE=${BASE:-http://localhost:8080}

echo "==> API index"
curl -sf "$BASE/v1" >/dev/null

echo "==> tenant signup"
SIGNUP=$(curl -sf -X POST "$BASE/v1/tenants" -H 'content-type: application/json' \
  -d "{\"name\":\"Kind Smoke\",\"slug\":\"kind-smoke-$RANDOM\"}")
API_KEY=$(echo "$SIGNUP" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['api_key'])")

echo "==> create databases (placement should spread across pods)"
NODES=""
for i in 1 2 3 4 5 6; do
  DB=$(curl -sf -X POST "$BASE/v1/databases" -H "authorization: Bearer $API_KEY" \
    -H 'content-type: application/json' -d "{\"name\":\"smoke-$i\"}")
  DB_ID=$(echo "$DB" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
  DB_TOKEN=$(echo "$DB" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['auth_token'])")

  RESULT=$(curl -sf -X POST "$BASE/v1/databases/$DB_ID/query" \
    -H "authorization: Bearer $DB_TOKEN" -H 'content-type: application/json' \
    -d '{"sql":"CREATE TABLE t (v TEXT)"}')

  curl -sf -X POST "$BASE/v1/databases/$DB_ID/query" \
    -H "authorization: Bearer $DB_TOKEN" -H 'content-type: application/json' \
    -d "{\"sql\":\"INSERT INTO t VALUES (?)\",\"args\":[\"pod-check-$i\"]}" >/dev/null

  ROW=$(curl -sf -X POST "$BASE/v1/databases/$DB_ID/query" \
    -H "authorization: Bearer $DB_TOKEN" -H 'content-type: application/json' \
    -d '{"sql":"SELECT v FROM t"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['rows'][0][0])")
  [ "$ROW" = "pod-check-$i" ] || { echo "FAIL: round-trip mismatch"; exit 1; }
done

echo "==> idle-snapshot shipping: idle-stop on the owner, wipe its file, reactivate elsewhere"
MOVE_DB=$(curl -sf -X POST "$BASE/v1/databases" -H "authorization: Bearer $API_KEY" \
  -H 'content-type: application/json' -d '{"name":"smoke-move"}')
MOVE_ID=$(echo "$MOVE_DB" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
MOVE_TOKEN=$(echo "$MOVE_DB" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['auth_token'])")

curl -sf -X POST "$BASE/v1/databases/$MOVE_ID/query" \
  -H "authorization: Bearer $MOVE_TOKEN" -H 'content-type: application/json' \
  -d '{"sql":"CREATE TABLE t (v TEXT)"}' >/dev/null
curl -sf -X POST "$BASE/v1/databases/$MOVE_ID/query" \
  -H "authorization: Bearer $MOVE_TOKEN" -H 'content-type: application/json' \
  -d '{"sql":"INSERT INTO t VALUES (?)","args":["moved-data"]}' >/dev/null

kubectl exec -n sqlites sqlites-0 -- /app/bin/sqlites rpc "
  database = Sqlites.ControlPlane.get_database(\"$MOVE_ID\")
  :ok = Sqlites.DataPlane.idle_stop_database(database)
  database = Sqlites.ControlPlane.get_database(\"$MOVE_ID\")
  IO.inspect(database.snapshot_generation, label: :generation_after_idle_stop)
  survivors = for n <- [Node.self() | Node.list()], to_string(n) != database.node, do: n
  target = hd(survivors)
  {:ok, _} = database |> Sqlites.ControlPlane.Database.placement_changeset(%{status: :active, node: to_string(target)}) |> Sqlites.Repo.update()
  IO.puts(\"reassigned #{database.id} from #{database.node} to #{target}\")
"

ROW=$(curl -sf -X POST "$BASE/v1/databases/$MOVE_ID/query" \
  -H "authorization: Bearer $MOVE_TOKEN" -H 'content-type: application/json' \
  -d '{"sql":"SELECT v FROM t"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['rows'][0][0])")
[ "$ROW" = "moved-data" ] || { echo "FAIL: idle-snapshot reactivation lost data"; exit 1; }

echo "==> drain sqlites-1 live via the node_drains bus (as the operator would)"
DRAIN_NODE=$(kubectl exec -n sqlites sqlites-1 -- /app/bin/sqlites rpc 'IO.puts(Node.self())' | tail -1)
kubectl exec -n sqlites postgres-0 -- psql -U postgres -d sqlites -c \
  "INSERT INTO node_drains (node, requested_at) VALUES ('$DRAIN_NODE', now()) ON CONFLICT (node) DO NOTHING"

for _ in $(seq 1 24); do
  DONE=$(kubectl exec -n sqlites postgres-0 -- psql -tA -U postgres -d sqlites -c \
    "SELECT count(*) FROM node_drains WHERE node = '$DRAIN_NODE' AND completed_at IS NOT NULL")
  [ "$DONE" = "1" ] && break
  sleep 5
done
[ "$DONE" = "1" ] || { echo "FAIL: drain never completed"; exit 1; }

REMAINING=$(kubectl exec -n sqlites postgres-0 -- psql -tA -U postgres -d sqlites -c \
  "SELECT count(*) FROM databases WHERE node = '$DRAIN_NODE'")
[ "$REMAINING" = "0" ] || { echo "FAIL: $REMAINING databases still placed on drained node"; exit 1; }
kubectl exec -n sqlites postgres-0 -- psql -U postgres -d sqlites -c \
  "SELECT node, started_by, reassigned, error FROM node_drains WHERE node = '$DRAIN_NODE'"
kubectl exec -n sqlites postgres-0 -- psql -U postgres -d sqlites -c \
  "DELETE FROM node_drains WHERE node = '$DRAIN_NODE'"

echo "==> placement spread"
kubectl exec -n sqlites sqlites-0 -- /app/bin/sqlites rpc \
  'IO.inspect(Enum.frequencies(for {_, d} <- :ets.tab2list(Sqlites.ReadModel.Databases), d.node != nil, do: d.node))'

echo "==> cluster membership from inside a pod"
kubectl exec -n sqlites sqlites-0 -- /app/bin/sqlites rpc 'IO.inspect(Node.list())'

echo "==> SqliteNode statuses (operator-reported)"
kubectl -n sqlites get sqlitenodes

echo "==> replication slots on metadb"
kubectl exec -n sqlites postgres-0 -- psql -U postgres -d sqlites -c \
  "SELECT slot_name, active, wal_status FROM pg_replication_slots"

echo "SMOKE OK"
