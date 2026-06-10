# Certificate Monitoring & Runbooks — Specification

**Source:** [Postmortem 2026-06](../../../docs/postmortems/2026-06-certificate-expiry.md)  
**Scope:** P0 + selected P1 action items

## Problem Statement

Cluster-wide TLS failure went undetected for 84 days because cert-manager renewal failures and certificate expiry had no automated monitoring, and operational runbooks were incomplete.

## Goals

- [ ] Alert operators before certificates expire or when cert-manager cannot renew
- [ ] Externally verify TLS served to users (not just cert-manager CR status)
- [ ] Document full certificate lifecycle: rotation, troubleshooting, Reflector hygiene
- [ ] Provide audit script for TLS secret propagation

## Out of Scope

| Item | Reason |
|---|---|
| Alertmanager Slack/email receiver | Requires user-provided webhook credentials — deferred; alerts visible in Alertmanager UI |
| Grafana cert-manager dashboard | P2 — follow-up feature |
| Weekly CronJob cert audit | P2 — script provided for manual/CI use first |
| Cloudflare calendar reminder | Process documented in runbook only |

---

## Requirements

### CERT-MON-001: cert-manager Prometheus metrics ⭐ P0

**Acceptance criteria:**
1. cert-manager controller exposes metrics via ServiceMonitor scraped by kube-prometheus-stack
2. ServiceMonitor carries `release: monitoring-kube-prometheus-stack` label for discovery

### CERT-MON-002: cert-manager PrometheusRule alerts ⭐ P0

**Acceptance criteria:**
1. WHEN a Certificate is `Ready=False` for >15m THEN Alertmanager fires `CertManagerCertificateNotReady` (critical)
2. WHEN a Certificate expires within 21 days THEN Alertmanager fires `CertManagerCertificateExpirySoon` (warning)

### CERT-MON-003: Blackbox TLS probes ⭐ P0

**Acceptance criteria:**
1. Blackbox exporter probes `https://argo.artr.com.br`, `https://grafana.artr.com.br`, `https://sitio.artr.com.br` every 60s
2. WHEN probe fails for >5m THEN `TlsProbeFailed` alert fires (critical)
3. WHEN served cert expires within 7 days THEN `TlsCertificateExpirySoon` alert fires (critical)

### CERT-MON-004: Certificate runbook ⭐ P0

**Acceptance criteria:**
1. Runbook covers: token rotation, verification, ACME unstick, Reflector propagation, openssl checks
2. Post-rotation checklist included
3. `change-cloud-flare-token.md` links to full runbook

### CERT-MON-005: TLS secret audit script — P1

**Acceptance criteria:**
1. Script checks all namespaces for `wildcard-artr-com-br-tls` reflector annotations vs orphan cert-manager secrets
2. Exits non-zero when orphans or missing secrets found
3. Passes shellcheck

### CERT-MON-006: Reflector architecture documentation — P1

**Acceptance criteria:**
1. AGENTS.md documents single-source TLS secret pattern and Reflector constraint

---

## Traceability

| ID | Deliverable |
|---|---|
| CERT-MON-001 | `charts/cert-manager-values.yaml` |
| CERT-MON-002 | `charts/kube-prometheus-stack-values.yaml` |
| CERT-MON-003 | `charts/prometheus-blackbox-exporter-values.yaml`, ArgoCD app |
| CERT-MON-004 | `docs/certificate-runbook.md` |
| CERT-MON-005 | `scripts/audit-tls-secrets.sh` |
| CERT-MON-006 | `AGENTS.md` |
