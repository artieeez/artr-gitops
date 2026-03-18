# sitio-wix-webhooks (sitio-staging)

## Reseal `docker-registry-pull` (e.g. after changing registry host)

`--docker-server` must match the **image** host (e.g. in-cluster `10.96.240.50:5000`).

From the **artr-gitops repo root**:

```bash
kubectl create secret docker-registry docker-registry-pull \
  -n sitio-staging \
  --docker-server=10.96.240.50:5000 \
  --docker-username='admin' \
  --docker-password='YOUR_REGISTRY_PASSWORD' \
  --docker-email='unused@example.com' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets -o yaml \
  > apps/sitio-staging/sitio-wix-webhooks/docker-registry-pull-sealed.yaml
```

Commit and push. ArgoCD applies the SealedSecret → Secret `docker-registry-pull`.

**Note:** If you ever pasted the real password somewhere public, rotate it in the registry and run the command again with the new password.
