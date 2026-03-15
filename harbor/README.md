# Harbor extra manifests (SealedSecrets, IngressRoute)

## SealedSecret: admin password

See root or earlier docs for creating `harbor-admin-password-sealed.yaml` (key: `HARBOR_ADMIN_PASSWORD`). Place it in this directory so the Harbor Application syncs it.

## SealedSecret: encryption key (secretKey)

Harbor uses a 16-character key for encrypting sensitive data. The chart expects a Secret with key **`secretKey`** (literal key name).

### 1. Generate a 16-character value

```bash
openssl rand -hex 8
```

(Output is 16 hex characters.)

### 2. Create and seal the Secret

```bash
export HARBOR_SECRET_KEY="$(openssl rand -hex 8)"

kubectl create secret generic harbor-secret-key \
  --from-literal=secretKey="$HARBOR_SECRET_KEY" \
  --namespace=harbor \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets -o yaml \
  > harbor-secret-key-sealed.yaml
```

### 3. Commit

Move `harbor-secret-key-sealed.yaml` into this `harbor/` directory and commit. The chart is configured with `existingSecretSecretKey: harbor-secret-key`.

**Important:** Once Harbor has encrypted data with this key, changing it will break decryption. Back up or store the value somewhere safe if you might need to restore.
