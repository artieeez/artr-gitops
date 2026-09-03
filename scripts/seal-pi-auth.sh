#!/usr/bin/env bash
# Seal the pi box's model auth (opencode-go API key) into apps/pi/pi-auth-sealed.yaml.
#
# Usage:
#   ./scripts/seal-pi-auth.sh            # prompts (hidden input) for the key
#   OPENCODE_API_KEY=... ./scripts/seal-pi-auth.sh   # non-interactive (CI/automation)
#
# Output: apps/pi/pi-auth-sealed.yaml (SealedSecret, namespace pi, key auth.json).
# Plaintext lives only in a temp dir that is deleted on exit; nothing is printed.
#
# Requires: kubeseal + access to the sealed-secrets controller (oracle-cluster context).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_DIR}/apps/pi/pi-auth-sealed.yaml"

command -v kubeseal >/dev/null || { echo "kubeseal not found" >&2; exit 1; }

# 1. Get the key: env (scriptable) or hidden interactive prompt
KEY="${OPENCODE_API_KEY:-}"
if [ -z "$KEY" ]; then
  read -r -s -p "opencode-go API key: " KEY
  echo
fi
if [ -z "$KEY" ]; then
  echo "no key provided — aborting" >&2
  exit 1
fi

# 2. Build the plaintext Secret ({opencode-go: {type: api_key, key: <KEY>}})
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OPENCODE_API_KEY="$KEY" python3 - "$TMP" <<'PYEOF'
import base64, json, os, sys

key = os.environ["OPENCODE_API_KEY"]
payload = json.dumps({"opencode-go": {"type": "api_key", "key": key}}).encode()
secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "pi-auth", "namespace": "pi"},
    "type": "Opaque",
    "data": {"auth.json": base64.b64encode(payload).decode()},
}
with open(f"{sys.argv[1]}/pi-auth-secret.yaml", "w") as f:
    json.dump(secret, f, indent=2)
PYEOF

# 3. Seal against the live controller
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets --format yaml \
  < "$TMP/pi-auth-secret.yaml" > "$OUT"

echo "sealed -> ${OUT#"${REPO_DIR}"/}"
echo "encrypted entries: $(grep -cE '^\s{4}[a-zA-Z0-9_.]+:' "$OUT")"