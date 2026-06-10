#!/usr/bin/env bash
# Audit wildcard TLS secret propagation via Reflector.
# Exits 0 when all expected namespaces have Reflector-managed copies with matching cert content.
# Exits 1 when orphans, missing secrets, or certificate mismatch detected.
set -euo pipefail

SECRET_NAME="wildcard-artr-com-br-tls"
SOURCE_NS="cert-manager"
EXPECTED_NAMESPACES=(
  argocd
  staging
  production
  platform
  monitoring
  sitio-staging
  sitio-production
)

EXPECTED_REFLECTS="${SOURCE_NS}/${SECRET_NAME}"

errors=0

cert_not_after() {
  local ns="$1"
  kubectl get secret -n "${ns}" "${SECRET_NAME}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -enddate 2>/dev/null \
    | sed 's/notAfter=//'
}

if ! kubectl get secret -n "${SOURCE_NS}" "${SECRET_NAME}" &>/dev/null; then
  echo "ERROR: source secret ${SOURCE_NS}/${SECRET_NAME} not found"
  exit 1
fi

source_expiry="$(cert_not_after "${SOURCE_NS}")"
echo "Source secret ${SOURCE_NS}/${SECRET_NAME} expires: ${source_expiry}"
echo

for ns in "${EXPECTED_NAMESPACES[@]}"; do
  if ! kubectl get secret -n "${ns}" "${SECRET_NAME}" &>/dev/null; then
    echo "ERROR: ${ns}/${SECRET_NAME} — missing"
    errors=$((errors + 1))
    continue
  fi

  reflects="$(kubectl get secret -n "${ns}" "${SECRET_NAME}" \
    -o jsonpath='{.metadata.annotations.reflector\.v1\.k8s\.emberstack\.com/reflects}' 2>/dev/null || true)"
  cm_cert="$(kubectl get secret -n "${ns}" "${SECRET_NAME}" \
    -o jsonpath='{.metadata.annotations.cert-manager\.io/certificate-name}' 2>/dev/null || true)"
  ns_expiry="$(cert_not_after "${ns}")"

  if [[ -n "${cm_cert}" && -z "${reflects}" ]]; then
    echo "ERROR: ${ns}/${SECRET_NAME} — orphan cert-manager secret (not Reflector-managed)"
    errors=$((errors + 1))
  elif [[ "${reflects}" != "${EXPECTED_REFLECTS}" ]]; then
    echo "ERROR: ${ns}/${SECRET_NAME} — reflects=${reflects:-<none>}, expected ${EXPECTED_REFLECTS}"
    errors=$((errors + 1))
  elif [[ "${ns_expiry}" != "${source_expiry}" ]]; then
    echo "ERROR: ${ns}/${SECRET_NAME} — cert expires ${ns_expiry}, source expires ${source_expiry}"
    errors=$((errors + 1))
  else
    echo "OK:    ${ns}/${SECRET_NAME} — Reflector copy matches source (expires ${ns_expiry})"
  fi
done

echo
if [[ "${errors}" -gt 0 ]]; then
  echo "Audit failed with ${errors} issue(s). See docs/certificate-runbook.md"
  exit 1
fi

echo "All ${#EXPECTED_NAMESPACES[@]} namespaces have valid Reflector-managed TLS secrets."
