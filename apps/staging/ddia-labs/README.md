# ddia-labs

DDIA Labs — hands-on experiments from the Designing Data-Intensive Applications
book club (craft and code club). Monorepo: [`artieeez/ddia-labs`](https://github.com/artieeez/ddia-labs).

| Env | Namespace | URL |
|-----|-----------|-----|
| Staging | `staging` | https://ddia.artr.com.br |

Image: `vcp.ocir.io/axtvnrdemzo7/ddia-labs:<tag>`

**CI/CD:** push to `main` in `artieeez/ddia-labs` runs CI, then the
*Build and push OCIR* workflow builds the linux/arm64 image, pushes it to OCIR
(also as `staging-latest`), and bumps the image tag in this file. Argo CD syncs.

SealedSecrets: `ddia-labs-secrets` (SECRET_KEY_BASE) sealed for the `staging`
namespace; image pulls use the existing `ocir-pull` secret.

Probes hit `/up` (Rails health check); the app is stateless — no PVC, single
replica.