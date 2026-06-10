# Postmortem: Cluster-wide TLS certificate expiry (June 2026)

**Date:** 2026-06-09  
**Duration:** ~84 days undetected; ~30 minutes to restore  
**Severity:** High — all HTTPS endpoints served an expired certificate  
**Status:** Resolved

---

## Summary

Every deployment exposed via Traefik returned `net::ERR_CERT_DATE_INVALID` in browsers. The wildcard certificate for `*.artr.com.br` had expired on **2026-06-04**, but cert-manager had been unable to renew it since **2026-03-17** due to an invalid Cloudflare API token. Traefik continued serving stale TLS secrets copied by Reflector (and, in two namespaces, even older cert-manager-managed leftovers).

---

## Impact

| Area | Effect |
|---|---|
| User-facing | All HTTPS routes (`argo`, `grafana`, `sitio`, platform apps, etc.) showed browser certificate errors |
| Operations | No automated alert fired; issue discovered manually |
| Duration | Expired cert served for ~5 days; renewal blocked for ~84 days |
| Data / security | No data loss; no evidence of compromise — purely a credential + renewal failure |

---

## Timeline

| When | Event |
|---|---|
| 2026-03-06 | Last successful wildcard cert issued (`notAfter=2026-06-04`) |
| 2026-03-11 | Cloudflare API token rotated in Git (`Rotate Cloudflare API key` commit); cluster received updated SealedSecret |
| 2026-03-17 | `Certificate/wildcard-artr-com-br` enters `Ready=False`; DNS-01 challenges fail with Cloudflare `9109: Invalid access token` |
| 2026-03-17 → 2026-06-09 | cert-manager retries continuously; Cloudflare rate-limits with `10502: Too many authentication failures`; no alert |
| 2026-06-04 | Certificate expires; browsers begin showing `ERR_CERT_DATE_INVALID` |
| 2026-06-09 | Root cause identified; new Cloudflare token applied; ACME challenges succeed; new cert issued (`notAfter=2026-09-07`) |
| 2026-06-09 | Stale secrets in `argocd` and `sitio-staging` deleted; Reflector restarted to propagate fresh cert |

---

## Root cause

**Primary:** The Cloudflare API token used by cert-manager for DNS-01 challenges was invalid. cert-manager could not create `_acme-challenge` TXT records, so Let's Encrypt never reissued the wildcard certificate.

**Why the old cert was still served:** Traefik reads TLS secrets from each IngressRoute namespace. Reflector copies `wildcard-artr-com-br-tls` from `cert-manager` to workload namespaces. When renewal failed, the old reflected secrets remained in place with no automatic invalidation.

---

## Contributing factors

1. **No certificate monitoring or alerting** — kube-prometheus-stack is deployed but has no PrometheusRules for cert-manager Certificate readiness or expiry.

2. **ArgoCD sync ≠ operational health** — `cert-manager-resources` showed `Synced / Healthy` while the Certificate CR was `Ready=False` for months. GitOps sync only confirms manifests match Git, not that ACME succeeded.

3. **Silent renewal failure** — cert-manager retried in the background; challenge errors (`PresentError`) were only visible via `kubectl describe challenge`.

4. **Orphan TLS secrets in two namespaces** — `argocd` and `sitio-staging` held old secrets created directly by cert-manager (with `cert-manager.io/*` annotations) instead of Reflector-managed copies (`reflector.v1.k8s.emberstack.com/*`). When the source secret was recreated, Reflector updated five namespaces but skipped these two because secrets already existed — prolonging stale certs on `argo.artr.com.br` even after renewal.

5. **Incomplete runbook** — [change-cloud-flare-token.md](../change-cloud-flare-token.md) documents how to re-seal the token but not how to verify the token works, unstick ACME resources, or confirm end-to-end TLS.

6. **Cloudflare token lifecycle** — No process to track token expiry/revocation in Cloudflare; invalid token persisted undetected after a prior rotation attempt.

---

## Resolution

1. Created a new Cloudflare API token with `Zone:DNS:Edit` on `artr.com.br`.
2. Re-sealed and pushed `cert-manager/cloudflare-api-token-secret.yaml` to Git; ArgoCD synced.
3. Deleted stuck `Challenge`, `Order`, and `CertificateRequest` resources to force a clean ACME retry.
4. cert-manager issued a new wildcard cert; `Certificate/wildcard-artr-com-br` became `Ready=True`.
5. Deleted stale TLS secrets in `argocd` and `sitio-staging`; restarted Reflector to recreate them from the source.
6. Verified live certs via `openssl s_client` on representative hosts.

---

## Lessons learned

- **Certificate renewal is an runtime concern**, not just a GitOps concern. Synced manifests do not guarantee valid TLS.
- **A single wildcard cert is a single point of failure** — one broken credential or one stuck renewal affects every HTTPS endpoint.
- **Reflector only creates missing secrets** — it does not replace pre-existing secrets that were not created by Reflector. Namespace hygiene matters.
- **External API credentials need the same operational rigor as cluster secrets** — rotation must include post-rotation verification.

---

## Action items

Prioritized enhancements to avoid recurrence. Track implementation in GitHub issues or `.specs/project/STATE.md`.

### P0 — Do first

