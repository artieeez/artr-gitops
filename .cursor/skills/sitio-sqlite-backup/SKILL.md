---
name: sitio-sqlite-backup
description: Operate Sitio Rails SQLite backups on artr (OCI bucket sitio-production-backups + CronJobs): check status and space usage, run a backup now, verify integrity, prune objects only when the user specifies what to delete, and prepare staging or production restore drills. Use when asked about sitio sqlite backup, backup space, verify backup, clear/prune/delete backups, restore staging/production from backup, or Archive restore. Requires artr-platform-ops installed. Do NOT use for general cluster diagnosis, Terraform, non-Sitio apps, or editing GitOps manifests unless the user asks for a backup-ops fix.
license: CC-BY-4.0
metadata:
  author: arturwebber
  version: 1.0.0
---

# sitio-sqlite-backup

Run Sitio Rails SQLite backup operations against the live artr cluster and OCI bucket. Prefer evidence over guesswork. Compose with **artr-platform-ops** for kube context, Argo health, and Job/pod logs.

## Hard requirements

1. **Require `artr-platform-ops`.** If that skill is not available in this session/repo skill list, STOP and tell the user to install it (e.g. ensure `artr-platform-ops` is present under Cursor skills). Do not reinvent cluster bootstrap or pretend kubectl succeeded.
2. **Read-only by default.** Listing CronJobs, objects, and sizes is fine. Do not create Jobs, restore Archive objects, delete OCI objects, scale Deployments, or replace PVC files unless the user explicitly asks for that action.
3. **Prune is never implicit.** Never invent an age threshold or “delete everything old.” The user must specify env (`staging` / `production` / both) **and** what to delete (exact object key(s), or “older than N days”, or a listed candidate set they approved). If unspecified → ask; do not delete.
4. **Production restore is gated.** Preparing a production restore checklist is OK; mutating production requires the user to name `production` and confirm. Prefer staging drills first.
5. **Never print S3 secret values.** Confirm Secret exists; do not dump key material into chat.

When about to run concrete commands, read `references/runbook-map.md` for bucket/prefix/paths and example Job manifests. For cluster reachability / wrong context, follow **artr-platform-ops** (default context `oracle-cluster`).

## Constants (do not guess otherwise)

| Item | Value |
| --- | --- |
| Bucket | `sitio-production-backups` |
| Namespace staging | `sitio-staging` |
| Namespace production | `sitio-production` |
| CronJob | `sitio-rails-sqlite-backup` |
| Key prefix | `{env}/sitio-rails/` |
| Image | `docker.io/amazon/aws-cli:2.27.25` (always FQDN) |
| Runbook | `docs/sqlite-backup-runbook.md` |
| Argo apps | `sitio-staging-sitio-rails-backup`, `sitio-production-sitio-rails-backup` |

## Command router

Match the user intent, then run the matching workflow:

| Intent | Workflow |
| --- | --- |
| Status / did backup run / Job failed | **Status** |
| How much space / list backups | **Space** |
| Run backup now | **Trigger backup** |
| Verify backup / integrity_check | **Verify** |
| Clear / prune / delete backups | **Prune** (specified only) |
| Prepare restore / apply backup staging or production | **Prepare restore** |
| Ambiguous “backup” | Ask which of the above |

## Workflows

### Status

1. Orient via artr-platform-ops (context `oracle-cluster`).
2. Check Argo app for the env’s backup leaf if sync is in doubt.
3. `kubectl -n <ns> get cronjob,job,po -l app=sitio-rails-backup`
4. Logs on the latest Job pod; successful backup ends with `Uploaded s3://sitio-production-backups/...`
5. Report: last schedule, latest Job result, one next dig.

### Space

1. List objects under the env prefix(es) the user cares about (default: ask staging vs production vs both if unclear).
2. Prefer OCI CLI against the known bucket/namespace, e.g. `oci os object list --bucket-name sitio-production-backups --prefix staging/sitio-rails/` (and/or production). Sum sizes; show count + largest/newest keys.
3. Note Archive tier and 90-day lifecycle (auto-delete) — skill prune is **extra**, only when specified.
4. Report human-readable totals (MiB/GiB) + object count per prefix.

