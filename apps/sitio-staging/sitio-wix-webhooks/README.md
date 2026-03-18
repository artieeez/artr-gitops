# sitio-wix-webhooks (sitio-staging)

## Pull secret (`docker-registry-pull`)

`--docker-server` must match the **registry host in the image**, character-for-character:

| Image starts with | `--docker-server` |
|-------------------|-------------------|
| `docker.artr.com.br/...` | `docker.artr.com.br` |
| `10.96.240.50:5000/...` | `10.96.240.50:5000` |

If you see **authentication required**, the secret is missing, wrong password, or was sealed for the **other** host (e.g. internal IP while the image uses `docker.artr.com.br`).

From **artr-gitops repo root** (image on `docker.artr.com.br`):

```bash
kubectl create secret docker-registry docker-registry-pull \
  -n sitio-staging \
  --docker-server=docker.artr.com.br \
  --docker-username='YOUR_USER' \
  --docker-password='YOUR_PASSWORD' \
  --docker-email='unused@example.com' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets -o yaml \
  > apps/sitio-staging/sitio-wix-webhooks/docker-registry-pull-sealed.yaml
```

Commit and push so ArgoCD applies the SealedSecret.

**Quick test without GitOps** (same server as image):

```bash
kubectl create secret docker-registry docker-registry-pull \
  -n sitio-staging \
  --docker-server=docker.artr.com.br \
  --docker-username='YOUR_USER' \
  --docker-password='YOUR_PASSWORD' \
  --docker-email='unused@example.com' \
  --dry-run=client -o apply -f - | kubectl apply -f -
kubectl rollout restart deployment/sitio-wix-webhooks -n sitio-staging
```
