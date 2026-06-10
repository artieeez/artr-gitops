# PostgreSQL Backup to OCI Object Storage — Specification

## Problem Statement

The `sitio-production` PostgreSQL database (single-instance Deployment, 20Gi NFS PVC) has no backup mechanism. If the PVC is deleted, corrupted, or the cluster lost, all application data is gone permanently. We need automated, off-cluster backups to OCI Object Storage (Archive tier) that cost almost nothing to store and can be recovered when needed.

## Goals

- [ ] Automated nightly `pg_dump` backup of the `sitio-production` `app` database to OCI Object Storage Archive tier
- [ ] DBA runbook covering recovery procedures and periodic health checks
- [ ] Cloud infrastructure prerequisites documented for the Terraform team
- [ ] Zero custom Docker images — uses publicly available, maintained images only

## Out of Scope

| Feature | Reason |
|---|---|
| Point-in-time recovery (WAL archiving) | Adds complexity (WAL shipping, base backups, restore tooling). Logical dumps satisfy RPO of ~24h for v1. |
| Backup encryption at rest (client-side) | OCI Object Storage already encrypts all data at rest by default. |
| Staging database backups | P3 — can be added later by copying manifests with different env values. |
| Monitoring/alerting on backup failures | P3 — can be added via ServiceMonitor later; CronJob history + manual checks for v1. |
| Automated restore testing | P3 — DBA runbook covers manual restore verification. |
| In-cluster local backup retention | Backups go directly to object storage. No local `/backups` PVC needed. |

---

## User Stories

### P1: Automated Nightly Backup to OCI Archive Storage ⭐ MVP

**User Story:** As a platform operator, I want the `sitio-production` PostgreSQL database backed up automatically every night to OCI Object Storage Archive tier, so that I can recover application data in case of data loss or corruption.

**Why P1:** This is the core deliverable. Without it, there is no backup at all. Archive tier keeps storage costs near zero (~$0.0014/GB/mo).

**Acceptance Criteria:**

1. WHEN the CronJob schedule triggers THEN the system SHALL execute `pg_dump -Fc` against `postgres.sitio-production.svc.cluster.local:5432` database `app` and upload the compressed dump to the configured OCI Object Storage bucket (Archive tier).
2. WHEN the backup completes successfully THEN the CronJob pod SHALL exit with code 0 and the dump object SHALL be visible in the OCI bucket with a name following the pattern `sitio_prod_app.<date>.dmp`.
3. WHEN the database is unreachable THEN the CronJob pod SHALL exit with non-zero status and the failed attempt SHALL be recorded in CronJob history.
4. WHEN deployed to the cluster THEN ArgoCD SHALL report the Application as `Healthy` and `Synced`.

**Independent Test:** Deploy the CronJob + OCI infra, wait for the schedule (or manually create a Job from the CronJob), verify a `.dmp` object appears in the OCI bucket.

---

### P2: DBA Runbook — Recovery & Health Checks

**User Story:** As a database administrator, I want a clear, step-by-step written guide explaining how to recover the database from a backup and how to periodically verify that backups are working, so that I can act quickly and confidently during an incident.

**Why P2:** Backups without a recovery procedure are worthless under pressure. Health checks catch silent failures before they become data loss.

**Acceptance Criteria:**

1. WHEN a DBA reads the runbook THEN they SHALL find a step-by-step recovery procedure covering: locating the latest backup in OCI, restoring it to a fresh PostgreSQL instance, and verifying data integrity.
2. WHEN a DBA reads the runbook THEN they SHALL find a periodic health check checklist including: verifying recent CronJob success, checking backup file size trends, and performing a restore dry-run.
3. WHEN the runbook references OCI Console or CLI operations THEN it SHALL include the exact commands/console paths — no assumed knowledge.

**Independent Test:** A team member unfamiliar with the backup system can follow the runbook to restore a backup to a fresh database and complete the health check checklist in under 30 minutes.

---

### P3: Backup Retention & Staging Coverage (Future)

**User Story:** As a platform operator, I want old backups automatically deleted after a configurable retention period and the staging database backed up on the same schedule.

**Why P3:** Retention prevents indefinite storage cost growth. Staging coverage mirrors production for pre-production disaster recovery testing. Both are deferred for v1.

**Acceptance Criteria:** (Defined when story is promoted to active)

---

## Edge Cases

- WHEN the backup pod runs out of memory (e.g., very large database) THEN the dump SHALL fail with a non-zero exit code and NOT upload a partial/corrupt file.
- WHEN the OCI Object Storage endpoint is unreachable THEN the CronJob SHALL fail (not silently skip the upload) and the error SHALL be visible in pod logs.
- WHEN two CronJob executions overlap (previous backup still running when next schedule fires) THEN the concurrencyPolicy (set to `Forbid`) SHALL skip the new execution.
- WHEN the database contains large objects (images, files) THEN the `DUMP_ARGS=-Fc` custom format SHALL compress them efficiently to minimize storage and transfer time.

---

## Requirement Traceability

| Requirement ID | Story | Description | Phase | Status |
|---|---|---|---|---|
| BACKUP-01 | P1 | CronJob YAML manifest with kartoza/pg-backup:16-3.6, scheduled nightly, connected to `postgres.sitio-production.svc.cluster.local:5432`, DB `app`, user `postgres`. Uses SealedSecret for DB password (reuses existing `postgres-sitio-production-auth`). | Specify | Pending |
| BACKUP-02 | P1 | SealedSecret for OCI Customer Secret Key (S3-compatible access/secret key pair). | Specify | Pending |
| BACKUP-03 | P1 | ConfigMap with `s3cfg` content configured for OCI S3-compatible endpoint (`<namespace>.compat.objectstorage.<region>.oci.customer-oci.com`), pointing to the backup bucket. | Specify | Pending |
| BACKUP-04 | P1 | ArgoCD Application manifest registering the backup resources under `sitio-production` parent app. | Specify | Pending |
| BACKUP-05 | P1 | OCI Object Storage bucket (`sitio-production-backups`) of type **Archive**, with a Customer Secret Key for programmatic S3-compatible access. | Cloud Infra | Pending |
| BACKUP-06 | P1 | OCI lifecycle policy on the backup bucket: delete objects older than 90 days (matching Archive minimum retention). | Cloud Infra | Pending |
| BACKUP-07 | P2 | `docs/pg-backup-runbook.md` — recovery procedure (locate backup, restore to fresh PG, verify) + periodic health check checklist (CronJob success, file sizes, restore dry-run). | Docs | Pending |
| BACKUP-08 | P1 | Cloud infrastructure requirements document (`cloud-infra-requirements.md`) for the Terraform team, specifying bucket properties, IAM policy, and Customer Secret Key setup. | Docs | Pending |

**Coverage:** 8 total, 8 mapped, 0 unmapped

---

## Success Criteria

- [ ] A `pg_dump -Fc` of the `app` database is uploaded to OCI Archive bucket every night at the configured time
- [ ] A team member can follow the runbook to recover the database from the latest backup in under 30 minutes
- [ ] Storage cost for backups is approximately $0.0014/GB/month (Archive tier)
- [ ] No custom Docker images were built — only `kartoza/pg-backup:16-3.6` from Docker Hub
