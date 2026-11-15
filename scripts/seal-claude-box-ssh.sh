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
# A NEW host key is generated in a temp dir, sealed, and the temp dir removed —
# re-running changes the fingerprint (clients must update known_hosts).
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

ssh-keygen -q -t ed25519 -N '' -C 'claude-box (hermes)' -f "$TMP/ssh_host_ed25519_key"
echo "new host key: $(ssh-keygen -lf "$TMP/ssh_host_ed25519_key.pub")"

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
