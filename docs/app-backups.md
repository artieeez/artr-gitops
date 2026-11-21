# App Backups (off-node, nightly)

Nightly off-node backups for the stateful apps whose data lives on `nfs-client` PVCs. All those PVCs sit on one NFS pod and one 50 GB block volume, so without these backups a volume loss takes everything. Sitio has its own pipeline (see [SQLite backup runbook](sqlite-backup-runbook.md)); this covers everything else.

**Related:** GitOps manifests in `apps/app-backups/` · Applications in `argocd/applications/**/*-backup.yaml` · alerts in `charts/kube-prometheus-stack-values.yaml` (`app-backups`)

---

## What is backed up

| App | Namespace | PVC | Method | Object | Schedule (UTC) | Expected size/night |
| --- | --- | --- | --- | --- | --- | --- |
| pocketid | `platform` | `platform-pocketid-data` | SQLite `.backup` of `pocket-id.db` (WAL mode), `integrity_check` | `platform/pocketid/<ts>.sqlite3.gz` | 04:00 | ~1 MB |
| tinyauth | `platform` | `platform-tinyauth-data` | SQLite `.backup` of `tinyauth.db`, `integrity_check` | `platform/tinyauth/<ts>.sqlite3.gz` | 04:15 | < 100 KB |
| home (production) | `production` | `home-sqlite` | SQLite `.backup` of `production.sqlite3`, `integrity_check` | `production/home/<ts>.sqlite3.gz` | 04:30 | ~1 MB |
| hermes | `hermes` | `hermes-data` | tar.gz minus caches; every SQLite DB replaced by a consistent copy | `hermes/hermes/<ts>.tar.gz` | 05:15 | ~125 MB (measured) |

Sitio runs at 06:00 / 06:30 and the weekly volume snapshot at Sunday 07:00, so nothing overlaps.

Notes per app:

- **home**: only `production.sqlite3` (primary data) is backed up. `production_queue`, `_cache` and `_cable` are Solid Queue/Cache/Cable state and are not included; a restored app starts with an empty queue. (Unverified: that Rails recreates those files on boot. Check the entrypoint if you ever restore into an empty PVC.)
- **hermes**: excluded are `cache/`, `models_dev_cache.json`, `claude-home/.bundle-cache`, `claude-home/.local`, `claude-home/.cache`, and anywhere `node_modules`, `.bundle`, `vendor/bundle`. Of the 1.7 GB raw volume about 0.5 GB is `workspace` git worktrees, the rest of the kept data is small; compressed it measured about 126 MB (read-only `tar | gzip` of the same file set, SQLite files included raw). The archive contains `.env`, `auth.json` and `.ssh/`, i.e. **secrets in plaintext inside the bucket**. The bucket is private and credentials are tenancy-internal, but treat bucket read access as equal to hermes secrets access.
- **WAL databases** (pocketid, hermes): the `-shm` index is an mmap'd file that is not coherent across NFS clients and cannot be created on a read-only mount. The script therefore copies the `.db` and `-wal` to scratch space, retrying if the main file changed during the copy (a checkpoint racing the copy), lets SQLite replay the WAL there, runs `.backup`, then `PRAGMA integrity_check`. Rollback-journal databases (tinyauth, home) are read with `sqlite3 -readonly ... .backup` straight from the source.

## How it works

One script, `apps/app-backups/base/backup.sh`, is generated into a ConfigMap `app-backup-scripts` (kustomize `configMapGenerator`) and included once per namespace by `apps/app-backups/<dir>/` (`platform` holds both pocketid and tinyauth, since two Applications rendering `../base` into one namespace would fight over its ConfigMap and SealedSecret). Every app has a CronJob `app-backup-<app>` that mounts its data PVC **read-only**, runs the script, uploads with `aws s3 cp`, then `head-object`s the key and compares sizes. Any failure exits non-zero.

- Image: `public.ecr.aws/amazonlinux/amazonlinux:2023` pinned by digest; tools (`sqlite`, `awscli`, `gzip`, `tar`, `findutils`, `python3`) are installed at start like the sitio Jobs (same 512Mi request / 1Gi limit; a prebuilt image is the durable fix).
- Runs as root. The NFS export is `no_root_squash`; that is what lets it read hermes' `0700` data directory owned by uid 10000.
- `concurrencyPolicy: Forbid`, `backoffLimit: 1`, `activeDeadlineSeconds: 3600`, `ttlSecondsAfterFinished: 7d`, history 2 success / 3 failed.

