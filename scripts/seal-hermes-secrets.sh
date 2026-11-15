#!/usr/bin/env bash
# seal-hermes-secrets.sh — create/rotate the `hermes-secrets` SealedSecret
# (namespace `hermes`) without a value ever touching the shell history or disk
# in plaintext: read -s prompts -> merge over the LIVE secret (if any) ->
# kubeseal over stdin -> diff -> install on confirmation.
#
#   ./scripts/seal-hermes-secrets.sh            prompt for every key (bootstrap)
#   ./scripts/seal-hermes-secrets.sh KEY [...]  rotate only these keys
#
# Do all key changes in ONE run before pushing: each run merges over the live
# cluster secret, so a second run before Argo syncs would drop the first run.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/apps/hermes"
die() { echo "error: $*" >&2; exit 1; }

ALL_KEYS=(
  DEEPSEEK_API_KEY
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  SLACK_ALLOWED_USERS
  GH_TOKEN
  LINEAR_API_KEY
  GRAFANA_SERVICE_ACCOUNT_TOKEN
  HERMES_DASHBOARD_OIDC_CLIENT_ID
  HERMES_DASHBOARD_SESSION_TOKEN
  CLAUDE_CODE_OAUTH_TOKEN
)

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"

# Current values (empty object on first run).
CURRENT='{}'
if kubectl get secret hermes-secrets -n hermes >/dev/null 2>&1; then
  CURRENT="$(kubectl get secret hermes-secrets -n hermes -o json \
    | jq '.data | map_values(@base64d)')"
fi

if [ "$#" -gt 0 ]; then KEYS=("$@"); else KEYS=("${ALL_KEYS[@]}"); fi

ask() { # $1 key name — echoes only the value
  local val
  read -rsp "Paste $1: " val
  printf '\n' >&2
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$val" ] || die "empty value for $1"
  printf '%s' "$val"
}

DATA="$CURRENT"
for k in "${KEYS[@]}"; do
  v="$(ask "$k")"
  case "$k" in
    SLACK_BOT_TOKEN) [[ "$v" == xoxb-* ]] || echo "note: $k doesn't start with xoxb-" ;;
    SLACK_APP_TOKEN) [[ "$v" == xapp-* ]] || echo "note: $k doesn't start with xapp-" ;;
    GH_TOKEN) [[ "$v" == github_pat_* ]] || echo "note: $k is not a fine-grained PAT" ;;
    HERMES_DASHBOARD_SESSION_TOKEN) [ "${#v}" -ge 32 ] || echo "note: $k is short — use \`openssl rand -base64 32\`" ;;
    CLAUDE_CODE_OAUTH_TOKEN) [[ "$v" == sk-ant-oat* ]] || echo "note: $k doesn't look like a \`claude setup-token\` token" ;;
  esac
  DATA="$(printf '%s' "$DATA" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')"
done

for k in "${ALL_KEYS[@]}"; do
  printf '%s' "$DATA" | jq -e --arg k "$k" 'has($k)' >/dev/null \
    || die "missing $k (first run must set every key)"
done

jq -n --argjson data "$DATA" \
  '{apiVersion:"v1", kind:"Secret", type:"Opaque",
    metadata:{name:"hermes-secrets", namespace:"hermes"},
    stringData:$data}' \
  | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
             --format yaml \
  > hermes-secrets-sealed.new.yaml
[ -s hermes-secrets-sealed.new.yaml ] || die "kubeseal produced no output"

echo
if [ -f hermes-secrets-sealed.yaml ]; then
  diff -u hermes-secrets-sealed.yaml hermes-secrets-sealed.new.yaml || true
else
  echo "first seal: apps/hermes/hermes-secrets-sealed.yaml will be created"
fi

read -r -p "Install as hermes-secrets-sealed.yaml? [y/N] " yesno
case "$yesno" in
  y|Y) mv hermes-secrets-sealed.new.yaml hermes-secrets-sealed.yaml
       echo "installed. Commit + push; after Argo syncs:"
       echo "  kubectl rollout restart deployment/hermes -n hermes" ;;
  *) echo "left as hermes-secrets-sealed.new.yaml — nothing changed." ;;
esac
