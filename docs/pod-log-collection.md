# Cluster pod logs in Loki

Container stdout/stderr for every namespace now reaches Loki alongside the OTLP events the
two Rails apps push. Before this change Loki only had the OTLP streams, so
`/loki/api/v1/label/service_namespace/values` returned `["sitio-staging","sitio-production"]`
and nothing else existed. A weekly CronJob could fail for three weeks without anyone able to
read its output afterwards; the root cause had to be reconstructed from exit codes and the
image.

**Related:** [sitio-observability.md](sitio-observability.md) (Rails OTLP events) ·
[charts/alloy-values.yaml](../charts/alloy-values.yaml) · [charts/loki-values.yaml](../charts/loki-values.yaml)

---

## Pipeline

| Source | Component | Labels | Sink |
| --- | --- | --- | --- |
| Rails OTLP (4317/4318) | `otelcol.receiver.otlp` → batch → attributes → `otelcol.exporter.loki` | `service_name`, `service_namespace` | `loki.write "local"` → `loki-gateway.monitoring.svc.cluster.local` |
| Pod stdout/stderr | `discovery.kubernetes` (role `pod`) → `discovery.relabel` → `loki.source.kubernetes` | `namespace`, `pod`, `container`, `node` | same `loki.write "local"` |

Both paths write to the same endpoint; they are independent, so rolling back one leaves the
other working.

### Why `loki.source.kubernetes` and not a `/var/log/pods` hostPath

The `grafana/alloy` chart renders a **DaemonSet** (`controller.type` defaults to `daemonset`,
and this repo does not override it — verified in the cluster: `monitoring/alloy` is a
DaemonSet with one pod on the single node). So `loki.source.file` with the standard
`/var/log/pods` + `/var/log/containers` hostPaths would be viable here.

Chosen instead: `loki.source.kubernetes`, which streams `pods/log?follow=true` through the API
server.

| | `loki.source.kubernetes` (chosen) | `loki.source.file` + hostPath |
| --- | --- | --- |
| Node access | none | mounts host `/var/log` (`alloy.mounts.varlog: true`) |
| Labels | straight from the API (`__meta_kubernetes_*`) | must be parsed out of `/var/log/pods/<ns>_<pod>_<uid>/<container>/0.log` |
| RBAC | none: the chart's ClusterRole already grants `pods`, `pods/log` cluster-wide | same ClusterRole, plus a host mount |
| API server load | ~142 MB/day relayed on the single node | none |
| Survives `controller.type` change | yes | silently collects nothing if the chart ever renders a Deployment/StatefulSet |
| Restart behavior | re-reads each container log from the start (no `tail_from_end` in Alloy 1.14, positions live in `/tmp/alloy`) | `tail_from_end = true` available |

