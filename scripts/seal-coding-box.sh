#!/usr/bin/env bash
# seal-coding-box.sh — seal coding-box's three Secrets (namespace coding-box):
#   coding-box-ssh      authorized_keys (Mac, phone, Herdr apps) + sshd host key
#   coding-box-secrets  GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN
#   ocir-pull           OCIR pull credentials (private coding-box image)
#
#   ./scripts/seal-coding-box.sh                   all three
#   ./scripts/seal-coding-box.sh ssh [extra.pub…]  only coding-box-ssh, adding keys
#   ./scripts/seal-coding-box.sh secrets           only coding-box-secrets
#   ./scripts/seal-coding-box.sh ocir              only ocir-pull
#
# Values come from the live cluster, first match wins:
#   1. the live coding-box Secret (re-seal / add a key: nothing is lost)
#   2. the retired hermes namespace (one-time migration, while it still exists)
#   3. otherwise: secrets are prompted (hidden), the host key is generated
# Extra public-key files given after `ssh` are appended to authorized_keys —
# the ONLY durable way to add a key: the pod replaces ~/.ssh/authorized_keys
# from this Secret on every boot. NEW_HOST_KEY=1 forces a new host key;
# ROTATE=1 prompts for every token instead of reusing the live ones.
# Plaintext lives only in a temp dir removed on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/apps/coding-box"
NS=coding-box
die() { echo "error: $*" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"
command -v kubeseal >/dev/null || die "kubeseal not found"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WHAT="${1:-all}"
[ $# -gt 0 ] && shift
case "$WHAT" in all|ssh|secrets|ocir) ;; *) die "unknown target '$WHAT' (all|ssh|secrets|ocir)" ;; esac

# secret_json NAMESPACE NAME -> the Secret as JSON, or nothing
secret_json() { kubectl -n "$1" get secret "$2" -o json 2>/dev/null || true; }
# key_of JSON KEY -> decoded value, or nothing
key_of() { jq -r --arg k "$2" '.data[$k] // empty' <<<"$1" | base64 -d; }

seal() { # seal OUT_FILE  (Secret JSON on stdin)
  kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
    --format yaml > "$1"
  [ -s "$1" ] || die "kubeseal produced no output for $1"
  echo "wrote ${1#"$ROOT/"}"
}

seal_ssh() {
  local live old
  live="$(secret_json "$NS" coding-box-ssh)"
  old="$(secret_json hermes claude-box-ssh)"
  if [ -n "$live" ]; then key_of "$live" authorized_keys > "$TMP/ak"
  elif [ -n "$old" ]; then key_of "$old" authorized_keys > "$TMP/ak"; echo "authorized_keys: from hermes/claude-box-ssh"
  else : > "$TMP/ak"; fi
  for f in "$@"; do
    [ -f "$f" ] || die "no such file: $f"
    cat "$f" >> "$TMP/ak"
  done
  grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com) ' "$TMP/ak" \
    | awk '!seen[$1" "$2]++' > "$TMP/authorized_keys" || die "no public keys found (pass a .pub file)"
  echo "authorized keys:"
  ssh-keygen -lf "$TMP/authorized_keys" | sed 's/^/  /'

  if [ "${NEW_HOST_KEY:-0}" != 1 ] && [ -n "$live" ]; then
    key_of "$live" ssh_host_ed25519_key > "$TMP/hk"
    key_of "$live" ssh_host_ed25519_key.pub > "$TMP/hk.pub"
    chmod 600 "$TMP/hk"
    ssh-keygen -y -f "$TMP/hk" >/dev/null || die "live host key unreadable; re-run with NEW_HOST_KEY=1"
    echo "kept host key: $(ssh-keygen -lf "$TMP/hk.pub")"
  else
    ssh-keygen -q -t ed25519 -N '' -C 'coding-box' -f "$TMP/hk"
    echo "new host key: $(ssh-keygen -lf "$TMP/hk.pub") (clients must update known_hosts)"
  fi

  jq -n --arg ns "$NS" \
    --rawfile ak "$TMP/authorized_keys" --rawfile hk "$TMP/hk" --rawfile hkp "$TMP/hk.pub" \
    '{apiVersion:"v1", kind:"Secret", type:"Opaque",
      metadata:{name:"coding-box-ssh", namespace:$ns},
      stringData:{"authorized_keys":$ak, "ssh_host_ed25519_key":$hk,
                  "ssh_host_ed25519_key.pub":$hkp}}' \
    | seal "$OUT_DIR/coding-box-ssh-sealed.yaml"
}

seal_secrets() {
  local live old k v args=()
  live="$(secret_json "$NS" coding-box-secrets)"
  old="$(secret_json hermes hermes-secrets)"
  for k in GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
    v=""
    if [ "${ROTATE:-0}" != 1 ] && [ -n "$live" ]; then v="$(key_of "$live" "$k")"; fi
    if [ "${ROTATE:-0}" != 1 ] && [ -z "$v" ] && [ -n "$old" ]; then
      v="$(key_of "$old" "$k")"
      [ -n "$v" ] && echo "$k: from hermes/hermes-secrets"
    fi
    if [ -z "$v" ]; then
      read -r -s -p "$k: " v; echo
      [ -n "$v" ] || die "$k is empty"
    fi
    printf '%s' "$v" > "$TMP/$k"
    args+=(--rawfile "$k" "$TMP/$k")
  done
  jq -n --arg ns "$NS" "${args[@]}" \
    '{apiVersion:"v1", kind:"Secret", type:"Opaque",
      metadata:{name:"coding-box-secrets", namespace:$ns},
      stringData:{GH_TOKEN:$GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN:$CLAUDE_CODE_OAUTH_TOKEN}}' \
    | seal "$OUT_DIR/coding-box-secrets-sealed.yaml"
}

seal_ocir() {
  local src
  src="$(secret_json "$NS" ocir-pull)"
  [ -n "$src" ] || src="$(secret_json hermes ocir-pull)"
  [ -n "$src" ] || die "no live ocir-pull Secret in $NS or hermes to copy"
  key_of "$src" .dockerconfigjson > "$TMP/dockerconfig.json"
  jq -e '.auths["vcp.ocir.io"]' "$TMP/dockerconfig.json" >/dev/null || die "ocir-pull has no vcp.ocir.io auth"
  jq -n --arg ns "$NS" --rawfile d "$TMP/dockerconfig.json" \
    '{apiVersion:"v1", kind:"Secret", type:"kubernetes.io/dockerconfigjson",
      metadata:{name:"ocir-pull", namespace:$ns},
      stringData:{".dockerconfigjson":$d}}' \
    | seal "$OUT_DIR/ocir-pull-sealed.yaml"
}

case "$WHAT" in
  all) seal_ssh "$@"; seal_secrets; seal_ocir ;;
  ssh) seal_ssh "$@" ;;
  secrets) seal_secrets ;;
  ocir) seal_ocir ;;
esac
echo "commit the changed apps/coding-box/*-sealed.yaml; after Argo CD syncs:"
echo "  kubectl -n $NS rollout restart deployment/coding-box"
