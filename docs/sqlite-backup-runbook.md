# SQLite Backup Runbook

Operational guide for Sitio Rails nightly SQLite backups to OCI Object Storage and restore procedures.

**Related:** [ADR-006](https://github.com/artieeez/sitio-rails/blob/main/docs/adr/0006-sqlite-backup-to-oci-object-storage.md) · GitOps manifests: `apps/sitio-{staging,production}/sitio-rails-backup/`

---

## How backups work

| Item | Value |
| --- | --- |
| Schedule | `0 6 * * *` UTC (03:00 America/São Paulo) |
| CronJob | `sitio-rails-sqlite-backup` in `sitio-staging` / `sitio-production` |
| Mechanism | `VACUUM INTO` → gzip → `aws s3 cp` to OCI S3-compatible endpoint |
| Bucket | `sitio-production-backups` (Archive tier) |
| Object key pattern | `{staging\|production}/sitio-rails/production-{YYYYMMDDTHHMMSSZ}.sqlite3.gz` |
| AWS CLI / OCI | Scripts set `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` (and response validation) so PutObject does not use aws-chunked encoding, which OCI rejects |
| Example key | `staging/sitio-rails/production-20260803T060000Z.sqlite3.gz` |
| Retention | 90-day lifecycle rule on the bucket (objects auto-deleted after 90 days) |
| Credentials | SealedSecret `s3-credentials` per namespace (Customer Secret Key) |

Both environments share the same bucket; prefixes `staging/` and `production/` isolate objects.

**Verify a CronJob ran:**

```bash
kubectl -n sitio-staging get cronjob sitio-rails-sqlite-backup
kubectl -n sitio-staging get jobs -l app=sitio-rails-backup --sort-by=.metadata.creationTimestamp
kubectl -n sitio-staging logs job/<job-name>
```

Successful backup logs end with `Uploaded s3://sitio-production-backups/...`.

---

## Archive restore (~1 hour)

Objects in the Archive tier are not immediately downloadable. Rehydrate before verify or full restore.

### OCI Console

1. Open **Object Storage** → bucket `sitio-production-backups`.
2. Locate the object (prefix `staging/` or `production/`).
3. **Restore** the object (Standard tier, 24-hour download window).
4. Wait until status shows **Restored** (typically ~1 hour).

### OCI CLI

```bash
oci os object restore \
  --bucket-name sitio-production-backups \
  --name staging/sitio-rails/production-20260803T060000Z.sqlite3.gz \
  --hours 24
```

Replace `--name` with the full object key. Poll until restore completes:

```bash
oci os object head \
  --bucket-name sitio-production-backups \
  --name staging/sitio-rails/production-20260803T060000Z.sqlite3.gz
```

Look for `"archival-state": "Restored"` in the output.

---

## Verify Job (integrity check only)

The verify Job downloads a restored object and runs `PRAGMA integrity_check`. It **does not** mount the app PVC and cannot overwrite the live database.

1. Ensure the object is restored (previous section).
2. Edit the example manifest for your environment (not synced by Argo CD):
   - Staging: `docs/examples/sitio-rails-sqlite-backup-verify-staging.yaml`
   - Production: `docs/examples/sitio-rails-sqlite-backup-verify-production.yaml`
   - Set `OBJECT_KEY` to the full key (e.g. `staging/sitio-rails/staging-20260803T060000Z.sqlite3.gz`).
   - Optionally rename `metadata.name` if a prior verify Job exists.
3. Apply:

```bash
kubectl apply -f docs/examples/sitio-rails-sqlite-backup-verify-staging.yaml
kubectl -n sitio-staging logs -f job/sitio-rails-sqlite-backup-verify
# Production: kubectl apply -f docs/examples/sitio-rails-sqlite-backup-verify-production.yaml
```

Expected success: `OK: integrity_check passed for s3://sitio-production-backups/...`

On failure, check restore status, credentials, and object key before retrying.

---

## Full restore (replace live database)

Use only when recovering from data loss or a deliberate staging drill. **Production restores require explicit approval.**

### Prerequisites

- Verified backup object (verify Job passed).
- Object restored from Archive.
- kubectl access to the target namespace.

### Steps

1. **Scale Rails to zero** (releases PVC for exclusive write):

```bash
kubectl -n sitio-staging scale deployment sitio-rails --replicas=0
kubectl -n sitio-staging wait --for=delete pod -l app=sitio-rails --timeout=120s
```

2. **Download backup locally or into a helper pod** mounting the PVC:

```bash
# Option A: helper pod (recommended)
kubectl -n sitio-staging run sqlite-restore-helper \
  --restart=Never \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{
    "spec": {
      "securityContext": {"fsGroup": 1000},
      "containers": [{
        "name": "sqlite-restore-helper",
        "image": "public.ecr.aws/amazonlinux/amazonlinux:2023",
        "command": ["sh", "-ec", "dnf install -y -q sqlite awscli gzip && sleep 3600"],
        "volumeMounts": [{"name": "data", "mountPath": "/rails/storage"}],
        "env": [
          {"name": "AWS_DEFAULT_REGION", "value": "sa-vinhedo-1"},
          {"name": "AWS_ENDPOINT_URL", "value": "https://axtvnrdemzo7.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com"}
        ],
        "envFrom": [{"secretRef": {"name": "s3-credentials"}}]
      }],
      "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "sitio-rails-sqlite"}}]
    }
  }'
```

3. **Copy and decompress into the PVC** (exec into helper pod):

```bash
kubectl -n sitio-staging exec -it sqlite-restore-helper -- sh -c '
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  aws s3 cp s3://sitio-production-backups/staging/sitio-rails/production-REPLACE.sqlite3.gz /tmp/backup.gz &&
  gunzip -c /tmp/backup.gz > /rails/storage/production.sqlite3 &&
  sqlite3 /rails/storage/production.sqlite3 "PRAGMA integrity_check;"
'
```

4. **Remove helper pod and scale Rails back up:**

```bash
kubectl -n sitio-staging delete pod sqlite-restore-helper
kubectl -n sitio-staging scale deployment sitio-rails --replicas=1
kubectl -n sitio-staging rollout status deployment sitio-rails
```

5. **Smoke test:**

   - Hit `/up` (health check).
   - Log in and confirm expected data is present.

For **production**, replace `sitio-staging` with `sitio-production` and use a `production/` object key.

---

## Free space for VACUUM INTO

`VACUUM INTO` writes a full copy of the database to temp storage before gzip. During the nightly backup Job:

- Temp files live on the Job's `emptyDir` (`/tmp`), not on the PVC.
- The PVC is mounted **read-only** for backup; the live DB file is not modified.
- If the database grows large, ensure the Job's emptyDir and node disk can hold ~1× DB size (512Mi limit on the container may need raising for very large DBs).

Monitor PVC usage separately — full restore writes directly to the PVC and needs enough free space for the decompressed file.

Current PVC size: **10Gi** (`sitio-rails-sqlite`).

---

## Staging drill checklist

Record each drill in `sitio-rails/.specs/features/sqlite-backup/validation.md`.

| Field | Value |
| --- | --- |
| Date | _YYYY-MM-DD_ |
| Operator | _name_ |
| Object key | _e.g. staging/sitio-rails/production-20260803T060000Z.sqlite3.gz_ |
| Archive restore | ☐ Started ☐ Complete (~1h) |
| Verify Job | ☐ Pass ☐ Fail |
| Full restore (optional) | ☐ Pass ☐ Fail ☐ Skipped |
| Notes | _errors, timing, follow-ups_ |

**Recommended cadence:** at least once per quarter, or after any backup manifest change.

---

## Retention (90 days)

Bucket `sitio-production-backups` has an OCI lifecycle policy that deletes objects after **90 days**. Older backups are not recoverable unless copied elsewhere.

Confirm lifecycle is active in OCI Console → bucket → **Lifecycle Policy**, or via Terraform in `oracle-cluster` if provisioned there.

---

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| CronJob Job failed immediately | Missing/invalid SealedSecret | Reseal `s3-credentials`; check ArgoCD sync |
| `source database not found` | PVC not mounted or wrong path | Confirm `sitio-rails-sqlite` PVC exists and Rails has written DB |
| S3 upload error | Network, credentials, or bucket policy | Check Job logs; verify Customer Secret Key scope |
| Verify Job download fails | Object still in Archive | Run `oci os object restore` first |
| `integrity_check` ≠ ok | Corrupt backup or incomplete download | Do not restore; pick a different object |
| Backup skipped | Prior Job still running (`Forbid`) | Check for stuck Jobs; delete if safe |

---

## SealedSecret setup (one-time per namespace)

See comments in `s3-credentials-sealed.yaml` for each environment. Never commit plaintext keys.

```bash
kubectl create secret generic s3-credentials \
  --namespace sitio-staging \
  --from-literal=access-key-id='<ACCESS_KEY>' \
  --from-literal=secret-access-key='<SECRET_KEY>' \
  --dry-run=client -o yaml > /tmp/s3-credentials.yaml

kubeseal --format=yaml --cert=<path-to-sealed-secrets-cert> \
  < /tmp/s3-credentials.yaml \
  > apps/sitio-staging/sitio-rails-backup/s3-credentials-sealed.yaml

rm /tmp/s3-credentials.yaml
```

Repeat for `sitio-production`. Commit the sealed YAML and let ArgoCD sync.
