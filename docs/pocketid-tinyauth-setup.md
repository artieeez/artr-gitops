## Pocket ID & Tinyauth bootstrap

This is the minimal flow to bootstrap Pocket ID and wire it into Tinyauth using SealedSecrets.

### 1. Generate an encryption key

Use a strong, random 32‑byte key. Run locally:

```bash
ENCRYPTION_KEY=$(openssl rand -hex 32)
echo "$ENCRYPTION_KEY"
```

Save this value somewhere safe. You will **reuse the same key** whenever you rotate the Pocket ID client credentials.

### 2. Create or update the `pocketid-credentials` SealedSecret

Edit the values below with:

- `encryption-key`: the value from the previous step  
- `client-id` / `client-secret`: from the Pocket ID admin UI → OIDC client for Tinyauth

Then run from the repo root:

```bash
kubectl -n platform create secret generic pocketid-credentials \
  --from-literal=encryption-key='<ENCRYPTION_KEY_HERE>' \
  --from-literal=client-id='<POCKETID_CLIENT_ID_HERE>' \
  --from-literal=client-secret='<POCKETID_CLIENT_SECRET_HERE>' \
  --dry-run=client -o yaml | \
kubeseal --format yaml \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets \
  > apps/platform/pocketid/pocketid-credentials-sealed.yaml
```

Commit and push the updated `pocketid-credentials-sealed.yaml`. ArgoCD will sync it and the SealedSecrets controller will create/update the `pocketid-credentials` Secret in the `platform` namespace, which both Pocket ID and Tinyauth consume.

