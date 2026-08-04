#!/usr/bin/env bash
# Download backup object and run PRAGMA integrity_check (does not touch live DB PVC).
set -euo pipefail

: "${OBJECT_KEY:?OBJECT_KEY required (e.g. staging/sitio-rails/production-20260101T060000Z.sqlite3.gz)}"
: "${BUCKET:?BUCKET required}"

# Match backup.sh — keep aws s3 downloads compatible with OCI Object Storage.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

WORK_DIR="${TMPDIR:-/tmp}"
TMP_GZ="${WORK_DIR}/sitio-verify-$$.sqlite3.gz"
TMP_DB="${WORK_DIR}/sitio-verify-$$.sqlite3"

cleanup() {
  rm -f "${TMP_GZ}" "${TMP_DB}"
}
trap cleanup EXIT

S3_URI="s3://${BUCKET}/${OBJECT_KEY}"

aws s3 cp "${S3_URI}" "${TMP_GZ}"

if [[ ! -s "${TMP_GZ}" ]]; then
  echo "ERROR: downloaded object is empty" >&2
  exit 1
fi

gunzip -c "${TMP_GZ}" > "${TMP_DB}"

result="$(sqlite3 "${TMP_DB}" "PRAGMA integrity_check;")"
if [[ "${result}" != "ok" ]]; then
  echo "ERROR: integrity_check failed: ${result}" >&2
  exit 1
fi

echo "OK: integrity_check passed for s3://${BUCKET}/${OBJECT_KEY}"
