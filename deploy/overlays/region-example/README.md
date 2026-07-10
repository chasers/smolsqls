# Per-region overlay (template)

Multi-region smolsqls runs **one GKE cluster per region**, each an independent
StatefulSet, all joined into **one Erlang cluster** and pointed at the **single
global metadb** (Cloud SQL). A global external load balancer geo-routes clients
to the nearest region on one hostname; any node transparently proxies a query to
the database's owning region over `gen_rpc`.

This directory is a **template** for one region. Copy it per region
(`region-us-central1/`, `region-europe-west1/`, …) and set the region-specific
values.

## Per-region values

| Where | Key | Example | Notes |
|---|---|---|---|
| `statefulset-region-patch.yaml` | `REGION` | `gcp-us-central1` | this node's region; upserted to the `nodes` table on boot |
| `statefulset-region-patch.yaml` | `RELEASE_NODE_HOST` | `$(POD_NAME).smolsqls-us-central1.smolsqls.svc.clusterset.local` | cross-cluster-routable node name (MCS clusterset FQDN) |
| `smolsqls-env` secret | `S3_BUCKET` | `smolsqls-replica-us-central1` | per-region object store |

## Same across every region

`REGIONS` (the full set, identical everywhere), `DEFAULT_REGION`, `PHX_HOST`
(the global LB host), `DATABASE_URL` (the one global metadb), `SECRET_KEY_BASE`,
`TOKEN_ENCRYPTION_KEY`, and `RELEASE_COOKIE`.

## Networking prerequisites (P5 / `smolsqls-deploy`)

Not provided by this overlay — they belong to the Terraform infra:

- Shared VPC (or peered) with **non-overlapping pod CIDR ranges** so pod IPs
  route directly cross-region.
- Firewall allowing `4369` (epmd), `9100` (dist), `5369`/`5870` (gen_rpc)
  between the regions' pod ranges.
- **GKE Multi-Cluster Services** `ServiceExport` of `smolsqls-headless` so each
  pod resolves as its clusterset FQDN.
- Per-node TLS certs whose CN/SAN match the clusterset FQDN (for `DIST_TLS` /
  `GEN_RPC_TLS`).
- The global external HTTPS load balancer (anycast + geo-DNS) fronting each
  region's API service.

## Known limitation

Until the metadb write-lease lands (see the `regional-placement` tracker plan),
a WAN partition can briefly allow a second writer for a database in another
region. GCP's premium backbone makes partitions rare, but this is the reason
cross-region production writes wait on the lease.
