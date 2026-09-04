#!/usr/bin/env bash
# reseal-pi-auth.sh — add/rotate API keys in the `pi-auth` SealedSecret
# (artieeez/artr-gitops, namespace `pi`) without a key ever touching the
# shell, history, or disk in plaintext.
#
# Two kinds of key live in this secret:
#   auth.json  providers (opencode-go, deepseek, google)  -> auth.json entry
#   env keys   e.g. DEEPINFRA_API_KEY (custom providers    -> sibling data key
#              resolve "$VAR" from process env on the box)    wired to Deployment env
#
# The merge always starts from the LIVE cluster secret (whatever is currently
# decrypted there), so nothing already present is lost — but for that reason
# run all desired key changes in ONE invocation before pushing (otherwise the
# next run would start from the pre-sync secret again).
#
#   ./reseal-pi-auth.sh                google + DEEPINFRA_API_KEY (default need)
#   ./reseal-pi-auth.sh google         just an auth.json provider
#   ./reseal-pi-auth.sh --env NAME     just a raw env data key
#
# Steps: read -s prompts -> merge over the live secret -> kubeseal over stdin
# -> diff -> install on confirmation.
set -euo pipefail

# Operate on apps/pi/ (where pi-auth-sealed.yaml lives), wherever we're invoked
# from — scripts/reseal-pi-auth.sh or any other cwd.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/apps/pi"
die() { echo "error: $*" >&2; exit 1; }

# --- safety: we must be talking to the oracle-cluster ----------------------
CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
kubectl get secret pi-auth -n pi >/dev/null || die "secret pi-auth/pi not found"

# --- fetch the CURRENT plaintext secret (all data keys) ---------------------
SECRET_JSON="$(kubectl get secret pi-auth -n pi -o json)"
AUTH="$(printf '%s' "$SECRET_JSON" | jq -r '.data["auth.json"]? // ""' | base64 -d 2>/dev/null || true)"
[ -n "$AUTH" ] || AUTH="{}"
# any non-auth.json data keys currently in the secret (e.g. DEEPINFRA_API_KEY)
ENV_JSON="$(printf '%s' "$SECRET_JSON" | jq --argjson skip '["auth.json"]' \
  '[.data | to_entries[] | select(.key as $k | $skip | index($k) | not)] |
   map({key: .key, value: (.value | @base64d)}) | from_entries // {}' 2>/dev/null || echo '{}')"

# --- decide what to prompt for ----------------------------------------------
ask_key() { # $1 label — echoes ONLY the key on stdout (captured via $(...))
  local label=$1 val
  read -rsp "Paste ${label}: " val
  printf '\n' >&2              # move cursor past the silent prompt
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$val" ] || die "empty key for ${label}"
  printf '%s' "$val"
}

MODE="${1:-default}"
case "$MODE" in
  default)
    GOOGLE_KEY="$(ask_key 'google (Gemini) API key')"
    [[ "$GOOGLE_KEY" == AIza* ]] || echo "note: google key doesn't start with AIza — sealing anyway"
    AUTH="$(printf '%s' "$AUTH" | jq --arg k "$GOOGLE_KEY" '.google = {"type":"api_key","key":$k}')"
    DEEPINFRA_KEY="$(ask_key 'DeepInfra API key')"
    ENV_JSON="$(printf '%s' "$ENV_JSON" | jq --arg k "$DEEPINFRA_KEY" '.DEEPINFRA_API_KEY = $k')"
    SUMMARY="google (auth.json) + DEEPINFRA_API_KEY"
    ;;
  --env)
    NAME="${2:-}"
    [ -n "$NAME" ] || die "usage: reseal-pi-auth.sh --env NAME"
    VAL="$(ask_key "$NAME")"
    ENV_JSON="$(printf '%s' "$ENV_JSON" | jq --arg v "$VAL" --arg n "$NAME" '.[$n] = $v')"
    SUMMARY="$NAME"
    ;;
  *)
    PROVIDER="$MODE"
    KEY="$(ask_key "$PROVIDER API key")"
    AUTH="$(printf '%s' "$AUTH" | jq --arg p "$PROVIDER" --arg k "$KEY" '.[$p] = {"type":"api_key","key":$k}')"
    SUMMARY="$PROVIDER (auth.json)"
    ;;
esac

# --- sanity --------------------------------------------------------------
printf '%s' "$AUTH" | jq -e 'type == "object"' >/dev/null || die "auth.json is not an object"
printf '%s' "$ENV_JSON" | jq -e 'type == "object"' >/dev/null || die "env keys invalid"

# --- seal over stdin: plaintext never written to disk ----------------------
# kubeseal fetches the controller's public cert over the cluster.
jq -n --arg auth "$AUTH" --argjson env "$ENV_JSON" \
  '{apiVersion:"v1", kind:"Secret", type:"Opaque",
    metadata:{name:"pi-auth", namespace:"pi"},
    stringData: ({"auth.json": $auth} + ($env | with_entries(.value |= tostring)))}' \
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
echo "new sealed file: apps/pi/pi-auth-sealed.new.yaml  ($SUMMARY)"
echo "diff vs current (ciphertext lines only should change/add):"
diff -u pi-auth-sealed.yaml pi-auth-sealed.new.yaml || true

read -r -p "Install over pi-auth-sealed.yaml? [y/N] " yesno
case "$yesno" in
  y|Y) mv pi-auth-sealed.new.yaml pi-auth-sealed.yaml
       echo "installed. Next:"
       echo "  git add apps/pi/pi-auth-sealed.yaml"
       echo "  git commit -m \"chore(pi): seal $SUMMARY\""
       echo "  git push"
       echo "  # after Argo syncs app 'pi': kubectl rollout restart deployment/pi -n pi"
       echo "  ssh pi-cloud 'jq keys ~/.pi/agent/auth.json'   # verify providers"
       ;;
  *) echo "left as pi-auth-sealed.new.yaml — nothing changed." ;;
esac
