#!/usr/bin/env bash
# Validate Kubernetes manifests with kubeconform (used by CI and pre-commit).
# Excludes charts/ (Helm values) and .github/ (workflows). CRDs are checked
# against the datreeio CRDs-catalog where a schema exists; others are skipped.
# -strict rejects unknown fields, which catches misplaced keys such as an
# ArgoCD syncPolicy field at the wrong nesting level.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.36.0}"
CRDS_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

cd "$(git rev-parse --show-toplevel)"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    find . -name '*.yaml' \
      -not -path './.git/*' -not -path './charts/*' -not -path './.github/*' \
      -not -path './.notebook/*' -not -name '.pre-commit-config.yaml' | sort
  )
fi

exec kubeconform \
  -strict -summary -ignore-missing-schemas \
  -kubernetes-version "$K8S_VERSION" \
  -schema-location default \
  -schema-location "$CRDS_CATALOG" \
  "${files[@]}"
