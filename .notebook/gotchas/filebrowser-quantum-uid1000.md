# FileBrowser Quantum UID 1000

Tags: gotcha, filebrowser, quantum, nfs, permissions

## Symptom

CrashLoop with:
- `open .../database.db: permission denied`
- then (after chown) `listen tcp 0.0.0.0:80: bind: permission denied`

## Cause

Quantum ≥1.3 runs as UID/GID `1000:1000` (`filebrowser`). Older installs left NFS data as `root:root` mode `600`. Non-root also cannot bind privileged port 80 in this cluster (`NET_BIND_SERVICE` alone was insufficient).

## Fix

1. NFS data: `chown -R 1000:1000 /exports/platform/filebrowser` (persisted via nfs-server init).
2. Listen on `8080`; Service `port: 80` → `targetPort: 8080`.
3. Pod `securityContext.runAsUser/runAsGroup/fsGroup: 1000`.

## Related

- `apps/platform/filebrowser/deployment.yaml`
- `apps/platform/filebrowser/filebrowser-config.yaml` (`server.port: 8080`)
- `apps/platform/storage/nfs-server-deployment.yaml` (init chown)
- PV currently mounts NFS `/` so `/srv` indexes the whole export (Loki WAL permission errors are noisy but non-fatal).