## Bucket and layout

- Bucket `cluster-app-backups` (Standard tier, 14-day lifecycle), created by Terraform in another repo. **The bucket must exist before the first run**, otherwise every Job fails (alerts fire; nothing else breaks).
- Region `sa-vinhedo-1`, endpoint `https://axtvnrdemzo7.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com`.
- Key: `<namespace>/<app>/<UTC timestamp>.<ext>`, for example `hermes/hermes/20261118T051500Z.tar.gz`. Retention is 14 daily versions per app.

## Credentials (dedicated append-only key)

The Jobs use their own OCI user, not the sitio key: a Customer Secret Key inherits every Object Storage permission of its user, and the sitio key belongs to a tenancy administrator.

- Terraform (oracle-cluster, `app-backup-iam.tf`) creates user `oke-cluster-app-backup-writer` and group `oke-cluster-app-backup-writers`. The group may only `read buckets` and `OBJECT_CREATE` / `OBJECT_INSPECT` on `cluster-app-backups`: no read-back, no overwrite, no delete, no other bucket. The bucket's 14-day lifecycle rule does the expiry, so a leaked key cannot wipe the backups.
- The key is created out of band so its secret never lands in Terraform state. `scripts/seal-app-backup-credentials.sh <user-ocid>` creates it and pipes it straight into `kubeseal --scope cluster-wide`, writing `apps/app-backups/base/s3-credentials-sealed.yaml`. The user OCID is `terraform output -raw app_backup_writer_user_id` in oracle-cluster.
- Every app directory includes `../base`, so each namespace gets its own `app-backup-s3-credentials` Secret from the same ciphertext.
- Rotation: rerun the script, commit the new sealed file, then delete the old key in OCI.

Check after Argo CD syncs: `kubectl get secret app-backup-s3-credentials -n <ns>` exists in `platform`, `production` and `hermes` (do not print its data).

## Run a backup now

```bash
kubectl -n platform create job --from=cronjob/app-backup-pocketid pocketid-manual-1
kubectl -n platform logs -f job/pocketid-manual-1
```

Other CronJobs: `app-backup-tinyauth` (`platform`), `app-backup-home` (`production`), `app-backup-hermes` (`hermes`). A good run ends with `Uploaded s3://cluster-app-backups/... (N bytes)`. Manual Jobs are reaped by the 7-day TTL.

List objects from your workstation with your own OCI CLI profile: `oci os object list -bn cluster-app-backups --prefix <namespace>/<app>/ --query 'data[].name'`, or use the OCI Console. The Jobs' key cannot list or read objects back.

## Monitoring

PrometheusRule `app-backups` (in the kube-prometheus-stack values) keys on the CronJob name prefix `app-backup-`:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `AppBackupFailed` | a Job owned by an `app-backup-*` CronJob has failed for 5 min | critical |
| `AppBackupStale` | no successful run for more than 26 h, or never succeeded and the CronJob is older than 26 h | warning |

Both route to `slack-infra` via the `AppBackup.*` matcher.

## Restore

General rules:

- A restore overwrites live data. Confirm the object key first and take a fresh backup of the current state if it is still readable.
- Argo CD `selfHeal` reverts a manual scale to 0. Pause auto-sync on the app first, for example `kubectl -n argocd patch application <app> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`, and restore it (or let Argo re-apply from Git) at the end.
- Objects are in the Standard tier, so no rehydration is needed.
- Always remove stale `-wal` / `-shm` / `-journal` files before placing a restored SQLite file, otherwise SQLite replays old WAL frames over the restored data.

The backup key is write-only, so restores download with **your own** OCI CLI profile on your workstation and copy the file into a helper pod.

```bash
oci os object get -bn cluster-app-backups --name <key> --file ./backup.gz
```

Helper pod used by every restore (runs as root, mounts the PVC read-write, holds no credentials). Set `NS`, `PVC`:

```bash
NS=platform; PVC=platform-pocketid-data
kubectl -n "$NS" run backup-restore-helper --restart=Never \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "backup-restore-helper",
        "image": "public.ecr.aws/amazonlinux/amazonlinux:2023",
        "command": ["sh", "-ec", "dnf install -y -q sqlite gzip tar && sleep 3600"],
        "volumeMounts": [{"name": "data", "mountPath": "/data"}]
      }],
      "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "'"$PVC"'"}}]
    }
  }'
kubectl -n "$NS" cp ./backup.gz backup-restore-helper:/tmp/b.gz
```

