#!/usr/bin/env bash
# Updates charts/traefik-values.yaml with public_subnet_id and reserved_public_ip_address
# from Terraform output. Run from artr-gitops repo root.
# Usage: ./scripts/update-traefik-oci-from-terraform.sh [path-to-terraform-dir]
# Example: ./scripts/update-traefik-oci-from-terraform.sh ../terraform-files/oracle-cluster

set -e
TERRAFORM_DIR="${1:-../terraform-files/oracle-cluster}"
VALUES_FILE="${VALUES_FILE:-charts/traefik-values.yaml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SUBNET=$(terraform -chdir="$TERRAFORM_DIR" output -raw public_subnet_id 2>/dev/null) || { echo "Run from repo root and point to oracle-cluster Terraform dir (e.g. $TERRAFORM_DIR)."; exit 1; }
RESERVED_IP=$(terraform -chdir="$TERRAFORM_DIR" output -raw reserved_public_ip_address 2>/dev/null) || true

if [[ "$(uname)" = Darwin ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi
sed "${SED_INPLACE[@]}" "s|oci-network-load-balancer.oraclecloud.com/subnet: \".*\"|oci-network-load-balancer.oraclecloud.com/subnet: \"$SUBNET\"|" "$VALUES_FILE"
if [[ -n "$RESERVED_IP" ]]; then
  sed "${SED_INPLACE[@]}" "s|oci.oraclecloud.com/reserved-ips: \".*\"|oci.oraclecloud.com/reserved-ips: \"$RESERVED_IP\"|" "$VALUES_FILE"
fi
echo "Updated $VALUES_FILE with public_subnet_id and reserved_public_ip from Terraform."
