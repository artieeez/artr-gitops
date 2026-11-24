#!/usr/bin/env bash
# Re-seal the `ocir-pull` image pull Secret in every namespace that has one, with a new
# OCIR auth token (OCI Console → profile → Auth tokens). Use after rotating/expiring the token.
#
#   ./scripts/seal-ocir-pull.sh
#
# The username is read from the live coding-box/ocir-pull Secret (OCIR_USER overrides it);
# the token is prompted (hidden) and checked against the registry before anything is sealed.
# Plaintext lives only in a temp dir removed on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY=vcp.ocir.io
die() { echo "error: $*" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
for c in kubeseal jq curl; do command -v "$c" >/dev/null || die "$c not found"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

USER_NAME="${OCIR_USER:-}"
if [ -z "$USER_NAME" ]; then
  USER_NAME="$(kubectl -n coding-box get secret ocir-pull -o json 2>/dev/null \
    | jq -r --arg r "$REGISTRY" '.data[".dockerconfigjson"] | @base64d | fromjson
        | .auths[$r] | .username // ((.auth | @base64d) | split(":")[0]) // empty' || true)"
fi
[ -n "$USER_NAME" ] || die "could not read the OCIR username; set OCIR_USER=<tenancy-namespace>/<user>"
echo "user: $USER_NAME"

read -r -s -p "OCIR auth token: " TOKEN </dev/tty; echo >&2
[ -n "$TOKEN" ] || die "empty token"

# Validate before sealing: the registry's token endpoint answers 200 only for good credentials.
printf 'user = "%s:%s"\n' "$USER_NAME" "$TOKEN" > "$TMP/curl.cfg"
code="$(curl -s -o /dev/null -w '%{http_code}' -K "$TMP/curl.cfg" "https://$REGISTRY/20180419/docker/token")"
[ "$code" = 200 ] || die "registry rejected the credentials (HTTP $code); new tokens can take a minute to activate"
echo "token accepted by $REGISTRY"

jq -n --arg r "$REGISTRY" --arg u "$USER_NAME" --arg p "$TOKEN" \
  '{auths: {($r): {username: $u, password: $p, auth: ("\($u):\($p)" | @base64)}}}' > "$TMP/dockerconfig.json"

found=0
while IFS= read -r f; do
  ns="$(awk '/^  namespace:/ {print $2; exit}' "$f")"
  [ -n "$ns" ] || die "no namespace in $f"
  jq -n --arg ns "$ns" --rawfile d "$TMP/dockerconfig.json" \
    '{apiVersion: "v1", kind: "Secret", type: "kubernetes.io/dockerconfigjson",
      metadata: {name: "ocir-pull", namespace: $ns},
      stringData: {".dockerconfigjson": $d}}' \
    | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
        --format yaml > "$f.new"
  [ -s "$f.new" ] || die "kubeseal produced no output for $f"
  mv "$f.new" "$f"
  echo "wrote ${f#"$ROOT/"} ($ns)"
  found=$((found + 1))
done < <(find "$ROOT/apps" -name 'ocir-pull-sealed.yaml' | sort)
[ "$found" -gt 0 ] || die "no ocir-pull-sealed.yaml files found"