Wait for the install (`kubectl -n "$NS" logs backup-restore-helper`, then `exec`). Delete the helper when done: `kubectl -n "$NS" delete pod backup-restore-helper`. Hermes uses the same pod with `NS`/`PVC` swapped.

Within the helper, a SQLite restore is always:

```bash
gunzip -c /tmp/b.gz > /tmp/restored.db
sqlite3 /tmp/restored.db "PRAGMA integrity_check;"      # must print ok
rm -f /data/<db>-wal /data/<db>-shm /data/<db>-journal
cp /tmp/restored.db /data/<db> && chown <uid>:<gid> /data/<db>
```

### pocketid (`platform`, uid 1000)

1. Pause auto-sync on `platform-pocketid`, then `kubectl -n platform scale deploy pocketid --replicas=0` and wait for the pod to go.
2. Start the helper (`PVC=platform-pocketid-data`), run the SQLite restore with `<db>` = `pocket-id.db`, owner `1000:1000`, key `platform/pocketid/<ts>.sqlite3.gz`.
3. Delete the helper, `kubectl -n platform scale deploy pocketid --replicas=1`, re-enable auto-sync. The deployment's `ENCRYPTION_KEY` Secret must be the one the backup was made with (it is in Git as a SealedSecret). Log in via OIDC to confirm.

### tinyauth (`platform`, owner root)

Same as pocketid with deployment `tinyauth`, `PVC=platform-tinyauth-data`, `<db>` = `tinyauth.db`, owner `0:0`, key `platform/tinyauth/<ts>.sqlite3.gz`, Application `platform-tinyauth`.

### home (`production` or `staging`, uid 1000)

1. Pause auto-sync on `production-home`, scale `deploy/home` to 0 in that namespace.
2. Helper with `PVC=home-sqlite`, restore into `<db>` = `production.sqlite3` (the file is named that in staging too), owner `1000:1000`, key `<namespace>/home/<ts>.sqlite3.gz`.
3. Scale `deploy/home` to 1, re-enable auto-sync, check `/up` and log in.

### hermes (`hermes`, uid 10000)

1. Pause auto-sync on the `hermes` Application, then `kubectl -n hermes scale deploy hermes --replicas=0` and wait for the pod to go (it has several containers mounting the PVC).
2. Helper with `PVC=hermes-data`. The restore overlays the archive on the existing data (caches that were not backed up stay, which is fine). For a clean disaster recovery into an empty PVC the same command works:

   ```bash
   mv /tmp/b.gz /tmp/h.tar.gz   # downloaded and copied in as above
   gzip -t /tmp/h.tar.gz
   cd /data
   find /data \( -name '*.db-wal' -o -name '*.db-shm' -o -name '*.db-journal' \
     -o -name '*.sqlite3-wal' -o -name '*.sqlite3-shm' \) -delete
   tar xzf /tmp/h.tar.gz -C /data
   chown -R 10000:10000 /data
   ```

   Note the data dir mode is `0700`; `chown -R` keeps the owner right, and `chmod 700 /data` if it was lost.
3. Delete the helper, `kubectl -n hermes scale deploy hermes --replicas=1`, re-enable auto-sync, check the pod logs and that sessions/memory are present.

## Troubleshooting

- `AccessDenied` / `NoSuchBucket` on upload: bucket not created yet, or the key's user lacks rights on `cluster-app-backups` (see Credentials).
- `secret "app-backup-s3-credentials" not found` (pod `CreateContainerConfigError`): the SealedSecret did not unseal. Check `kubectl -n <ns> describe sealedsecret app-backup-s3-credentials`; it must have been sealed with `--scope cluster-wide`.
- `AccessDenied` on upload: the IAM policy from `app-backup-iam.tf` is missing or not yet propagated, or the key belongs to another user.
- `could not take a stable copy`: the database was checkpointing continuously during the copy; re-run, and if it persists look at the app's write load at that hour.
- `integrity_check failed`: do not trust the source; investigate the live database and keep the previous night's object.
- OOMKilled during start-up: same cause and fix as [Resource sizing and OOM](sqlite-backup-runbook.md).
