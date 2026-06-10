# Project State

## Active Features

| Feature | Phase | Status |
|---|---|---|
| pg-backups | Specify | In progress — spec written, awaiting approval |
| cert-monitoring | Execute | Complete — alerts, blackbox probes, runbook, audit script |

## Decisions

- **2026-06-10:** Certificate monitoring uses cert-manager ServiceMonitor + PrometheusRules in kube-prometheus-stack, plus blackbox exporter for externally-visible TLS expiry. Alertmanager notification channel deferred (no webhook configured yet).
- **2026-06-10:** Certificate expiry alert threshold set to 21 days (cert-manager) and 7 days (blackbox served cert) per postmortem recommendations.

## Blockers

_(none)_

## Deferred Ideas

- Alertmanager Slack/email receiver (needs webhook URL)
- Grafana cert-manager dashboard (P2 from postmortem)
- Weekly CronJob running `scripts/audit-tls-secrets.sh`

## Lessons

- **2026-06-09:** ArgoCD `Synced/Healthy` does not mean TLS is valid. Monitor cert-manager runtime status and external probes separately.
