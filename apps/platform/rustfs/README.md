# RustFS extra manifests (IngressRoute, SealedSecret for credentials)

## SealedSecret: RustFS credentials

The chart expects an existing Secret named **rustfs-credentials** with keys **RUSTFS_ACCESS_KEY** and **RUSTFS_SECRET_KEY**.

### 1. Generate random credentials (optional)

```bash
export RUSTFS_ACCESS_KEY="admin"   # or: $(openssl rand -hex 8)
export RUSTFS_SECRET_KEY=$(openssl rand -base64 24)
echo "Save secret_key for login: $RUSTFS_SECRET_KEY"
```

### 2. Create the Secret and seal it

```bash
kubectl create secret generic rustfs-credentials \
  --from-literal=RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY}" \
  --from-literal=RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY}" \
  --namespace=platform \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets -o yaml \
  > rustfs-credentials-sealed.yaml
```

### 3. Commit

Move `rustfs-credentials-sealed.yaml` into this directory (`apps/platform/rustfs/`) and commit. The platform-rustfs Application syncs this path; the chart is configured with `secret.existingSecret: rustfs-credentials`.
