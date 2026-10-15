# Project State

## Active Features

| Feature | Phase | Status |
| --- | --- | --- |
| pg-backups | Specify | In progress — spec written, awaiting approval |
| cert-monitoring | Execute | Complete — alerts, blackbox probes, runbook, audit script, Grafana dashboard, weekly CronJob |

## Decisions

- **2026-06-10:** Certificate monitoring uses cert-manager ServiceMonitor + PrometheusRules in kube-prometheus-stack, plus blackbox exporter for externally-visible TLS expiry. Alertmanager Slack receiver configured via SealedSecret `alertmanager-slack-webhook` (cert/TLS alerts only).
- **2026-06-10:** Certificate expiry alert threshold set to 21 days (cert-manager) and 7 days (blackbox served cert) per postmortem recommendations.
- **2026-06-10:** Weekly cert audit CronJob runs Mondays 09:00 UTC; ConfigMap mirrors `scripts/audit-tls-secrets.sh` (regenerate ConfigMap when script changes).
- **2026-10-15:** `cert-audit` fixed: the CronJob now installs `openssl` via `apk add --no-cache bash openssl` (the `alpine/k8s` image lacks it, so the script died with exit 127), and the audit checks the 21-day threshold with `openssl x509 -checkend` instead of converting `notAfter` to epoch with `date -d` (busybox `date` cannot parse openssl's date format). Source-vs-copy drift is compared by SHA-256 fingerprint, which also catches a re-issue that keeps the same `notAfter`.
  Regenerate the ConfigMap after editing the script with:

  ```sh
  {
    echo '# Generated from scripts/audit-tls-secrets.sh — regenerate when the script changes.'
    echo 'apiVersion: v1'
    echo 'data:'
    echo '  audit-tls-secrets.sh: |'
    sed '/./s/^/    /' scripts/audit-tls-secrets.sh
    echo 'kind: ConfigMap'
    echo 'metadata:'
    echo '  name: cert-audit-script'
    echo '  namespace: monitoring'
    echo '  labels:'
    echo '    app: cert-audit'
  } > apps/monitoring/cert-audit/configmap.yaml
  ```

- **2026-10-15:** The Sitio SQLite backup CronJobs were OOMKilled (exit 137) in `sitio-staging` on 2026-10-12 and 2026-10-14, ~30 s into the run, during the start-up `dnf install -y -q sqlite awscli gzip` — not during the backup. Prometheus shows 357–429 MiB working set (RSS up to 409 MiB) for _successful_ runs too, against a `512Mi` limit, while the DB is 312 KiB (staging) / 36 MiB (production) and the backup phase drops to ~105 MiB. Fix: both CronJobs now run `requests.memory: 512Mi` / `limits.memory: 1Gi`, and the schedules are staggered (staging `30 6 * * *`, production unchanged at `0 6 * * *` UTC) so the two Jobs never install packages simultaneously on the single node. On 2026-10-14 staging ran alone with ~3.2 GiB node memory free and still died, so the container's own limit was the cause.
- **2026-10-15:** The durable fix for that OOM is a prebuilt backup image with `sqlite` + `awscli` + `gzip` baked in (seconds instead of 1–2 minutes, ~100 MiB instead of ~430 MiB, and no 128–516 MiB of node-disk writes per run at the DiskPressure-prone 06:00 minute). It must be built in `artieeez/sitio-rails`, which holds `OCIR_USERNAME`/`OCIR_AUTH_TOKEN`; `artr-gitops` has no Actions secrets and CI/CD pipelines are explicitly out of scope for this repo. Recipe: `docs/sqlite-backup-runbook.md` → **Resource sizing and OOM**.

## Blockers

_(none)_

## Deferred Ideas

- Prebuild the backup tooling image (`sitio-backup` in OCIR, built from `artieeez/sitio-rails`) and drop the CronJobs' `dnf install` step — recipe in `docs/sqlite-backup-runbook.md` → **Resource sizing and OOM**.
- Node `10.0.1.226` root filesystem sits ~83% full, and every backup run writes 128–516 MiB into its container layer; a `DiskPressure` eviction failed the 2026-10-10 backup. Investigate node disk reclaim (image GC, logs) separately from the backup fix.
- Swap `awscli` for `curl --aws-sigv4` (one package instead of ~40) — only worth it inside the prebuilt image, and it needs a validated staging drill before it can be trusted for uploads.

## Lessons

- **2026-06-09:** ArgoCD `Synced/Healthy` does not mean TLS is valid. Monitor cert-manager runtime status and external probes separately.
- **2026-10-15:** A CronJob that installs its tools at runtime can break silently: `cert-audit` failed 3 weeks in a row with exit 127 because the script needed `openssl` but the image did not ship it. When a script runs in a minimal image, pin the runtime dependencies in the manifest (here `apk add --no-cache bash openssl`) and avoid GNU-only utilities such as `date -d`, which busybox does not support.
- **2026-10-15:** The same anti-pattern bit the SQLite backup: a critical alert fired for three separate days because the _tooling install_, not the data, exceeded the memory limit. Size a job's memory limit against its setup phase, and read the per-phase timeline (`container_memory_rss` 409 MiB during `dnf` → ~105 MiB during the backup) instead of only the job's total peak. "The backup is too big" was the intuitive-but-wrong hypothesis; the DB was 312 KiB.
- **2026-10-15:** Two CronJobs scheduled in the same minute on a single node is a correlated-failure design. Stagger them.
