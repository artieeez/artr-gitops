# Project State

## Active Features

| Feature | Phase | Status |
|---|---|---|
| pg-backups | Specify | In progress — spec written, awaiting approval |
| cert-monitoring | Execute | Complete — alerts, blackbox probes, runbook, audit script, Grafana dashboard, weekly CronJob |

## Decisions

- **2026-06-10:** Certificate monitoring uses cert-manager ServiceMonitor + PrometheusRules in kube-prometheus-stack, plus blackbox exporter for externally-visible TLS expiry. Alertmanager Slack receiver configured via SealedSecret `alertmanager-slack-webhook` (cert/TLS alerts only).
- **2026-06-10:** Certificate expiry alert threshold set to 21 days (cert-manager) and 7 days (blackbox served cert) per postmortem recommendations.
- **2026-06-10:** Weekly cert audit CronJob runs Mondays 09:00 UTC; ConfigMap mirrors `scripts/audit-tls-secrets.sh` (regenerate ConfigMap when script changes).

## Blockers

_(none)_

## Deferred Ideas

_(none)_

## Lessons

- **2026-06-09:** ArgoCD `Synced/Healthy` does not mean TLS is valid. Monitor cert-manager runtime status and external probes separately.
