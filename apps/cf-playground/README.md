# apps/cf-playground — the code-factory playground

[artieeez/cf-playground-dashboard](https://github.com/artieeez/cf-playground-dashboard) at
`https://playground.artr.com.br`. Namespace `cf-playground`, Argo CD app `cf-playground`
(path `apps/cf-playground`).

| Workload | Image | Notes |
| --- | --- | --- |
| `cf-playground-dashboard` | `cf-playground-dashboard` | static React SPA behind a non-root nginx on 8080, arm64 |

The image tag in `dashboard/deployment.yaml` is bumped by cf-playground-dashboard's CI.

The IngressRoute is public (no TinyAuth) and uses the wildcard cert, which Reflector copies into
`cf-playground` (`cert-manager/wildcard-certificates.yaml`).

## First deploy

1. `./scripts/seal-cf-playground.sh` writes `ocir-pull-sealed.yaml` (needs the `oracle-cluster`
   kubectl context). Commit it with, or before, the Application.
