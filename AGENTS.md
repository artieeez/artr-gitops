# AGENTS.md

## Cursor Cloud specific instructions

### Repository overview

This is a **GitOps infrastructure-as-code repository** (ArgoCD App-of-Apps pattern) for a Kubernetes cluster on Oracle Cloud Infrastructure. It contains only Kubernetes YAML manifests, Helm value files, and helper shell scripts — no application source code, no build system, no package manager.

### Development tools

The development environment requires:
- `yamllint` — YAML linting (`pip install yamllint`)
- `kubeconform` — Kubernetes manifest validation (binary from GitHub releases)
- `kubectl` — Kubernetes CLI
- `helm` — Helm chart CLI (for template rendering / validation of values files)
- `shellcheck` — Bash script linting (system package)

### Lint / Validate commands

| Check | Command | Notes |
|---|---|---|
| YAML lint | `yamllint -d relaxed .` | 2 pre-existing trailing-space errors in IngressRoute files; warnings are non-blocking |
| K8s manifest validation | `kubeconform -summary -ignore-missing-schemas -kubernetes-version 1.30.0 $(find . -name '*.yaml' -not -path './.git/*' -not -path './charts/*')` | Exclude `charts/` (Helm values, not manifests). ~50 CRDs skipped (no schema); 0 invalid expected |
| Helm template (Traefik) | `helm template traefik-oci traefik/traefik --version 33.0.0 -f charts/traefik-values.yaml --namespace traefik` | Requires `helm repo add traefik https://traefik.github.io/charts` first |
| Shell lint | `shellcheck scripts/*.sh` | Should pass clean |

### Key caveats

- **No application to "run"**: there is no dev server, no `docker-compose up`, no build step. The repo is consumed by ArgoCD reading from Git.
- **Helm values files** (`charts/*.yaml`) are not standalone K8s manifests — kubeconform will error on them if not excluded.
- **CRDs** (ArgoCD `Application`, Traefik `IngressRoute`, Bitnami `SealedSecret`) are skipped by kubeconform due to missing schemas — this is expected.
- **Helper scripts** in `scripts/` require an external Terraform directory (`../terraform-files/oracle-cluster`) that is not part of this repo. They cannot be executed standalone.
- **SealedSecrets** require `kubeseal` + access to the live cluster's sealed-secrets controller. They cannot be created/rotated locally without cluster access.
- **TLS certificates:** Single wildcard cert in `cert-manager` namespace; Reflector copies `wildcard-artr-com-br-tls` to workload namespaces. Never issue certs directly into workload namespaces — see `docs/certificate-runbook.md`.
- See `docs/quick-start.md` for ArgoCD bootstrap instructions and `docs/pocketid-tinyauth-setup.md` for identity provider setup.

### Git

**Agents do not commit or push.** The human commits and pushes.

When changes are ready, suggest a commit message (1–2 sentences, focus on why) and list the files to stage. Stop there — do not run `git add`, `git commit`, or `git push`.

This repo is often a Cursor worktree (`~/.cursor/worktrees/artr-gitops/*`); the primary clone is at `~/Documents/sitio/artr-gitops`. ArgoCD deploys from `origin/main` after the human pushes and merges.
