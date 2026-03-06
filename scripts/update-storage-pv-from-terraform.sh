#!/usr/bin/env bash
# Updates apps/platform/storage/block-pv.yaml with db_volume_id and
# db_volume_availability_domain from Terraform output. Run from artr-gitops repo root.
# Usage: ./scripts/update-storage-pv-from-terraform.sh [path-to-terraform-dir]
# Example: ./scripts/update-storage-pv-from-terraform.sh ../terraform-files/oracle-cluster

set -e
TERRAFORM_DIR="${1:-../terraform-files/oracle-cluster}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PV_FILE="${PV_FILE:-apps/platform/storage/block-pv.yaml}"

VOLUME_OCID=$(terraform -chdir="$TERRAFORM_DIR" output -raw db_volume_id 2>/dev/null) || { echo "Run from repo root and point to oracle-cluster Terraform dir (e.g. $TERRAFORM_DIR)."; exit 1; }
AVAILABILITY_DOMAIN=$(terraform -chdir="$TERRAFORM_DIR" output -raw db_volume_availability_domain 2>/dev/null) || { echo "Could not read db_volume_availability_domain."; exit 1; }

if [[ "$(uname)" = Darwin ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi
sed "${SED_INPLACE[@]}" "s|VOLUME_OCID_PLACEHOLDER|$VOLUME_OCID|g" "$PV_FILE"
sed "${SED_INPLACE[@]}" "s|AVAILABILITY_DOMAIN_PLACEHOLDER|$AVAILABILITY_DOMAIN|g" "$PV_FILE"
echo "Updated $PV_FILE with db_volume_id and db_volume_availability_domain from Terraform."
