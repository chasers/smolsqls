#!/usr/bin/env bash
# Cold-start latency bench, in-cluster against the real MinIO/S3 object store
# on the kind 3-pod cluster — the only path that exercises a real S3 GET on
# the cold-restore path. Ships cold_start.exs into a pod and evaluates it via
# the release `rpc` command (same pattern as kind_latency.sh).
#
#   ./bench/cold_start/run.sh [pod]
#
# Requires the kind cluster up (scripts/kind-up.sh) with MinIO running.
set -euo pipefail

POD=${1:-smolsqls-0}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl exec -n smolsqls "$POD" -- /app/bin/smolsqls rpc "$(cat "$SCRIPT_DIR/cold_start.exs")"
