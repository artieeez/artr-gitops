#!/usr/bin/env bash
# Nightly SQLite backup: VACUUM INTO → gzip → aws s3 cp to OCI Object Storage.
set -euo pipefail

: "${BACKUP_ENV:?BACKUP_ENV required}"
: "${BUCKET:?BUCKET required}"
: "${SQLITE_PATH:?SQLITE_PATH required}"

# OCI Object Storage rejects AWS CLI v2 default flexible checksums (aws-chunked PutObject).
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

WORK_DIR="${TMPDIR:-/tmp}"
TMP_DB="${WORK_DIR}/sitio-backup-$$.sqlite3"
TMP_GZ="${WORK_DIR}/sitio-backup-$$.sqlite3.gz"

cleanup() {
  rm -f "${TMP_DB}" "${TMP_GZ}"
}
trap cleanup EXIT

if [[ ! -f "${SQLITE_PATH}" ]]; then
  echo "ERROR: source database not found: ${SQLITE_PATH}" >&2
  exit 1
fi

if [[ ! -s "${SQLITE_PATH}" ]]; then
  echo "ERROR: source database is empty: ${SQLITE_PATH}" >&2
  exit 1
fi

sqlite3 "${SQLITE_PATH}" "VACUUM INTO '${TMP_DB}'"
gzip -c "${TMP_DB}" > "${TMP_GZ}"

if [[ ! -s "${TMP_GZ}" ]]; then
  echo "ERROR: compressed backup is empty" >&2
  exit 1
fi

UTC_TS="$(date -u +%Y%m%dT%H%M%SZ)"
OBJECT_KEY="${BACKUP_ENV}/sitio-rails/production-${UTC_TS}.sqlite3.gz"
S3_URI="s3://${BUCKET}/${OBJECT_KEY}"

aws s3 cp "${TMP_GZ}" "${S3_URI}"

echo "Uploaded ${S3_URI}"
