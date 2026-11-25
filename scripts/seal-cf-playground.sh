#!/usr/bin/env bash
# seal-cf-playground.sh — seal the cf-playground namespace's `ocir-pull` image pull Secret,
# copied from coding-box's live one (the same way seal-code-factory.sh does for code-factory).
#
#   ./scripts/seal-cf-playground.sh
#
# Later token rotations are covered by seal-ocir-pull.sh, which re-seals every
# ocir-pull-sealed.yaml under apps/. Plaintext never touches disk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/apps/cf-playground/ocir-pull-sealed.yaml"
die() { echo "error: $*" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
for c in kubeseal jq; do command -v "$c" >/dev/null || die "$c not found"; done

src="$(kubectl -n coding-box get secret ocir-pull -o json 2>/dev/null || true)"
[ -n "$src" ] || die "no live coding-box/ocir-pull Secret to copy"
jq '{apiVersion, kind, type, data, metadata: {name: "ocir-pull", namespace: "cf-playground"}}' <<<"$src" \
  | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
      --format yaml > "$OUT"
[ -s "$OUT" ] || die "kubeseal produced no output for $OUT"
echo "wrote ${OUT#"$ROOT/"}"
