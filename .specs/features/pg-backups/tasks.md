# PostgreSQL Backup — Tasks

**Design:** `.specs/features/pg-backups/design.md`
**Status:** Draft

---

## Execution Plan

### Phase 1: Foundation

```
T1 (create dir)
  │
  ├── T2 (CronJob YAML) [P]
  ├── T3 (SealedSecret YAML) [P]
  ├── T4 (ArgoCD App YAML) [P]
  └── T5 (DBA Runbook) [P]
        │
        └── T6 (Lint & Validate)
```

All 4 file-creation tasks (T2–T5) are independent — different files, no shared logic. They run in parallel after T1.

---

## Task Breakdown

### T1: Create `postgres-backup/` directory

**What:** Create the directory that will hold all backup-related K8s manifests.
**Where:** `apps/sitio-production/postgres-backup/`
**Depends on:** None
**Reuses:** Same pattern as `apps/sitio-production/postgres/`, `apps/sitio-production/sitio-backend/` etc.
**Requirement:** BACKUP-01, BACKUP-02

**Tools:**
- MCP: NONE
- Skill: NONE

**Done when:**
- [ ] Directory `apps/sitio-production/postgres-backup/` exists

**Tests:** none (infrastructure)
**Gate:** none

---

### T2: Write `cronjob.yaml` [P]

**What:** Kubernetes CronJob manifest using `kartoza/pg-backup:16-3.6`. Connects to `postgres.sitio-production.svc.cluster.local:5432`, dumps DB `app` as user `postgres`, uploads to OCI S3-compatible Archive bucket. Scheduled daily at 6am UTC (3am BRT).
**Where:** `apps/sitio-production/postgres-backup/cronjob.yaml`
**Depends on:** T1
**Reuses:**
- DB credentials from existing Secret `postgres-sitio-production-auth` (key `password`)
- Env var pattern from `apps/sitio-production/postgres/deployment.yaml` (L26-35)
- Labels convention: `app: postgres-backup`, `environment: sitio-production`
**Requirement:** BACKUP-01

**Tools:**
- MCP: NONE
- Skill: NONE

**Done when:**
- [ ] CronJob YAML follows existing indentation/style conventions
- [ ] Uses image `kartoza/pg-backup:16-3.6`
- [ ] Env vars: POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_DB, POSTGRES_PASS (from secretRef), STORAGE_BACKEND=S3, RUN_ONCE=true, DUMP_ARGS=-Fc, DUMPPREFIX=sitio_prod, DBLIST=app
- [ ] S3 env vars: DEFAULT_REGION, HOST_BASE, HOST_BUCKET, SSL_SECURE, BUCKET (hardcoded per provisioned infra)
- [ ] S3 creds: ACCESS_KEY_ID, SECRET_ACCESS_KEY from `secretKeyRef` → `s3-credentials`
- [ ] schedule: `0 6 * * *`, concurrencyPolicy: Forbid, restartPolicy: OnFailure
- [ ] Resources: cpu 250m/500m, memory 256Mi/512Mi
- [ ] history limits: 3 successful, 3 failed
- [ ] Gate check passes: `yamllint -d relaxed .` (no new errors on this file)
- [ ] Gate check passes: `kubeconform` accepts the CronJob resource

**Tests:** none (YAML manifest)
**Gate:** `yamllint -d relaxed apps/sitio-production/postgres-backup/cronjob.yaml && kubeconform -summary -ignore-missing-schemas -kubernetes-version 1.30.0 apps/sitio-production/postgres-backup/cronjob.yaml`

---

### T3: Write `s3-credentials-sealed.yaml` [P]

**What:** SealedSecret manifest (placeholder) for the OCI Customer Secret Key pair. Contains the SealedSecret envelope; the operator fills in the encrypted values using `kubeseal`.
**Where:** `apps/sitio-production/postgres-backup/s3-credentials-sealed.yaml`
**Depends on:** T1
**Reuses:** SealedSecret pattern from `apps/sitio-production/postgres/postgres-sitio-production-auth-sealed.yaml`
**Requirement:** BACKUP-02

**Tools:**
- MCP: NONE
- Skill: NONE

**Done when:**
- [ ] SealedSecret with name `s3-credentials` in namespace `sitio-production`
- [ ] `encryptedData` has keys: `access-key-id`, `secret-access-key`
- [ ] Template includes documented instructions for sealing with kubeseal
- [ ] Gate check passes: `yamllint` (no errors)

**Tests:** none (YAML manifest)
**Gate:** `yamllint -d relaxed apps/sitio-production/postgres-backup/s3-credentials-sealed.yaml`

**Operator instructions (to be placed as YAML comment in the file):**
```bash
# 1. Create a temporary plain Secret:
kubectl create secret generic s3-credentials \
  --namespace sitio-production \
  --from-literal=access-key-id='<ACCESS_KEY>' \
  --from-literal=secret-access-key='<SECRET_KEY>' \
  --dry-run=client -o yaml > /tmp/s3-credentials.yaml

# 2. Seal it:
kubeseal --format=yaml --cert=<path-to-cert> \
  < /tmp/s3-credentials.yaml > apps/sitio-production/postgres-backup/s3-credentials-sealed.yaml

# 3. Delete temp file:
rm /tmp/s3-credentials.yaml
```

