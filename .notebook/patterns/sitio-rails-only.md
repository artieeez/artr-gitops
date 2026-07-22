# Sitio = sitio-rails only

## Layout
- Parents: `artr-sitio-staging` / `artr-sitio-production` → `argocd/applications/sitio-{staging,production}/`
- Only child Application: `sitio-*-sitio-rails` → `apps/sitio-*/sitio-rails/`
- NestJS/React/postgres manifests removed from git (2026-07). Promote workflows kept only for `promote-sitio-rails.yaml`.

## Not Sitio
`staging-postgres` under `apps/staging/postgres` is generic staging DB (replicas: 0, retained PVC). Separate from Sitio.
