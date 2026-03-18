# SealedSecrets cheatsheet

Controller: `--controller-namespace=sealed-secrets --controller-name=sealed-secrets` (adjust if your install differs).

---

## Generate a random password

```bash
openssl rand -base64 24
```

(URL-safe, no `+`/`/`): `openssl rand -base64 24 | tr -d '+/' | cut -c1-24`

---

## Get the public key (new key / after rotation)

```bash
kubeseal --fetch-cert \
  --controller-namespace=sealed-secrets \
  --controller-name=sealed-secrets \
  -o pub-sealed-secrets.pem
```

Use this cert to seal new secrets from another machine that doesn’t have cluster access:  
`kubeseal --cert=pub-sealed-secrets.pem ...`

---

## Reseal one SealedSecret (re-encrypt with current key)

```bash
kubeseal --re-encrypt \
  --controller-namespace=sealed-secrets \
  --controller-name=sealed-secrets \
  < path/to/your-sealed-secret.yaml \
  -o yaml > path/to/your-sealed-secret-new.yaml
mv path/to/your-sealed-secret-new.yaml path/to/your-sealed-secret.yaml
```

Or in-place:

```bash
kubeseal --re-encrypt --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
  < path/to/your-sealed-secret.yaml > tmp.yaml && mv tmp.yaml path/to/your-sealed-secret.yaml
```

---

## Reseal all SealedSecrets (e.g. after key rotation)

From repo root, re-encrypt every `*sealed*.yaml`:

```bash
for f in $(grep -rl "kind: SealedSecret" --include="*.yaml" .); do
  kubeseal --re-encrypt --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
    < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
```

Then commit and push; ArgoCD will apply the updated SealedSecrets.

---

## Get a Secret (decrypted content from the cluster)

The SealedSecret controller turns a SealedSecret into a normal Secret. To view it:

```bash
kubectl get secret -n <namespace> <secret-name> -o yaml
# or one key:
kubectl get secret -n <namespace> <secret-name> -o jsonpath='{.data.KEY}' | base64 -d
```

You cannot “unseal” offline; decryption only happens in the cluster.

---

## When the sealing key is rotated

1. **New key** – The controller creates new keys on a schedule (e.g. 30 days). Existing SealedSecrets still decrypt with old keys; new seals use the latest key.
2. **Reseal everything** – To migrate to the new key and stop relying on old ones, run the “Reseal all SealedSecrets” loop above, then commit.
3. **Optional: list / blacklist keys** – Keys live in the controller namespace (e.g. `sealed-secrets`). To see them:
   ```bash
   kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key
   ```
   To mark a key as compromised (stops using it for decryption):
   ```bash
   kubectl -n sealed-secrets label secret <key-secret-name> \
     sealedsecrets.bitnami.com/sealed-secrets-key=compromised --overwrite
   ```
   Restart the controller so it picks up the label.