| # | Action | Rationale |
|---|---|---|
| 1 | **Add PrometheusRule alerts for cert-manager** | Alert when `certmanager_certificate_ready_status{condition="False"} == 1` for >15m, when cert expires in <14 days, and when ACME orders are pending >1h. cert-manager exposes metrics; enable `prometheus.enabled: true` in [cert-manager-values.yaml](../../charts/cert-manager-values.yaml). |
| 2 | **Add blackbox TLS probe** | External check that `openssl`/HTTP probes on `argo.artr.com.br`, `grafana.artr.com.br`, and `sitio.artr.com.br` report >7 days until expiry. Catches Reflector drift and Traefik serving stale secrets. |
| 3 | **Expand cert runbook** | Extend [change-cloud-flare-token.md](../change-cloud-flare-token.md) into a full troubleshooting guide: verify token (`curl …/tokens/verify`), check challenges, unstick ACME, verify Reflector propagation, `openssl s_client` checks. |

### P1 — Do soon

| # | Action | Rationale |
|---|---|---|
| 4 | **Post-rotation verification checklist** | After any Cloudflare token change: verify API token, confirm `Certificate` becomes `Ready=True` within 10 minutes, confirm all namespaces have Reflector-annotated secrets with matching `creationTimestamp`. |
| 5 | **Audit namespace TLS secrets** | One-time + periodic script: ensure every namespace using `wildcard-artr-com-br-tls` has `reflector.v1.k8s.emberstack.com/reflects: cert-manager/wildcard-artr-com-br-tls` — not `cert-manager.io/certificate-name`. Remove orphans. |
| 6 | **Alertmanager notification channel** | Configure Alertmanager receiver (email, Slack, or similar) so cert alerts reach someone who can act. |
| 7 | **Cloudflare token expiry calendar** | If the token has an expiration date set in Cloudflare, add a calendar reminder 14 days before expiry. Prefer non-expiring tokens scoped to DNS edit only, with rotation documented. |

### P2 — Nice to have

| # | Action | Rationale |
|---|---|---|
| 8 | **Grafana dashboard for cert-manager** | Import or build a dashboard showing Certificate status, expiry countdown, and recent ACME challenge failures. |
| 9 | **Weekly CI / CronJob cert audit** | Script in `scripts/` that checks Certificate CR status and TLS secret `notAfter` dates; fails or notifies if any cert expires within 21 days or is not Ready. |
| 10 | **Document Reflector architecture constraint** | Add to AGENTS.md or a dedicated doc: only `cert-manager` namespace holds the source TLS secret; all other namespaces must receive Reflector copies — never cert-manager-issued secrets directly. |
| 11 | **Consider shorter renewal window alert** | cert-manager renews ~30 days before expiry by default; alerting at 14 days leaves limited buffer. Alert at 21 days to allow time for credential fixes. |

---

## Example alert rules (starting point)

Add to a new `PrometheusRule` in the monitoring stack:

```yaml
# Certificate not Ready for 15+ minutes
- alert: CertManagerCertificateNotReady
  expr: certmanager_certificate_ready_status{condition="False"} == 1
  for: 15m
  labels:
    severity: critical
  annotations:
    summary: "Certificate {{ $labels.name }} in {{ $labels.namespace }} is not Ready"

# Certificate expires within 14 days
- alert: CertManagerCertificateExpirySoon
  expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14
  for: 1h
  labels:
    severity: warning
  annotations:
    summary: "Certificate {{ $labels.name }} expires in {{ $value | humanizeDuration }}"
```

Requires cert-manager Prometheus metrics to be scraped (enable in Helm values + ServiceMonitor).

---

## Verification commands (keep handy)

```bash
# Certificate status
kubectl get certificate -A
kubectl describe certificate -n cert-manager wildcard-artr-com-br

# ACME pipeline
kubectl get certificaterequest,order,challenge -n cert-manager
kubectl describe challenge -n cert-manager

# Cloudflare token (from cluster)
kubectl get secret -n cert-manager cloudflare-api-token-secret \
  -o jsonpath='{.data.api-token}' | base64 -d | \
  xargs -I{} curl -s -H "Authorization: Bearer {}" \
  https://api.cloudflare.com/client/v4/user/tokens/verify

# Live TLS served to browsers
openssl s_client -connect argo.artr.com.br:443 -servername argo.artr.com.br </dev/null 2>/dev/null \
  | openssl x509 -noout -dates

# Reflector propagation — all copies should share source timestamp
for ns in argocd staging production platform monitoring sitio-staging sitio-production; do
  echo -n "$ns: "
  kubectl get secret -n "$ns" wildcard-artr-com-br-tls \
    -o jsonpath='{.metadata.creationTimestamp}{" "}{.metadata.annotations.reflector\.v1\.k8s\.emberstack\.com/reflects}{"\n"}' 2>&1
done
```

---

## References

- [change-cloud-flare-token.md](../change-cloud-flare-token.md)
- [wildcard-certificates.yaml](../../cert-manager/wildcard-certificates.yaml)
- [cert-manager Prometheus metrics](https://cert-manager.io/docs/devops-tools/prometheus-metrics/)
- Fix commit: `97dcd8c` — Rotate Cloudflare API token for cert-manager DNS-01 renewal
