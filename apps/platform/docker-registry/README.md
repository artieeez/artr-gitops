# Docker Registry (IngressRoute + auth via SealedSecret)

## Auth: create the htpasswd SealedSecret

The registry expects a Secret **registry-htpasswd** in namespace **platform** with key **htpasswd** (one line: `user:hashedpassword` from `htpasswd -nbB`).

Create the sealed secret and save it as `registry-htpasswd-sealed.yaml` in this directory:

```bash
# From repo root. Replace USER and PASSWORD.
htpasswd -nbB USER PASSWORD | \
kubectl -n platform create secret generic registry-htpasswd \
  --from-file=htpasswd=/dev/stdin \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets -o yaml \
  > apps/platform/docker-registry/registry-htpasswd-sealed.yaml
```

Save the command output as **registry-htpasswd-sealed.yaml** in this directory, then commit and push. ArgoCD will sync; the controller creates the Secret and the registry uses it for auth. (Until this file exists, the registry pod may stay in CreateContainerConfigError.)

**Login:** `docker login registry.artr.com.br` (use the same USER/PASSWORD).
