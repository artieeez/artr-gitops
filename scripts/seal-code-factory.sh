#!/usr/bin/env bash
# seal-code-factory.sh — seal code-factory's Secrets (namespace code-factory):
#   cf-postgres        password + url (DATABASE_URL) for the server's database
#   cf-server          CF_SECRETS_KEY, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, and the plugin
#                      secrets once factory.yaml enables them (LINEAR_*, GITHUB_*)
#   cf-worker-dogfood  CF_WORKER_TOKEN (Workers page / `cf worker create`); no GitHub key, the
#                      server mints the worker's tokens with the App's (AD-072)
#   ocir-pull          OCIR pull credentials, copied from coding-box's live Secret
#
#   ./scripts/seal-code-factory.sh                 all four
#   ./scripts/seal-code-factory.sh postgres|server|worker|ocir
#
# Values come from the live code-factory Secret first, so a re-seal loses nothing. Missing
# ones are generated (postgres password, CF_SECRETS_KEY) or prompted (hidden); an empty answer
# to an optional key leaves it out. ROTATE=1 prompts for every prompted key again.
# CF_SECRETS_KEY is never rotated here: a new key cannot open the agent accounts the old one
# sealed. Plaintext lives only in a temp dir removed on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/apps/code-factory"
NS=code-factory
die() { echo "error: $*" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
command -v kubeseal >/dev/null || die "kubeseal not found"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WHAT="${1:-all}"
case "$WHAT" in all|postgres|server|worker|ocir) ;; *) die "unknown target '$WHAT' (all|postgres|server|worker|ocir)" ;; esac

secret_json() { kubectl -n "$1" get secret "$2" -o json 2>/dev/null || true; }
key_of() { jq -r --arg k "$2" '.data[$k] // empty' <<<"$1" | base64 -d; }

seal() { # seal OUT_FILE  (Secret JSON on stdin)
  kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
    --format yaml > "$1"
  [ -s "$1" ] || die "kubeseal produced no output for $1"
  echo "wrote ${1#"$ROOT/"}"
}

# value LIVE_JSON KEY required|optional -> the live value, else a hidden prompt
value() {
  local live="$1" key="$2" need="$3" v=""
  [ "${ROTATE:-0}" = 1 ] || v="$(key_of "$live" "$key")"
  if [ -z "$v" ]; then
    read -r -s -p "$key ($need): " v </dev/tty; echo >&2
    [ -n "$v" ] || [ "$need" = optional ] || die "$key is required"
  fi
  printf '%s' "$v"
}

# secret NAME DIR KEY=VALUE... -> sealed file, skipping empty values
secret() {
  local name="$1" dir="$2"; shift 2
  local args=()
  for kv in "$@"; do [ -n "${kv#*=}" ] && args+=("--from-literal=$kv"); done
  kubectl create secret generic "$name" -n "$NS" "${args[@]}" --dry-run=client -o json \
    | seal "$dir/$name-sealed.yaml"
}

seal_postgres() {
  local live pw
  live="$(secret_json "$NS" cf-postgres)"
  pw="$(key_of "$live" password)"
  [ -n "$pw" ] || pw="$(openssl rand -hex 24)"
  secret cf-postgres "$OUT_DIR/platform/postgres" \
    "password=$pw" "url=postgresql://cf:$pw@cf-postgres.code-factory.svc.cluster.local:5432/cf"
}

seal_server() {
  local live key
  live="$(secret_json "$NS" cf-server)"
  key="$(key_of "$live" CF_SECRETS_KEY)"
  [ -n "$key" ] || key="$(openssl rand -base64 32)"
  secret cf-server "$OUT_DIR/platform/server" \
    "CF_SECRETS_KEY=$key" \
    "OIDC_CLIENT_ID=$(value "$live" OIDC_CLIENT_ID required)" \
    "OIDC_CLIENT_SECRET=$(value "$live" OIDC_CLIENT_SECRET required)" \
    "LINEAR_TEAM=$(value "$live" LINEAR_TEAM optional)" \
    "LINEAR_API_KEY=$(value "$live" LINEAR_API_KEY optional)" \
    "LINEAR_WEBHOOK_SECRET=$(value "$live" LINEAR_WEBHOOK_SECRET optional)" \
    "GITHUB_APP_ID=$(value "$live" GITHUB_APP_ID optional)" \
    "GITHUB_INSTALLATION_ID=$(value "$live" GITHUB_INSTALLATION_ID optional)" \
    "GITHUB_APP_SLUG=$(value "$live" GITHUB_APP_SLUG optional)" \
    "GITHUB_APP_PRIVATE_KEY=$(value "$live" GITHUB_APP_PRIVATE_KEY optional)" \
    "GITHUB_WEBHOOK_SECRET=$(value "$live" GITHUB_WEBHOOK_SECRET optional)"
}

seal_worker() {
  local live
  live="$(secret_json "$NS" cf-worker-dogfood)"
  secret cf-worker-dogfood "$OUT_DIR/workers/dogfood" \
    "CF_WORKER_TOKEN=$(value "$live" CF_WORKER_TOKEN required)"
}

seal_ocir() {
  local src
  src="$(secret_json coding-box ocir-pull)"
  [ -n "$src" ] || die "no live coding-box/ocir-pull Secret to copy"
  jq '{apiVersion, kind, type, data, metadata: {name: "ocir-pull", namespace: "code-factory"}}' <<<"$src" \
    | seal "$OUT_DIR/platform/ocir-pull-sealed.yaml"
}

case "$WHAT" in
  all) seal_postgres; seal_server; seal_worker; seal_ocir ;;
  postgres) seal_postgres ;;
  server) seal_server ;;
  worker) seal_worker ;;
  ocir) seal_ocir ;;
esac