### Trigger backup

Only if the user asks to run one now:

1. Confirm env namespace.
2. `kubectl -n <ns> create job --from=cronjob/sitio-rails-sqlite-backup manual-backup-<unix-ts>`
3. Follow logs until success or failure.
4. On `ImageInspectError` / short-name errors: remind image must be `docker.io/amazon/aws-cli:...` (already in manifests on main).

### Verify

1. Confirm env + **OBJECT_KEY** (or help pick newest after Space).
2. Remind Archive: object must be Restored (~1h) before download — offer `oci os object restore` / head for `archival-state`.
3. Edit/apply the example Job (not Argo-managed):
   - Staging: `docs/examples/sitio-rails-sqlite-backup-verify-staging.yaml`
   - Production: `docs/examples/sitio-rails-sqlite-backup-verify-production.yaml`
4. Set `OBJECT_KEY`; rename Job if one already exists; `kubectl apply -f ...`; stream logs.
5. Success: `OK: integrity_check passed`. Failure: check Archive state, credentials Secret `s3-credentials`, key typo.

### Prune (delete older backups)

1. **Refuse** if the user did not specify what to delete. Ask for: env prefix(es) + either exact keys, or “older than N days”, or approve a candidate list you printed.
2. List matching objects and total bytes to free. Show the exact delete set.
3. Require explicit confirmation naming the env (e.g. “yes, delete these staging objects older than 45 days”).
4. Delete only that set (`oci os object delete` / bulk as appropriate). Re-list to confirm.
5. Never delete the other env’s prefix by accident. Never delete the live PVC database.

### Prepare restore

Guided checklist — do not skip Archive restore or integrity verify unless the user waives verify knowingly.

1. Confirm **staging** or **production**. Production: restate risk; wait for clear go-ahead before any scale/replace.
2. Steps (point at runbook sections via `references/runbook-map.md`):
   - Pick object key → Archive restore → wait Restored
   - Verify Job (recommended)
   - Scale `sitio-rails` Deployment to 0
   - Helper pod with PVC → replace `/rails/storage/production.sqlite3`
   - Scale up → `/up` + login smoke
3. Offer to run each mutating step only when asked (“scale staging to 0 now”). Between steps, re-check pod/Job state via artr-platform-ops patterns.
4. After a staging drill, remind recording results in sitio-rails `.specs/features/sqlite-backup/validation.md` if that repo is available.

## Examples

### Example 1: Space

User: "how much space are my sitio backups taking?"

1. Ask staging, production, or both if not said; or list both briefly.
2. `oci os object list` per prefix; sum sizes.
3. Report: `staging: N objects, X MiB; production: …` + newest key each.

### Example 2: Verify

User: "verify the latest staging backup"

1. List newest `staging/sitio-rails/` key.
2. Ensure Archive Restored (restore + poll if needed — only if user wants you to run restore).
3. Apply staging verify example with that `OBJECT_KEY`; report integrity_check.

### Example 3: Prune specified

User: "delete staging backups older than 14 days"

1. List candidates older than 14 days under `staging/sitio-rails/`; show count + bytes.
2. Wait for “yes, delete those”.
3. Delete only that set; confirm space freed.

### Example 4: Prepare staging restore

User: "help me prepare to apply a backup in staging"

1. Do **not** scale yet.
2. Walk checklist: pick key → Archive → verify → then ask before scale-to-0 / replace.
3. Keep production out of scope unless they switch.

## Troubleshooting

### Error: short name / ImageInspectError on aws-cli

Cause: cri-o short_name_mode rejects `amazon/aws-cli` without registry.
Solution: Image must be `docker.io/amazon/aws-cli:2.27.25`. Check CronJob/verify manifests on `main`.

### Error: download fails / NotRestored

Cause: Archive object not rehydrated.
Solution: `oci os object restore` then wait; poll head for Restored before verify Job.

### Error: artr-platform-ops missing

Cause: Skill not installed for this agent.
Solution: Stop; tell user to install/enable `artr-platform-ops`; do not fake cluster output.

### Error: prune request with no age/keys

Cause: User said “clear backups” without specifying.
Solution: Ask for env + older-than N days or exact keys; list candidates; confirm before delete.
