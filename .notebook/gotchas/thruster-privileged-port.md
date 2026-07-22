# Thruster privileged port bind

## Symptom

ArgoCD app pod logs (JSON, Go-style):

`Failed to start HTTP listener` / `listen tcp :80: bind: permission denied`

Looks like an ArgoCD/server issue; it is the **workload** (Rails + Thruster), not `argocd-server`.

## Cause

Rails 8 Thruster defaults to `:80`. Image runs as UID 1000 → cannot bind ports < 1024.

## Fix

Same pattern as `sitio-rails` deployments:

- `HTTP_PORT=8080`
- `containerPort: 8080` named `http`
- Leave Service `port: 80` / `targetPort: http` and IngressRoute alone

Applies to: `apps/*/home`, `apps/sitio-*/sitio-rails`.
