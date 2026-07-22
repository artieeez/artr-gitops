# .notebook
> Project intelligence — read before every mission

Last updated: 2026-07-22

- [thruster-privileged-port](gotchas/thruster-privileged-port.md) — Thruster :80 bind denied as UID 1000; use HTTP_PORT=8080 | gotcha | thruster, home, sitio-rails
- [sealedsecret-ownership](gotchas/sealedsecret-ownership.md) — Pre-existing Secret blocks SealedSecret sync | gotcha | sealed-secrets, argocd
- [sitio-rails-only](patterns/sitio-rails-only.md) — Sitio GitOps is Rails-only under artr-sitio-* | pattern | sitio, argocd
- [renovate-managerfilepatterns-glob](gotchas/renovate-managerfilepatterns-glob.md) — `/apps/**` in managerFilePatterns is invalid RE2; nested apps never scanned | gotcha | renovate, filebrowser, quantum
- [gha-secret-blanked-image-output](gotchas/gha-secret-blanked-image-output.md) — Secret in job output blanks IMAGE → `image: :sha-...` in gitops | gotcha | github-actions, sitio-rails, ocir
