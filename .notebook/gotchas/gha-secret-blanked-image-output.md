# GHA secret blanked image job output

**Tags:** gotcha, github-actions, sitio-rails, ocir

## Symptom

ArgoCD `InspectFailed`:

```
Failed to apply default image tag ":sha-<short>": couldn't parse image name ":sha-<short>": invalid reference format
```

Deployment in git had `image: :sha-0b293ab` (registry/name missing).

## Cause

`sitio-rails` Build/push workflow put `secrets.OCIR_NAMESPACE` into the `image` job output. GitHub Actions blanks job outputs that embed secret values when passed to dependent jobs, so `update-gitops` received an empty image and wrote `image: :sha-...`.

`home` avoided this by hardcoding `OCIR_NAMESPACE` as a plain workflow env (not a secret).

## Fix

- Restore full image in `apps/sitio-staging/sitio-rails/deployment.yaml`
- Keep `OCIR_NAMESPACE` as non-secret workflow env (same pattern as `home`)
- Guard the gitops bump so an invalid `IMAGE` fails the job instead of writing a broken ref

## See also

- `sitio-rails` `.github/workflows/build-push-ocir.yaml`
- `home` `.github/workflows/build-push-ocir.yaml`
