#!/usr/bin/env bash
# Create an OCI Customer Secret Key for the append-only backup user and seal it
# (cluster-wide scope) into apps/app-backups/base/s3-credentials-sealed.yaml.
#
# The plaintext key never touches disk or stdout: it flows from the OCI CLI
# straight into kubeseal.
#
# Usage: scripts/seal-app-backup-credentials.sh <app_backup_writer_user_ocid>
#   (the OCID is `terraform output -raw app_backup_writer_user_id` in oracle-cluster)
# Needs: oci CLI with admin rights, kubectl pointed at the cluster, kubeseal, jq.
set -euo pipefail

user_id="${1:?usage: $0 <app_backup_writer_user_ocid>}"
out="$(git rev-parse --show-toplevel)/apps/app-backups/base/s3-credentials-sealed.yaml"
display_name="app-backups-$(date -u +%Y%m%d)"

key_json="$(oci iam customer-secret-key create --user-id "$user_id" \
  --display-name "$display_name" --output json)"

{
  cat <<HEADER
# Append-only OCI Customer Secret Key for the app-backup-* CronJobs
# (user: oke-cluster-app-backup-writer, display name: ${display_name}).
# Sealed with --scope cluster-wide so it unseals in every namespace that
# includes apps/app-backups/base. Regenerate with
# scripts/seal-app-backup-credentials.sh; see docs/app-backups.md.
---
HEADER
  jq -r '.data | {apiVersion: "v1", kind: "Secret",
      metadata: {name: "app-backup-s3-credentials"},
      stringData: {"access-key-id": .id, "secret-access-key": .key}}' <<<"$key_json" |
    kubeseal --format yaml --scope cluster-wide \
      --controller-namespace sealed-secrets --controller-name sealed-secrets
} >"$out"
unset key_json

echo "Wrote $out (key display name: $display_name)."
echo "Delete the previous key in OCI if this is a rotation."
