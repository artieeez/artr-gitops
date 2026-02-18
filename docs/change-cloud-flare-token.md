kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
  --from-literal=api-token=YOUR_NEW_TOKEN \
  --dry-run=client -o yaml | \
kubeseal --format yaml --controller-namespace sealed-secrets --controller-name sealed-secrets \
  > cert-manager/cloudflare-api-token-secret.yaml