# artr-gitops

**Vision:** GitOps infrastructure-as-code repository (ArgoCD App-of-Apps) managing a Kubernetes cluster on Oracle Cloud Infrastructure.
**For:** The sitio platform operations team.
**Solves:** Declarative, auditable, Git-driven deployment of all cluster workloads — no manual kubectl.

## Goals

- Zero-drift cluster state: Git is the single source of truth, ArgoCD enforces it
- Separation of concerns: environment-specific values via per-env YAML manifests + SealedSecrets
- Reproducible bootstrap: fresh cluster can be stood up from docs/quick-start.md

## Tech Stack

**Core:**
- Orchestrator: ArgoCD (App-of-Apps)
- Runtime: Kubernetes 1.30 on OCI OKE
- Ingress: Traefik (Helm chart v33.0.0)
- Certificate management: cert-manager + Let's Encrypt DNS-01 (Cloudflare)
- Secrets: Bitnami SealedSecrets (encrypted at rest in Git)
- Identity: Pocket ID OIDC + Tinyauth proxy

**Key dependencies:**
- kube-prometheus-stack, Loki, Grafana, Alloy (monitoring)
- Filebrowser (web file manager)
- Pi-hole (DNS ad-blocking)
- RustFS (S3-compatible file storage)
- Docker Registry (in-cluster image cache)
- NFS provisioner (dynamic PVs via external NFS)

## Scope

**Included:**
- All Kubernetes workload manifests (Deployments, Services, IngressRoutes, ConfigMaps, SealedSecrets, PVCs, PVs)
- Helm chart values files for infrastructure components
- Helper shell scripts for Terraform integration
- Bootstrap instructions for ArgoCD

**Explicitly out of scope:**
- Application source code (sitio-backend, sitio-dashboard)
- CI/CD build pipelines (GitHub Actions in separate repos)
- Terraform infrastructure definitions (in `../terraform-files/oracle-cluster/`)
- Database schema management or migrations

## Constraints

- No build system or package manager in this repo
- SealedSecrets require cluster access + kubeseal to create/rotate
- Helper scripts depend on an external Terraform directory
- CRDs (Application, IngressRoute, SealedSecret) lack schema validation in kubeconform
