#!/usr/bin/env bash
# reseal-pi-auth.sh — add/rotate a model provider API key in the `pi-auth`
# SealedSecret (artieeez/artr-gitops, namespace `pi`) without the key ever
# touching the shell, history, or disk in plaintext.
#
#   - prompts for the key with `read -s` (no echo, no history)
#   - pulls the current entries (e.g. opencode-go) from the LIVE cluster
#     Secret so nothing is lost
#   - merges the new key in, seals via the in-cluster controller over stdin
#     (plaintext exists only in memory)
#   - writes apps/pi/pi-auth-sealed.new.yaml and diffs it against the current
#     file for review (only the ciphertext line should differ)
#   - on confirmation, installs it over pi-auth-sealed.yaml
#
# Usage: ./reseal-pi-auth.sh [provider]
#   provider defaults to `deepseek`; anything else maps to the same auth.json
#   shape {"<provider>": {"type": "api_key", "key": "..."}}.
set -euo pipefail

PROVIDER="${1:-deepseek}"
cd "$(dirname "$0")"                     # apps/pi

die() { echo "error: $*" >&2; exit 1; }

# --- safety: we must be talking to the oracle-cluster ----------------------
CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
kubectl get secret pi-auth -n pi >/dev/null || die "secret pi-auth/pi not found"

# --- prompt for the key (no echo) ------------------------------------------
read -rsp "Paste $PROVIDER API key: " KEY
echo
[ -n "$KEY" ] || die "empty key"
case "$PROVIDER" in
  deepseek)  [[ "$KEY" =~ ^sk- ]] || die "deepseek keys start with sk-" ;;
esac

# --- merge into the current auth.json (from the live secret) ----------------
AUTH="$(kubectl get secret pi-auth -n pi -o jsonpath='{.data.auth\.json}' | base64 -d)"
MERGED="$(printf '%s' "$AUTH" | jq --arg provider "$PROVIDER" --arg key "$KEY" \
  '.[$provider] = {"type": "api_key", "key": $key}')"
printf '%s' "$MERGED" | jq -e --arg provider "$PROVIDER" \
  '.[$provider].key | startswith("sk-")' >/dev/null \
  || die "merged auth.json failed sanity check"
printf '%s' "$MERGED" | jq -e 'keys | index("opencode-go")' >/dev/null \
  || echo "note: merged auth.json no longer contains opencode-go"

# --- seal over stdin: plaintext never written to disk -----------------------
# kubeseal fetches the controller's public cert over the cluster.
jq -n --arg auth "$MERGED" \
  '{apiVersion:"v1", kind:"Secret", type:"Opaque",
    metadata:{name:"pi-auth", namespace:"pi"},
    stringData:{"auth.json": $auth}}' \
  | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
             --format yaml \
  > pi-auth-sealed.new.yaml
[ -s pi-auth-sealed.new.yaml ] || die "kubeseal produced no output"

# normalize to the repo's convention: exactly one leading '---' marker if the
# current file has one (kubeseal already emits one — avoid doubling it).
sed -e '/^---$/d' pi-auth-sealed.new.yaml > pi-auth-sealed.new.yaml.tmp \
  && mv pi-auth-sealed.new.yaml.tmp pi-auth-sealed.new.yaml
if head -1 pi-auth-sealed.yaml | grep -q '^---$'; then
  { printf -- '---\n'; cat pi-auth-sealed.new.yaml; } > pi-auth-sealed.new.yaml.tmp \
    && mv pi-auth-sealed.new.yaml.tmp pi-auth-sealed.new.yaml
fi

# --- review ----------------------------------------------------------------
echo
echo "new sealed file: apps/pi/pi-auth-sealed.new.yaml  ($PROVIDER merged in)"
echo "diff vs current (only the auth.json ciphertext line should change):"
diff -u pi-auth-sealed.yaml pi-auth-sealed.new.yaml || true

read -r -p "Install over pi-auth-sealed.yaml? [y/N] " yesno
case "$yesno" in
  y|Y) mv pi-auth-sealed.new.yaml pi-auth-sealed.yaml
       echo "installed. Next:"
       echo "  git add apps/pi/pi-auth-sealed.yaml"
       echo "  git commit -m \"chore(pi): seal $PROVIDER api key\""
       echo "  git push"
       echo "  # then (after Argo syncs app 'pi'):"
       echo "  kubectl rollout restart deployment/pi -n pi"
       echo "  ssh pi-cloud 'jq keys ~/.pi/agent/auth.json'   # verify"
       ;;
  *) echo "left as pi-auth-sealed.new.yaml — nothing changed." ;;
esac
