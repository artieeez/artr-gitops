# apps/code-factory — the agentic workflow platform

[artieeez/code-factory](https://github.com/artieeez/code-factory) at
`https://factory.artr.com.br`, one environment. Namespace `code-factory`, two Argo CD apps:

| App | Path | What |
| --- | --- | --- |
| `code-factory` | `platform/` | Postgres, server, dashboard, IngressRoute |
| `code-factory-workers` | `workers/` | one StatefulSet per workflow, one replica per node |

| Workload | Image | Notes |
| --- | --- | --- |
| `cf-postgres` | `postgres:17.11` | StatefulSet, 5 Gi on `nfs-client` |
| `cf-server` | `cf-server` | NestJS on 4400; init container runs `prisma migrate deploy`; artifacts on PVC `cf-server-data`; `factory.yaml` from ConfigMap `cf-factory` |
| `cf-dashboard` | `cf-dashboard` | static build behind nginx on 8080 |
| `cf-worker-<workflow>` | `cf-worker-<workflow>` | StatefulSet (2 replicas, anti-affinity by node); run folders and pnpm's store on a 20 Gi `nfs-client` volume per pod, so a restarted pod keeps its name and folders (code-factory AD-076); a Postgres sidecar on `127.0.0.1:5432` for test runs (`CF_TEST_POSTGRES_URL`) |

Image tags are bumped by code-factory's GitHub Actions after CI passes on `main`:
`deploy.yml` (server, dashboard) and `deploy-workers.yml` (workflows listed in its
`deploy/workers.json`).

## Routing

`/api`, `/auth`, `/hooks`, `/w/`, `/health` and `/ready` go to the server, everything else to
the dashboard. No TinyAuth: people sign in through Pocket ID in the server itself, workers use
their `cfw_` tokens, and `/hooks/<instance>/<token>` must stay public for the GitHub and Linear
webhooks.

## First deploy

1. Pocket ID: add an OIDC client with callback `https://factory.artr.com.br/auth/callback`.
2. `./scripts/seal-code-factory.sh postgres`, `server` and `ocir`; commit the sealed files.
3. Let the platform sync and log in; on the Workers page create a worker for the workflow and
   copy its `cfw_` token; add agent accounts on the Accounts page.
4. `./scripts/seal-code-factory.sh worker`, then add the `code-factory-workers` Argo CD
   Application (`argocd/applications/code-factory-workers.yaml`, path `workers/`) in the same
   commit: the workers only sync once they have a token. Until then `deploy-workers.yml`
   bumps `workers/<workflow>/statefulset.yaml` and nothing deploys it.
5. GitHub App, owned by artieeez and installed on `artieeez/code-factory` only: permissions
   `contents`, `pull_requests`, `issues` write, `checks` read, `actions` write; events
   `check_suite`, `pull_request`, `pull_request_review`, `issue_comment`,
   `pull_request_review_comment`. Its PRs are the App bot's, so artieeez can approve them.
6. Plugins: seal `LINEAR_*` and `GITHUB_*` (App id, installation id, slug, private key,
   webhook secret) into `cf-server`, uncomment `plugins:` and `workflows:` in
   `platform/server/configmap.yaml`, and point the Linear and GitHub App webhooks at
   `https://factory.artr.com.br/hooks/<instance>/<token>`.

## Changing the server's config

The server reads `factory.yaml` (ConfigMap `cf-factory`) and Secret `cf-server` only at start.
Bump `code-factory/config-rev` on `platform/server/deployment.yaml` in the same commit, so
Argo CD rolls the pod.
