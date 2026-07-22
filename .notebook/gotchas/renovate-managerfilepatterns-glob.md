# Renovate `managerFilePatterns` with `**` skips Kubernetes apps

Tags: gotcha, renovate, filebrowser, quantum, kubernetes

## Symptom

Quantum (FileBrowser) stays on an old tag (e.g. `gtstef/filebrowser:1.2.2-stable`) while newer Docker tags exist (`1.5.0-stable`). No Renovate PR. Dependency Dashboard lists **no** `kubernetes` / `argocd` dependencies — only `github-actions` and a few `helm-values`.

## Cause

`renovate.json` uses glob-like patterns that are invalid / ineffective as Renovate regex patterns:

- `kubernetes.managerFilePatterns`: `/apps/**`
- `argocd.managerFilePatterns`: `/argocd/applications/**`

`**` is not valid RE2 (`multiple repeat`). Renovate never scans `apps/platform/filebrowser/deployment.yaml`, so it cannot see the image.

Working contrast: `helm-values` uses a real regex (`/charts/.+-values\\.yaml$/`) and does show up on the dashboard.

Not the primary cause here: weekly `schedule: ["before 6am on Monday"]` only delays PR creation; dashboard was still refreshed without detecting filebrowser. Renovate tracks Docker Hub tags (`gtstef/filebrowser`), not the GitHub release title `v1.5.0-stable`.

## Fix

Use regex (or a documented glob form Renovate accepts), e.g.:

```json
"kubernetes": {
  "managerFilePatterns": ["/apps/.+\\.ya?ml$/"]
},
"argocd": {
  "managerFilePatterns": ["/argocd/applications/.+\\.ya?ml$/"]
}
```

Then re-run via Dependency Dashboard checkbox; expect `docker.io/gtstef/filebrowser` under Detected Dependencies.

## Refs

- `renovate.json` (L11–16)
- `apps/platform/filebrowser/deployment.yaml` (image)
- Dependency Dashboard issue #2
