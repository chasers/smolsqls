#!/usr/bin/env bash
# Boots the full smolsqls stack in a local kind cluster:
# 3 data-plane pods (each with a Litestream sidecar), Postgres with
# wal_level=logical, and MinIO as the S3 replica target.
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTER=smolsqls
KCTX="kind-${CLUSTER}"

# Pin every kubectl below to the local kind context. Both this cluster and the
# GKE staging cluster use the "smolsqls" namespace, so a stray ambient
# current-context could otherwise apply these local-dev manifests to GKE.
kubectl() { command kubectl --context "$KCTX" "$@"; }

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config deploy/overlays/kind/kind-config.yaml
fi

echo "==> generating dev TLS certs"
./scripts/gen-dev-certs.sh deploy/overlays/kind/tls

echo "==> building images"
docker build -t smolsqls:dev .
docker build -t smolsqls-operator:dev operator/

echo "==> loading images into kind"
kind load docker-image smolsqls:dev --name "$CLUSTER"
kind load docker-image smolsqls-operator:dev --name "$CLUSTER"

echo "==> applying manifests"
kubectl apply -k deploy/overlays/kind 2>/dev/null || true
kubectl wait --for condition=established crd/sqlitenodes.smolsqls.supabase.com --timeout=60s
kubectl apply -k deploy/overlays/kind

echo "==> restarting workloads so reloaded :dev images take effect"
kubectl -n smolsqls rollout restart statefulset/smolsqls deployment/smolsqls-operator

echo "==> waiting for postgres"
kubectl -n smolsqls rollout status statefulset/postgres --timeout=180s

echo "==> waiting for smolsqls"
kubectl -n smolsqls rollout status statefulset/smolsqls --timeout=300s

echo "==> done — API available at http://localhost:8080/v1"
kubectl -n smolsqls get pods
