#!/usr/bin/env bash
# seal-hermes-ocir-pull.sh — one-off: seal the OCIR pull credentials for the
# `hermes` namespace (claude-box runs the private pi-cloud image).
#
# SealedSecrets are namespace-scoped, so apps/pi/ocir-pull-sealed.yaml can't be
# reused. This copies the LIVE `ocir-pull` Secret from namespace `pi` — run it
# BEFORE the pi app/namespace is pruned. The plaintext only flows through a
# pipe (kubectl -> jq -> kubeseal); nothing is written unencrypted.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/apps/hermes"
die() { echo "error: $*" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
kubectl get secret ocir-pull -n pi >/dev/null 2>&1 \
  || die "secret ocir-pull/pi not found (already retired?) — recreate it with kubectl create secret docker-registry"

kubectl get secret ocir-pull -n pi -o json \
  | jq '{apiVersion, kind, type, data,
         metadata: {name: "ocir-pull", namespace: "hermes"}}' \
  | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
             --format yaml \
  > ocir-pull-sealed.yaml

[ -s ocir-pull-sealed.yaml ] || die "kubeseal produced no output"
echo "wrote apps/hermes/ocir-pull-sealed.yaml (namespace hermes)"
