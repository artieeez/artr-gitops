# Alertmanager → Slack setup

Send **Prometheus / cert-manager / TLS probe alerts** to Slack.

## OCI Notifications vs Alertmanager

If you already receive **Oracle Cloud** alarms in Slack (OCI Console → **Notifications** → topic → **Slack** subscription), that path only covers **OCI-native metrics** (compute, billing, OCI Monitoring alarms). It does **not** receive alerts from in-cluster Prometheus.

For Kubernetes alerts (`CertManagerCertificateNotReady`, `TlsProbeFailed`, etc.) you need a **Slack Incoming Webhook** read by Alertmanager. You can post to the **same Slack channel** you use for OCI — it just needs its own webhook URL.

---

## 1. Create a Slack Incoming Webhook

1. Open [Slack API: Incoming Webhooks](https://api.slack.com/messaging/webhooks) (or **Slack → Apps → Incoming Webhooks**).
2. **Add to Slack** (or create a Slack app with *Incoming Webhooks* enabled).
3. Pick the channel (e.g. `#infra-alerts` or the same channel OCI uses).
4. Copy the webhook URL — it looks like:
   `https://hooks.slack.com/services/T…/B…/…`

Keep this URL secret (anyone with it can post to that channel).

---

## 2. Seal the webhook and commit

From the repo root, with `kubectl` pointed at the cluster and `kubeseal` installed:

```bash
kubectl -n monitoring create secret generic alertmanager-slack-webhook \
  --from-literal=slack-api-url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  --dry-run=client -o yaml | \
kubeseal --format yaml --controller-namespace sealed-secrets --controller-name sealed-secrets \
  > apps/monitoring/grafana/alertmanager-slack-webhook-sealed.yaml
```

Commit the SealedSecret and push. ArgoCD syncs it via the existing `monitoring-grafana-ingress` app.

---

## 3. Sync kube-prometheus-stack

The Alertmanager config lives in [kube-prometheus-stack-values.yaml](../charts/kube-prometheus-stack-values.yaml). After the secret exists, sync (or wait for auto-sync):

- ArgoCD app: `monitoring-kube-prometheus-stack`
- ArgoCD app: `monitoring-grafana-ingress` (deploys the SealedSecret)

Alertmanager mounts the secret at  
`/etc/alertmanager/secrets/alertmanager-slack-webhook/slack-api-url`.

---

## Which alerts go to Slack?

Only **certificate / TLS** alerts (postmortem scope):

| Alert | Severity |
|---|---|
| `CertManagerCertificateNotReady` | critical |
| `CertManagerCertificateExpirySoon` | warning |
| `TlsProbeFailed` | critical |
| `TlsCertificateExpirySoon` | critical |

Other kube-prometheus alerts stay in the Alertmanager UI only (`receiver: null`).

To send **all** cluster alerts to Slack later, change the default `route.receiver` from `null` to `slack-infra` in the values file.

---

## 4. Verify

**Check secret and Alertmanager pod:**

```bash
kubectl get secret -n monitoring alertmanager-slack-webhook
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager --tail=50
```

**Send a test notification** (port-forward Alertmanager):

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-stack-alertmanager 9093:9093
```

In another terminal:

```bash
curl -s -X POST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {
    "labels": {
      "alertname": "CertManagerCertificateExpirySoon",
      "severity": "warning",
      "namespace": "cert-manager",
      "name": "wildcard-artr-com-br"
    },
    "annotations": {
      "summary": "Test: certificate expiry alert",
      "description": "Slack wiring check — safe to ignore."
    },
    "startsAt": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
  }
]'
```

You should see a message in Slack within ~30s (Alertmanager `group_wait`).

**Live alerts:** Grafana → Alerting, or Alertmanager UI at `https://grafana.artr.com.br` (if linked) / port-forward to `:9093`.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| No Slack message | Secret missing or wrong key (`slack-api-url`); Alertmanager logs for `notify` errors |
| `unsupported protocol scheme` | Webhook file empty or malformed URL |
| `invalid_auth` from Slack | Webhook revoked — create a new one and re-seal |
| Alerts in UI but not Slack | Alert name must match `CertManager.*` or `Tls.*` regex |

---

## Related

- [certificate-runbook.md](certificate-runbook.md)
- [Postmortem 2026-06](postmortems/2026-06-certificate-expiry.md) action item #6
