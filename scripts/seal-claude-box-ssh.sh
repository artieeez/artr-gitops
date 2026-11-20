#!/usr/bin/env bash
# seal-claude-box-ssh.sh — seal the `claude-box-ssh` Secret (namespace hermes):
#   authorized_keys            who may `ssh claude-box` (Mac + phone)
#   ssh_host_ed25519_key(.pub) the sidecar's host key (stable fingerprint)
#
#   ./scripts/seal-claude-box-ssh.sh                  keys from the retired pi box (NFS)
#   ./scripts/seal-claude-box-ssh.sh path/to/authorized_keys
#
# Default source: the retired pi box's home on the NFS server. pi's entrypoint
# copied the sealed authorized_keys to /root/.ssh (= the pi-home PVC). nfs-client
# uses pathPattern ${namespace}/${pvc} + reclaimPolicy Retain, so the directory
# survived the namespace deletion untouched at /exports/pi/pi-home.
# The host key is reused from the live Secret (stable fingerprint) when it
# exists; NEW_HOST_KEY=1 (or no live Secret) generates a new one, which changes
# the fingerprint (clients must update known_hosts). Temp dir removed on exit.
#
# Add a key (e.g. the Herdr phone app's) without touching the others:
#   kubectl -n hermes get secret claude-box-ssh -o jsonpath='{.data.authorized_keys}' \
#     | base64 -d > /tmp/ak && echo 'ssh-ed25519 AAAA… herdr-phone' >> /tmp/ak
#   ./scripts/seal-claude-box-ssh.sh /tmp/ak
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/apps/hermes/claude-box-ssh-sealed.yaml"
die() { echo "error: $*" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "oracle-cluster" ] || die "kubectl context is '$CTX', expected 'oracle-cluster'"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "${1:-}" ]; then
  [ -f "$1" ] || die "no such file: $1"
  cp "$1" "$TMP/authorized_keys"
else
  NFS="$(kubectl -n platform get pod -l app=nfs-server -o name | head -1)"
  [ -n "$NFS" ] || die "nfs-server pod not found in namespace platform"
  kubectl -n platform exec "$NFS" -c nfs-server -- \
    cat /exports/pi/pi-home/.ssh/authorized_keys > "$TMP/authorized_keys" \
    || die "could not read /exports/pi/pi-home/.ssh/authorized_keys — pass a file instead"
fi

grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com) ' "$TMP/authorized_keys" \
  > "$TMP/authorized_keys.clean" || die "no public keys found"
echo "authorized keys:"
ssh-keygen -lf "$TMP/authorized_keys.clean" | sed 's/^/  /'

LIVE="$(kubectl -n hermes get secret claude-box-ssh -o json 2>/dev/null || true)"
if [ "${NEW_HOST_KEY:-0}" != 1 ] && [ -n "$LIVE" ]; then
  jq -r '.data.ssh_host_ed25519_key' <<<"$LIVE" | base64 -d > "$TMP/ssh_host_ed25519_key"
  jq -r '.data["ssh_host_ed25519_key.pub"]' <<<"$LIVE" | base64 -d > "$TMP/ssh_host_ed25519_key.pub"
  chmod 600 "$TMP/ssh_host_ed25519_key"
  ssh-keygen -y -f "$TMP/ssh_host_ed25519_key" >/dev/null || die "live host key is unreadable; re-run with NEW_HOST_KEY=1"
  echo "kept host key: $(ssh-keygen -lf "$TMP/ssh_host_ed25519_key.pub")"
else
  ssh-keygen -q -t ed25519 -N '' -C 'claude-box (hermes)' -f "$TMP/ssh_host_ed25519_key"
  echo "new host key: $(ssh-keygen -lf "$TMP/ssh_host_ed25519_key.pub")"
fi

jq -n \
  --rawfile ak "$TMP/authorized_keys.clean" \
  --rawfile hk "$TMP/ssh_host_ed25519_key" \
  --rawfile hkp "$TMP/ssh_host_ed25519_key.pub" \
  '{apiVersion:"v1", kind:"Secret", type:"Opaque",
    metadata:{name:"claude-box-ssh", namespace:"hermes"},
    stringData:{"authorized_keys":$ak, "ssh_host_ed25519_key":$hk,
                "ssh_host_ed25519_key.pub":$hkp}}' \
  | kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets \
             --format yaml > "$OUT"

[ -s "$OUT" ] || die "kubeseal produced no output"
echo "wrote ${OUT#"$ROOT/"}"
