# Rotate Cloudflare API token for cert-manager DNS-01

Full troubleshooting guide: [certificate-runbook.md](certificate-runbook.md)

```sh
kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
  --from-literal=api-token=YOUR_NEW_TOKEN \
  --dry-run=client -o yaml | \
kubeseal --format yaml --controller-namespace sealed-secrets --controller-name sealed-secrets \
  > cert-manager/cloudflare-api-token-secret.yaml
```

After committing and syncing, run the **post-rotation checklist** in the runbook.
