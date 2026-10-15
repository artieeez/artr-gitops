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

## Blockers

_(none)_

## Deferred Ideas

_(none)_

## Lessons

- **2026-06-09:** ArgoCD `Synced/Healthy` does not mean TLS is valid. Monitor cert-manager runtime status and external probes separately.
- **2026-10-15:** A CronJob that installs its tools at runtime can break silently: `cert-audit` failed 3 weeks in a row with exit 127 because the script needed `openssl` but the image did not ship it. When a script runs in a minimal image, pin the runtime dependencies in the manifest (here `apk add --no-cache bash openssl`) and avoid GNU-only utilities such as `date -d`, which busybox does not support.
