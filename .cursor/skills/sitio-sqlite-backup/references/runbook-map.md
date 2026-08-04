# Sitio SQLite backup — runbook map

Load this file when executing verify, restore-prep, trigger, space, or prune workflows for concrete paths and commands. Canonical prose: `docs/sqlite-backup-runbook.md`.

## Inventory

| Resource | Staging | Production |
| --- | --- | --- |
| Namespace | `sitio-staging` | `sitio-production` |
| CronJob | `sitio-rails-sqlite-backup` | same name |
| Label | `app=sitio-rails-backup` | same |
| PVC (app data) | `sitio-rails-sqlite` | same claim name |
| Deployment | `sitio-rails` | same |
| Secret | `s3-credentials` | same |
| Argo Application | `sitio-staging-sitio-rails-backup` | `sitio-production-sitio-rails-backup` |
| Verify example YAML | `docs/examples/sitio-rails-sqlite-backup-verify-staging.yaml` | `docs/examples/sitio-rails-sqlite-backup-verify-production.yaml` |

## Object storage

| Item | Value |
| --- | --- |
| Bucket | `sitio-production-backups` |
| OCI namespace | `axtvnrdemzo7` |
| Region | `sa-vinhedo-1` |
| S3 endpoint | `https://axtvnrdemzo7.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com` |
| Key pattern | `{staging\|production}/sitio-rails/production-{YYYYMMDDTHHMMSSZ}.sqlite3.gz` |
| Tier | Archive (~1h restore before download) |
| Lifecycle | Delete after 90 days (bucket policy) |

## Runbook sections → actions

| Need | Runbook section |
| --- | --- |
| CronJob / upload success | How backups work |
| `oci os object restore` / head | Archive restore (~1 hour) |
| Verify Job apply + logs | Verify Job (integrity check only) |
| Scale-to-0 + PVC replace | Full restore (replace live database) |
| Free space / retention | Retention (end of runbook) |
| Drill checklist | Staging drill checklist |

## Handy commands

```bash
# Status
kubectl -n sitio-staging get cronjob,job,po -l app=sitio-rails-backup

# Trigger one-off backup
kubectl -n sitio-staging create job --from=cronjob/sitio-rails-sqlite-backup manual-backup-$(date +%s)

# List objects (space / prune candidates)
oci os object list --bucket-name sitio-production-backups --prefix staging/sitio-rails/ --all

# Archive restore
oci os object restore --bucket-name sitio-production-backups --name '<OBJECT_KEY>' --hours 24
oci os object head --bucket-name sitio-production-backups --name '<OBJECT_KEY>'
```

Delete only after the skill’s prune confirmation gate (user-specified set).
