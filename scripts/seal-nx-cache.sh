#!/usr/bin/env bash
# seal-nx-cache.sh — seal the Nx remote cache's per-repository tokens
# (Secret platform/nx-cache-tokens, key AUTH_TOKENS = "name:token,name:token").
#
#   ./scripts/seal-nx-cache.sh NAME [NAME…]
#
# The names you pass are the full set: a name left out loses its token.
# Names: letters, digits, _ and - (each gets its own /data/<name>/ folder).
# A name that already has a token in the live Secret keeps it; a new name
# gets a random token, printed once so you can store it as the repo's
# NX_SELF_HOSTED_REMOTE_CACHE_ACCESS_TOKEN. ROTATE="a b" (space/comma-
# separated) generates new tokens for those names too.
# Plaintext lives only in a temp dir removed on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/apps/platform/nx-cache/nx-cache-tokens-sealed.yaml"
NS=platform
SECRET=nx-cache-tokens
die() { echo "error: $*" >&2; exit 1; }

[ $# -gt 0 ] || die "usage: $0 NAME [NAME…]"
CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
command -v kubeseal >/dev/null || die "kubeseal not found"
command -v jq >/dev/null || die "jq not found"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Live tokens, one "name:token" per line (empty if the Secret does not exist).
kubectl -n "$NS" get secret "$SECRET" -o json 2>/dev/null \
  | jq -r '.data.AUTH_TOKENS // empty' | base64 -d | tr ',' '\n' > "$TMP/live" || : > "$TMP/live"

ROTATE_LIST=" $(tr ',' ' ' <<<"${ROTATE:-}") "
pairs=()
for name in "$@"; do
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name '$name' (letters, digits, _ and - only)"
  token="$(awk -F: -v n="$name" '$1 == n { sub(/^[^:]*:/, ""); print; exit }' "$TMP/live")"
  if [ -z "$token" ] || [[ "$ROTATE_LIST" == *" $name "* ]]; then
    token="$(openssl rand -hex 32)"
    echo "$name: NEW token (store it now, it is not shown again):"
    echo "  $token"
  else
    echo "$name: keeping live token"
  fi
  pairs+=("$name:$token")
done

AUTH_TOKENS="$(IFS=,; echo "${pairs[*]}")"
kubectl create secret generic "$SECRET" -n "$NS" \
  --from-literal=AUTH_TOKENS="$AUTH_TOKENS" --dry-run=client -o json \
  | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
      --format yaml > "$OUT"
[ -s "$OUT" ] || die "kubeseal produced no output"
echo "wrote ${OUT#"$ROOT/"}"
