# apps/code-factory — the agentic workflow platform

[artieeez/code-factory](https://github.com/artieeez/code-factory) at
`https://factory.artr.com.br`, one environment. Namespace `code-factory`, two Argo CD apps:

| App | Path | What |
| --- | --- | --- |
| `code-factory` | `platform/` | Postgres, server, dashboard, IngressRoute |
| `code-factory-workers` | `workers/` | one StatefulSet per workflow, one replica per node; `pr-assistant/` and `sdd/` are scaffolds the Application excludes for now |

| Workload | Image | Notes |
| --- | --- | --- |
| `cf-postgres` | `postgres:17.11` | StatefulSet, 5 Gi on `nfs-client` |
| `cf-server` | `cf-server` | NestJS on 4400; init container runs `prisma migrate deploy`; artifacts on PVC `cf-server-data`; config from env and Secret `cf-server` (no config file, code-factory AD-089) |
| `cf-dashboard` | `cf-dashboard` | static build behind nginx on 8080 |
| `cf-worker-<workflow>` | `cf-worker-<workflow>` | StatefulSet, anti-affinity by node; run folders and pnpm's store on an `nfs-client` volume per pod, so a restarted pod keeps its name and folders (code-factory AD-076). dogfood: 2 replicas, 20 Gi, a Postgres sidecar on `127.0.0.1:5432` for test runs (`CF_TEST_POSTGRES_URL`). pr-assistant: 1 replica, 2 slots, 20 Gi. sdd: 1 replica, 5 Gi |

Image tags are bumped by GitHub Actions after CI passes on `main`: code-factory's `deploy.yml`
(server, dashboard), and each worker's own repo for `workers/<workflow>/statefulset.yaml`:

| Workflow | Image | Repo | Synced |
| --- | --- | --- | --- |
| `dogfood` | `cf-worker-dogfood` | artieeez/cf-dogfood-worker | yes |
| `pr-assistant` | `cf-worker-pr-assistant` | artieeez/pr-assistant-worker | no, excluded |
| `sdd` | `cf-worker-sdd` | artieeez/cf-sdd-worker | no, excluded |

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
   webhook secret, hook token) into `cf-server`; the server makes one `github` and one
   `linear` instance from them. Point the Linear and GitHub App webhooks at
   `https://factory.artr.com.br/hooks/<instance>/<token>`, and bind each workflow's slots and
   settings on the dashboard.

## Adding a worker

`pr-assistant/` and `sdd/` are scaffolded from `dogfood/` but excluded in
`argocd/applications/code-factory-workers.yaml` (`directory.exclude`). To turn one on:

1. The OCIR repository `cf-worker-<workflow>` exists (oracle-cluster) and the worker's repo has
   pushed an image and bumped the `sha-0000000` placeholder in its `statefulset.yaml`.
2. On the Workers page create a worker for the workflow and copy its `cfw_` token.
3. `./scripts/seal-code-factory.sh worker <workflow>` writes
   `workers/<workflow>/cf-worker-<workflow>-sealed.yaml`.
4. In the same commit, drop `<workflow>/*` from the Application's `exclude`.

## Changing the server's config

The server reads no config file (code-factory AD-089). Sign-in (`CF_OIDC_*`) and the plugins'
default instances (`GITHUB_*`, `LINEAR_*`, `CF_<PLUGIN>_HOOK_TOKEN`) come from env in
`platform/server/deployment.yaml` and Secret `cf-server`; workflow bindings and settings are
set on the dashboard. The image sets `CF_HOST=0.0.0.0`, so the server refuses to start
without `CF_OIDC_ISSUER`.

The server reads its env only at start. When you change Secret `cf-server`, bump
`code-factory/config-rev` on the deployment in the same commit, so Argo CD rolls the pod.
