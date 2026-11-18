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

CI runs these on every pull request and push to `main` (`.github/workflows/validate.yaml`). The same checks run locally via `.pre-commit-config.yaml` (`pre-commit run --all-files`) or by hand:

| Check | Command | Notes |
| --- | --- | --- |
| YAML lint | `yamllint --strict .` | Config in `.yamllint` (relaxed, line length off); warnings fail in strict mode |
| K8s manifest validation | `scripts/ci-kubeconform.sh` | Strict mode, Kubernetes 1.36.0, default schemas plus the datreeio CRDs-catalog (ArgoCD, Traefik, SealedSecret, cert-manager). Excludes `charts/` and `.github/`. CRDs without a schema are skipped. Strict mode catches misplaced fields such as `allowEmpty` outside `syncPolicy.automated` |
| Helm template | `python3 scripts/ci-helm-template.py` | Renders each chart in `argocd/applications/` with its pinned repo and version (e.g. Traefik 41.0.2) and the values files in `charts/`. Needs `helm` and PyYAML |
| Shell lint | `git ls-files '*.sh' \| xargs shellcheck` | Should pass clean |

### Key caveats

- **No application to "run"**: there is no dev server, no `docker-compose up`, no build step. The repo is consumed by ArgoCD reading from Git.
- **Helm values files** (`charts/*.yaml`) are not standalone K8s manifests — kubeconform will error on them if not excluded.
- **CRDs** (ArgoCD `Application`, Traefik `IngressRoute`, Bitnami `SealedSecret`) are validated against the CRDs-catalog schemas where one exists; CRDs without a schema are skipped, which is expected.
- **Helper scripts** in `scripts/` require an external Terraform directory (`../terraform-files/oracle-cluster`) that is not part of this repo. They cannot be executed standalone.
- **SealedSecrets** require `kubeseal` + access to the live cluster's sealed-secrets controller. They cannot be created/rotated locally without cluster access.
- **TLS certificates:** Single wildcard cert in `cert-manager` namespace; Reflector copies `wildcard-artr-com-br-tls` to workload namespaces. Never issue certs directly into workload namespaces — see `docs/certificate-runbook.md`.
- **Image pull policy:** immutable sha tag ⇒ `IfNotPresent`; use `Always` only for floating tags. Single node, so every needless pull is disk churn — see `docs/image-pull-policy.md`.
- See `docs/quick-start.md` for ArgoCD bootstrap instructions and `docs/pocketid-tinyauth-setup.md` for identity provider setup.

### Git

**Agents do not commit or push.** The human commits and pushes.

When changes are ready, suggest a commit message (1–2 sentences, focus on why) and list the files to stage. Stop there — do not run `git add`, `git commit`, or `git push`.

This repo is often a Cursor worktree (`~/.cursor/worktrees/artr-gitops/*`); the primary clone is at `~/Documents/sitio/artr-gitops`. ArgoCD deploys from `origin/main` after the human pushes and merges.

## Markdown lint

Neovim lints markdown with `markdownlint-cli2`, reading this repo's `.markdownlint.json`.

When a task creates or edits markdown files, run `markdownlint-cli2 --fix` on the changed files before finishing and leave zero remaining errors (binary: `~/.local/share/nvim/mason/bin/markdownlint-cli2`, fallback `npx markdownlint-cli2`).
