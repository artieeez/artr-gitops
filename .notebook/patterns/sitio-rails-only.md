# Sitio = sitio-rails only

## Layout
- Parents: `artr-sitio-staging` / `artr-sitio-production` → `argocd/applications/sitio-{staging,production}/`
- Only child Application: `sitio-*-sitio-rails` → `apps/sitio-*/sitio-rails/`
- NestJS/React/postgres manifests removed from git (2026-07). Promote workflows kept only for `promote-sitio-rails.yaml`.

## Not Sitio
`staging-postgres` (`apps/staging/postgres`, `argocd/applications/staging/staging-postgres.yaml`) was a generic staging DB (replicas: 0, retained PVC) — removed in 2026-08 (ART-68), along with its orphaned PVC.