---

### T4: Write ArgoCD Application manifest [P]

**What:** ArgoCD leaf Application manifest registering the backup CronJob under the `artr-sitio-production` parent app.
**Where:** `argocd/applications/sitio-production/sitio-production-postgres-backup.yaml`
**Depends on:** T1
**Reuses:** Exact copy of `argocd/applications/sitio-production/sitio-production-postgres.yaml` template, with name/path changed.
**Requirement:** BACKUP-04

**Tools:**
- MCP: NONE
- Skill: NONE

**Done when:**
- [ ] `metadata.name: sitio-production-postgres-backup`
- [ ] `spec.source.path: apps/sitio-production/postgres-backup`
- [ ] `spec.destination.namespace: sitio-production`
- [ ] syncPolicy matches all other leaf apps (automated, prune, selfHeal, retry 5x)
- [ ] Gate check passes: `yamllint` (no errors)
- [ ] Gate check passes: `kubeconform` accepts the Application CRD (may skip schema — expected)

**Tests:** none (YAML manifest)
**Gate:** `yamllint -d relaxed argocd/applications/sitio-production/sitio-production-postgres-backup.yaml`

---

### T5: Write DBA Runbook [P]

**What:** Markdown guide for database administrators covering recovery procedures and periodic health checks.
**Where:** `docs/pg-backup-runbook.md`
**Depends on:** T1 (conceptual — references the CronJob name and bucket name from design)
**Reuses:** References patterns from `docs/sealed-secrets.md`, `docs/quick-start.md`
**Requirement:** BACKUP-07

**Tools:**
- MCP: NONE
- Skill: NONE

**Done when:**
- [ ] Section 1: Recovery procedure — locate latest backup in OCI bucket, download, restore to fresh PG, verify data
- [ ] Section 2: Health check checklist — verify recent CronJob success, check file size trends, perform restore dry-run
- [ ] Commands include exact `kubectl`, `oci` CLI, and `pg_restore` invocations
- [ ] Gate check: `shellcheck` (N/A — markdown) — manual review only

**Tests:** none (documentation)
**Gate:** Manual review — no automated validation for markdown docs.

---

### T6: Lint & Validate All New Manifests

**What:** Run repo-level linting and K8s manifest validation on all new files.
**Where:** N/A (validation task)
**Depends on:** T2, T3, T4
**Reuses:** Validation commands from `AGENTS.md`

**Tools:**
- MCP: NONE
- Skill: NONE

**Done when:**
- [ ] `yamllint -d relaxed apps/sitio-production/postgres-backup/` passes (no new errors)
- [ ] `yamllint -d relaxed argocd/applications/sitio-production/sitio-production-postgres-backup.yaml` passes
- [ ] `kubeconform -summary -ignore-missing-schemas -kubernetes-version 1.30.0 apps/sitio-production/postgres-backup/cronjob.yaml` accepts the CronJob
- [ ] ArgoCD Application and SealedSecret CRDs may be skipped by kubeconform (expected — no schema available)

**Tests:** none (validation)
**Gate:** full YAML lint + kubeconform as specified in AGENTS.md

---

## Parallel Execution Map

```
Phase 1:
  T1

Phase 2 (all parallel after T1):
  ├── T2 [P]
  ├── T3 [P]
  ├── T4 [P]
  └── T5 [P]

Phase 3:
  T2, T3, T4 complete → T6
```

---

## Task Granularity Check

| Task | Scope | Status |
|---|---|---|
| T1: Create directory | 1 mkdir | ✅ Granular |
| T2: CronJob YAML | 1 file, 1 resource | ✅ Granular |
| T3: SealedSecret YAML | 1 file, 1 resource | ✅ Granular |
| T4: ArgoCD App YAML | 1 file, 1 resource | ✅ Granular |
| T5: DBA Runbook | 1 file, docs | ✅ Granular |
| T6: Lint & Validate | 1 validation pass | ✅ Granular |

---

## Diagram-Definition Cross-Check

| Task | Depends On (body) | Diagram Shows | Status |
|---|---|---|---|
| T1 | None | None → T1 | ✅ Match |
| T2 | T1 | T1 → T2 | ✅ Match |
| T3 | T1 | T1 → T3 | ✅ Match |
| T4 | T1 | T1 → T4 | ✅ Match |
| T5 | T1 | T1 → T5 | ✅ Match |
| T6 | T2, T3, T4 | T2, T3, T4 → T6 | ✅ Match |

---

## Test Co-location Validation

**Note:** This repo has no application code, no test framework, and no TESTING.md. The "tests" column is `none` for all tasks. Validation is done via `yamllint` + `kubeconform` (T6).

| Task | Layer | Matrix Requires | Task Says | Status |
|---|---|---|---|---|
| T1 | Infrastructure | N/A | none | ✅ N/A |
| T2 | YAML manifest | N/A | none | ✅ N/A |
| T3 | YAML manifest | N/A | none | ✅ N/A |
| T4 | YAML manifest | N/A | none | ✅ N/A |
| T5 | Documentation | N/A | none | ✅ N/A |
| T6 | Validation | N/A | none | ✅ N/A |
