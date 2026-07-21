# home

Personal portfolio app on OCIR.

| Env | Namespace | URL |
|-----|-----------|-----|
| Staging | `staging` | https://home-staging.artr.com.br |
| Production | `production` | https://artr.com.br |

Image: `vcp.ocir.io/axtvnrdemzo7/home:<tag>`

**CI:** push to `main` in `artieeez/home` builds/pushes and bumps the staging image tag. Promote staging → production with the `Promote home to production` workflow in this repo (`workflow_dispatch`).

SealedSecrets (`ocir-pull`, `home-secrets`) are already sealed for both namespaces.