The deciding factors are the last two rows: the API path keeps working whatever the chart
renders, needs no host filesystem access, and needs no log-path parsing. The price is
apiserver relay traffic on one node (trivial) and a bounded replay after an Alloy pod restart
(see [Known limits](#known-limits)).

## Label scheme

| Label | From | Notes |
| --- | --- | --- |
| `namespace` | `__meta_kubernetes_namespace` | |
| `pod` | `__meta_kubernetes_pod_name` | |
| `container` | `__meta_kubernetes_pod_container_name` | |
| `node` | `__meta_kubernetes_pod_node_name` | single node today, so it is constant |

No collisions with the OTLP path: that path promotes `service.name` → `service_name` and
`service.namespace` → `service_namespace`, names the pod discovery never produces. An OTLP
entry has `service_*` and no `namespace`/`pod`; a pod log entry has `namespace`/`pod` and no
`service_*`. Queries that need both worlds must combine two streams (see below).

## Drop policy

Decisions, with the measured numbers behind them (see [Sizing](#sizing-math)):

| Drop | Reason | Cost |
| --- | --- | --- |
| whole `kube-system` namespace | 143 MB/day, 32% of all pod log bytes, and every pod there is OCI-managed on OKE (coredns, flannel, kube-proxy, csi-oci, `oke-*` agents) — the same reasoning that disabled OKE control-plane alerts | no coredns/flannel logs for debugging |
| `monitoring` / container `loki` | 156 MB/day, 35% of all pod log bytes, and each line follows a Grafana query, so ingesting it feeds itself | Loki's own stdout is not searchable |
| nothing else | argocd (89 MB/day), grafana, the app namespaces, Job pods, tailscale, pi are all worth their size | |

Both rules are two lines each in `discovery.relabel "pod_logs"`; narrowing the
`kube-system` regex or deleting the `monitoring;loki` rule re-enables a source on the next
sync.

## Sizing math

Measured read-only on 2026-11-02 (kubelet `/logs/` endpoint through the API server, plus
`/metrics` of `loki-0`), with kubelet `containerLogMaxSize: 20Mi`, `containerLogMaxFiles: 5`:

- 59 pod log directories, 158 files, **772 MiB** of retained container logs on the node.
- Steady-state rate computed per container (time between consecutive 20 MiB kubelet
  rotations; for containers that never rotate, bytes over the whole retained window) and
  summed: **441 MB/day** of container stdout/stderr cluster-wide.

| Namespace | MB/day | after drop rules |
| --- | --- | --- |
| monitoring | 174 | 18 (`loki` 156 dropped) |
| kube-system | 143 | 0 (whole namespace dropped) |
| argocd | 89 | 89 |
| sitio-production + production | 15 | 15 |
| sitio-staging + staging | 12 | 12 |
| pi / games / tailscale / rest | 8 | 8 |
| **total** | **441** | **142** |

What that costs on disk. Compression was measured on the live volume
(`loki_distributor_bytes_received_total` 2.835 GB received vs 210 MiB occupied, i.e. 165 MiB
chunks + 45 MiB TSDB index) → **13.5x**. Planning uses 13.5x (structured events) to 6x
(mixed plaintext) as the range:

- 142 MB/day → **10.5–24 MiB/day** stored.
- 14 days retention → 147–330 MiB of chunks + index ≈ **185–415 MiB**.
- Without the drop rules: 441 MB/day → 33–74 MiB/day, i.e. the 1 GiB volume fills in
  **2–6 weeks**, and never stops growing.

## Retention and volume decision

Implemented: `limits_config.retention_period: 336h` (14 days) + a filesystem compactor, while
**keeping the 1 GiB PVC**.

- Retention needs the compactor. In `SingleBinary` mode the chart runs `-target=all`, so the
  compactor is inside `loki-0`; `compactor.replicas: 0` stays 0 and no second pod appears
  (verified with `helm template`). `delete_request_store: filesystem` is mandatory — Loki
  refuses to start with `retention_enabled` and an empty store.
- 14 days keeps steady state at ≲450 MiB of 1 GiB, which leaves room for a spike without
  touching the volume size. Rejected alternatives: no retention (fills the volume and never
  stops — see above) and a bigger PVC without retention (just buys a few more weeks).
- Cost on the node: none in RAM (compactor in-process, a few MiB), and no boot-volume cost —
  the PVC is `nfs-client`, backed by `nfs-server`'s 50 GiB OCI block volume (8.3 GB used of
  48.9 GB). The node boot volume stays at 63.8 GiB with ~33 GiB free either way, because pod
  logs are read through the API and never copied.
- If 14 days is too short: raise `limits_config.retention_period` and, if the math above stops
  fitting, `singleBinary.persistence.size` (the class sets `allowVolumeExpansion`). Note that
  `nfs-subdir-external-provisioner` enforces no quota, so the PVC size is advisory only —
  retention, not capacity, is what bounds growth.
- **Destructive on first run:** the compactor deletes existing data older than 14 days, which
  includes most of the 73 days of OTLP history already in the volume. The Grafana dashboards
  query ≤24 h windows, so this is not visible there, but the history is gone for good.

Alloy's memory limit goes 512Mi → 768Mi (request 128Mi → 192Mi): pod tailing adds ~70
concurrent streams, measured baseline was 78 MiB RSS, and an OOMKill would lose the only log
shipper. The node has ~3.1 GiB available.

## Queries that now work

```logql
{namespace="monitoring"} |= "level=error"
{namespace="argocd"} |= "error"
{namespace="sitio-production"} |~ "(?i)sqlite|backup"
{namespace="platform"} | json
{pod=~"sitio-rails-sqlite-backup-.*"}
{pod="sitio-rails-6d49b856d-q45jm", container="sitio-rails"} |= "500"
{namespace="sitio-staging"} |= "ERROR"
sum by (namespace) (rate({namespace!=""}[5m]))
```

Job pods are the important case: `{pod=~"sitio-rails-sqlite-backup-.*"}` keeps the output of a
CronJob run after it finishes, as long as the pod still exists (or the entries are inside the
retention window).

The Rails OTLP queries in [sitio-observability.md](sitio-observability.md) are unchanged —
those streams have no `namespace` label, so they never match the pod-log queries above.

## Verify after Argo syncs

Read-only, from a laptop with the `oracle-cluster` context. Nothing here writes to the cluster.

```bash
kubectl -n argocd get applications monitoring-alloy monitoring-loki
kubectl -n monitoring get ds alloy -o wide          # READY 1/1, pod not restarting
kubectl -n monitoring logs ds/alloy -c alloy --tail=40   # no "failed to" / "forbidden"
kubectl -n monitoring get sts loki -o wide          # loki-0 Ready 2/2
```

Then query Loki through the gateway:

```bash
kubectl -n monitoring port-forward svc/loki-gateway 3100:80 &
# namespaces that now exist. Expected: whatever namespaces actually log, minus
# kube-system. Small namespaces only appear once they emit a line.
curl -s http://127.0.0.1:3100/loki/api/v1/label/namespace/values | jq

# one known pod, last 5 entries
curl -s -G http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="monitoring", pod=~".+"}' \
  --data-urlencode 'limit=5' | jq '.data.result | length'
```

The retention config Loki actually loaded (the `loki` image is distroless, so read the config
over HTTP rather than with `exec`):

```bash
kubectl -n monitoring port-forward svc/loki 3101:3100 &
curl -s http://127.0.0.1:3101/config | grep -A6 '^compactor:'
# expected: retention_enabled: true, delete_request_store: filesystem
curl -s http://127.0.0.1:3101/config | grep retention_period   # expected: 336h
```

Grafana → Explore → Loki datasource (`uid: loki`) → run `{namespace="argocd"}`: the label
browser should list `container`, `namespace`, `node`, `pod`.

Compaction on the filesystem (the first run deletes data older than 14 days). Loki's image has
no shell, so measure the PVC from the NFS server pod, which is where the volume really lives:

```bash
kubectl -n platform exec deploy/nfs-server -- du -sh /exports/monitoring/storage-loki-0/chunks
# before the change: 165M. After one compaction interval (10 min) it should drop toward
# the 14-day estimate (147-330 MiB chunks); compare again a day later for the daily delta.
```

## Known limits

- **Multi-node:** `loki.source.kubernetes` discovers every pod cluster-wide, not just the pods
  of its own node. With one node and one Alloy pod this is exactly right; adding a second node
  would duplicate every stream. Fix it then by restricting discovery with a node field
  selector, switching to hostPath collection, or enabling Alloy clustering.
- **Replay after restart:** Alloy 1.14's `loki.source.kubernetes` has no `tail_from_end` and
  keeps its positions in `/tmp/alloy` (the chart's `alloy.storagePath`, an ephemeral path), so
  a pod restart re-reads each container log from the beginning. That is bounded by the
  kubelet cap (≤100 MiB per container) and by `reject_old_samples_max_age: 168h`, which makes
  Loki reject anything older than 7 days — expect some duplicate recent lines after a restart.
- **Stream count grows with Jobs:** `pod` is a stream label, so every Job run is a new stream.
  Weekly CronJobs are negligible; a chatty Job with a short TTL is not.
- **kube-system and Loki's own logs are not collected** (see [Drop policy](#drop-policy)).
- **Nothing historical comes back:** the collector sees what the kubelet still has in
  `/var/log/pods` (≤100 MiB per container) and Loki rejects samples older than 7 days, so a
  failure that happened before the first sync is only visible to the extent its container log
  files still exist on the node.

## Rollback

Both changes are independent, so roll back only what misbehaves. All of it goes through Git —
ArgoCD self-heals, so a manual `kubectl edit` is reverted on the next reconciliation.

| Symptom | Action |
| --- | --- |
| API server load / Alloy restarts | `git revert` the `charts/alloy-values.yaml` change (or delete the `loki.source.kubernetes` + `discovery.*` blocks). Pod-log ingest stops, the OTLP path keeps working, existing pod-log data stays in Loki until retention removes it. |
| Loki volume still filling | Revert `charts/loki-values.yaml`: the compactor stops deleting and `retention_period` disappears. Data will grow again, so this only buys time before the volume has to grow. |
| Everything | `git revert <commit>` for both files, push, let Argo sync. |

What rollback cannot do: restore the pre-14-day data the compactor already deleted. The first
compaction after the sync is destructive and irreversible.
