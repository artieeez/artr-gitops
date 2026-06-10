# Code Conventions

**Analyzed:** Project structure and existing YAML manifests.

## Naming Conventions

**Files:** kebab-case, purpose-descriptive.
Examples: `deployment.yaml`, `service.yaml`, `ingressroute.yaml`, `ocir-pull-sealed.yaml`, `sitio-backend-db-url-sealed.yaml`

**SealedSecrets:** named `<component>-<purpose>-sealed.yaml` (e.g., `postgres-sitio-production-auth-sealed.yaml`).

**Kubernetes resources:** lowercase, hyphens. Names include environment prefix where namespace doesn't isolate (e.g., PVC name `sitio-production-postgres-data`).

**ArgoCD Applications:** `<env>-<component>.yaml` under `argocd/applications/<env>/`.

## File Organization

**Apps:** `apps/<environment>/<component>/(deployment|service|ingressroute|pvc|sealed).yaml`
Each component is a flat directory — no subdirectories or kustomize overlays.

**ArgoCD:** `argocd/applications/<env>-parent.yaml` and `argocd/applications/<env>/<app>.yaml`

## YAML Style

- 2-space indentation
- `apiVersion` first, then `kind`, then `metadata`
- Labels include at minimum: `app: <name>` and `environment: <env-name>`
- Resources use `requests` and `limits` (CPU in millicores, memory in Gi/Mi)
- Container ports explicitly named (e.g., `name: postgres`)

## Secrets

- All secrets are SealedSecrets (Bitnami)
- No plaintext secrets in YAML files
- Sensitive env vars reference SealedSecrets via `secretKeyRef`
- SealedSecret files have `-sealed.yaml` suffix

## ArgoCD Apps

- Use `namespace: argocd` for the Application resource itself
- `destination.namespace` points to the target workload namespace
- `source.path` is relative to repo root (`apps/<env>/<component>`)
- No `syncPolicy.automated` on most apps (manual sync unless explicitly stated)

## Image References

- OCI Registry images use full path: `vcp.ocir.io/<namespace>/<repo>:<tag>`
- Docker Hub images: `docker.io/<org>/<image>:<tag>`
- No `latest` tag in production — always pinned to a specific version
