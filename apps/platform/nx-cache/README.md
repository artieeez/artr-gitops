# Nx remote cache

A self-hosted [Nx](https://nx.dev) remote cache at `https://nx-cache.artr.com.br`, running [enxtur/nx-caching-server](https://github.com/enxtur/nx-caching-server). That server implements Nx's custom remote cache OpenAPI spec, so it works with Nx 20.8 or later. You don't need Nx Cloud or a Powerpack plugin.

| Piece | Value |
| --- | --- |
| Image | `docker.io/enxtur/nx-caching-server` (Go, multi-arch) |
| Storage | `emptyDir` on the node's local disk, mounted at `/data`, `sizeLimit: 5Gi`. Empty again after every pod restart or rollout; losing it means one cold build |
| Eviction | `CLEANUP_THRESHOLD=72h`: an entry that isn't read or written for 72 h is deleted. If the cache grows past 5 Gi, the kubelet evicts the pod and it comes back empty |
| Auth | `AUTH_TOKENS` from the `nx-cache-tokens` SealedSecret. Each repository has its own token and can only see `/data/<name>/` |
| In-cluster URL | `http://nx-cache.platform.svc.cluster.local:8090` |
| Public URL | `https://nx-cache.artr.com.br` (Traefik, wildcard cert) |

## First deploy

DNS needs nothing: the `*.artr.com.br` wildcard already points at the cluster, and Traefik routes by host.

1. Seal the tokens. List every repository that should use the cache:

   ```bash
   ./scripts/seal-nx-cache.sh my-monorepo code-factory
   ```

   A new name gets a token that is printed only once. Store it right away in that repository's CI secrets.
2. Commit `apps/platform/nx-cache/` and `argocd/applications/platform/platform-nx-cache.yaml`. `artr-platform` picks up the new Application.

The pod stays in `CreateContainerConfigError` until the sealed Secret exists, so do step 1 before you merge.

## Adding or rotating a repository

Re-run the script with the **full** list of names. Names you leave out lose access. Existing tokens are kept. To rotate a token, set `ROTATE=name`. Then commit the regenerated `nx-cache-tokens-sealed.yaml`. The pod reads `AUTH_TOKENS` only at startup, so restart it after ArgoCD syncs:

```bash
kubectl -n platform rollout restart deploy/nx-cache
```

## Client setup

```bash
export NX_SELF_HOSTED_REMOTE_CACHE_SERVER=https://nx-cache.artr.com.br
export NX_SELF_HOSTED_REMOTE_CACHE_ACCESS_TOKEN=<that repo's token>
```

In GitHub Actions:

```yaml
env:
  NX_SELF_HOSTED_REMOTE_CACHE_SERVER: https://nx-cache.artr.com.br
  NX_SELF_HOSTED_REMOTE_CACHE_ACCESS_TOKEN: ${{ secrets.NX_CACHE_TOKEN }}
```

In-cluster workloads such as code-factory workers should use the in-cluster URL. That traffic stays off Traefik.

## Why not NFS

The `nfs-client` storage class sits on one shared 49 GB block volume alongside Postgres, Prometheus, Loki and the apps' SQLite files, and it doesn't enforce PVC sizes. A cache that grows without limit could fill that disk and break all of them. The cache is disposable, so it uses local node disk with a hard size limit instead.

If the pod is evicted often (`kubectl -n platform get events --field-selector involvedObject.kind=Pod | grep nx-cache`), lower `CLEANUP_THRESHOLD` or raise `sizeLimit`. Each node has about 20 GB of local disk free.

## Security notes

- **Cache poisoning (CVE-2025-36852, "CREEP").** Every token can both read and write. Anyone holding a token can upload artifacts that later builds will trust. Only give tokens to trusted CI: do not expose them to fork PRs, and do not use `pull_request_target` with this secret. The server has no read-only tokens.
- Requests to `/v1/cache/*` without a valid token get `401`. `/health` is open.

## Troubleshooting

```bash
kubectl -n platform get pod -l app=nx-cache
kubectl -n platform logs deploy/nx-cache
curl -s https://nx-cache.artr.com.br/health          # OK
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" \
  https://nx-cache.artr.com.br/v1/cache/does-not-exist  # 404 = auth OK
```

Large uploads that fail through Traefik but work in-cluster are probably hitting the `websecure` entrypoint's read timeout, which defaults to 60 s in Traefik v3. If so, raise `ports.websecure.transport.respondingTimeouts.readTimeout` in `charts/traefik-values.yaml`.
