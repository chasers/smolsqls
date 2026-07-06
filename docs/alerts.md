# Alert conditions

The deliverable of phase 5 §3: what to page on, built from the
`GET /metrics` Prometheus endpoint (per node) and the operator's
`SqliteNode` status. Dashboards can land opportunistically; these
conditions are the contract.

## Page (wake someone)

| Condition | Signal | Why |
| --- | --- | --- |
| Idle-snapshot ships failing sustained | `rate(smolsqls_idle_snapshot_ship_count{result="error"}[10m]) > 0` for 15m | Every failed ship widens the data-loss window for that database on volume loss; sustained failure usually means S3 or metadb trouble. |
| Activations landing on `missing` | `increase(smolsqls_activation_count{path="missing"}[10m]) > 0` | A database could not be restored from any source — a client is being told their data is gone. |
| Auto-evacuation executed | `increase(smolsqls_node_operation_count{kind="evacuate",result="ok"}[10m]) > 0` | The system healed itself, but a node died; someone should look at why. |
| Evacuation failed | `smolsqls_node_operation_count{kind="evacuate",result="error"}` increases | Node is down AND re-placement failed — traffic to its databases is erroring. |
| Replication slot retention growing | `SqliteNode.status.replicationSlot.retainedBytes` growth over 30m, or `walStatus != "reserved"` | A node's read-model feed is stalled; unchecked, WAL retention takes down the metadb. |
| Node count below expected | `count(smolsqls_hot_servers_count)` (scrape targets) < replicas for 10m | A pod isn't serving; if the operator hasn't evacuated it, placement still points at it. |
| Daily backup SLA breached | `max(smolsqls_backup_sla_in_breach) > 0` for 30m | A database has no backup within the promised daily window — the sweeper isn't keeping up or is down, or object-store writes are failing. The gauge is polled per node independently of the sweeper, so `max()` across scrape targets is the fleet-wide truth. |

## Warn (business hours)

| Condition | Signal | Why |
| --- | --- | --- |
| gen_rpc failures | `rate(smolsqls_query_count{result="badrpc"}[5m]) > 1` | Inter-node transport is flaking; queries to remote databases are failing. |
| Fencing fired | `increase(smolsqls_fence_stopped_count[1h]) > 0` | A returning node held servers for re-placed databases — expected after an evacuation, suspicious otherwise. |
| Query error rate | `rate(smolsqls_query_count{result="error"}[5m]) / rate(smolsqls_query_count[5m]) > 0.05` | Mostly client SQL errors, but a step change tracks releases/incidents. |
| Query latency p99 | `histogram_quantile(0.99, smolsqls_query_duration_ms_bucket)` > 1s for 15m | Writer contention or slow restores on the activation path. |
| Restore latency | `histogram_quantile(0.99, smolsqls_activation_duration_ms_bucket{path!="cache_hit"})` > 30s | Cold-start SLO erosion — S3 slow or snapshots too large. |
| Evictor churn | `rate(smolsqls_cache_evictor_sweep_freed_bytes[1h])` persistently high | Disk high-water mark too low for the working set; activations pay repeated re-fetches. |
| Rate-limit rejections | `rate(smolsqls_rate_limiter_rejected_count[5m])` sustained per database | A tenant is hitting their ceiling — support signal, not incident. |
| Drain requested but not completing | `node_drains` row with `started_at` set and no `completed_at` for > 15m | Worker stuck or a hot database refusing to idle-stop. |

## Notes

- `/metrics` is per node and unauthenticated — scrape it inside the
  cluster only; do not route it through the public ingress.
- The operator also surfaces `status.drain`, `status.podReady`, and
  `status.notReadySince` on each `SqliteNode` (`kubectl get
  sqlitenodes`) — the failover timeline is reconstructable from those
  plus the `node_drains` table.
