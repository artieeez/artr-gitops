#!/usr/bin/env bash
# Shared nightly app backup -> OCI Object Storage (S3 compat).
# Key layout: s3://$BUCKET/$NAMESPACE/$APP/<UTC timestamp>.<ext>
#
# MODE=sqlite  one SQLite file ($SQLITE_FILE, relative to $DATA_DIR)
#              -> consistent copy -> integrity_check -> gzip   (.sqlite3.gz)
# MODE=tar     whole $DATA_DIR as tar.gz minus excludes (.tar.gz). Every SQLite
#              database found is replaced by a consistent, integrity-checked
#              copy when TAR_SQLITE_AUTO=true. Optional RCON quiesce for
#              Minecraft (RCON_HOST + RCON_PASSWORD).
#
# Required env: MODE NAMESPACE APP DATA_DIR  (+ SQLITE_FILE for MODE=sqlite)
# Optional env: BUCKET TAR_EXCLUDE_ROOT TAR_EXCLUDE_ANY TAR_SQLITE_AUTO
#               RCON_HOST RCON_PORT RCON_PASSWORD RCON_SAVE_CMD
#               SKIP_INSTALL AWS_ENDPOINT_URL (for local tests)
set -euo pipefail

: "${MODE:?MODE required (sqlite|tar)}"
: "${NAMESPACE:?NAMESPACE required}"
: "${APP:?APP required}"
: "${DATA_DIR:?DATA_DIR required}"
BUCKET="${BUCKET:-cluster-app-backups}"

# OCI Object Storage rejects AWS CLI v2 default flexible checksums (aws-chunked PutObject).
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

if [[ "${SKIP_INSTALL:-}" != "true" ]]; then
  # Runtime install, same trade-off as sitio-rails-backup (see docs/app-backups.md).
  dnf install -y -q sqlite awscli gzip tar findutils python3
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/app-backup.XXXXXX")"
STAGE="${WORK_DIR}/stage"
mkdir -p "${STAGE}"
RCON_QUIESCED=false

rcon() {
  python3 - "$@" <<'PY'
import os, socket, struct, sys

def pkt(i, t, body):
    p = struct.pack("<ii", i, t) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(p)) + p

def read(s):
    raw = b""
    while len(raw) < 4:
        c = s.recv(4 - len(raw))
        if not c:
            raise SystemExit("rcon: connection closed")
        raw += c
    n = struct.unpack("<i", raw)[0]
    data = b""
    while len(data) < n:
        c = s.recv(n - len(data))
        if not c:
            raise SystemExit("rcon: connection closed")
        data += c
    return struct.unpack("<ii", data[:8]), data[8:-2].decode(errors="replace")

s = socket.create_connection((os.environ["RCON_HOST"], int(os.environ.get("RCON_PORT", "25575"))), timeout=60)
s.sendall(pkt(1, 3, os.environ["RCON_PASSWORD"]))
(rid, _), _ = read(s)
if rid == -1:
    raise SystemExit("rcon: authentication failed")
for n, cmd in enumerate(sys.argv[1:], start=2):
    s.sendall(pkt(n, 2, cmd))
    _, out = read(s)
    print(f"rcon> {cmd}: {out.strip()}")
PY
}

cleanup() {
  local rc=$?
  if [[ "${RCON_QUIESCED}" == "true" ]]; then
    # Never leave the server with autosave off, even when the backup failed.
    rcon "save-on" || echo "WARNING: save-on failed; run it manually via rcon" >&2
  fi
  rm -rf "${WORK_DIR}"
  exit "${rc}"
}
trap cleanup EXIT

# Consistent copy of one SQLite database: snapshot_db <src> <dest>.
# - rollback-journal DBs: `.backup` straight from the (read-only) source, which
#   takes SQLite's own shared lock.
# - WAL DBs: the -shm index is an mmap'd file that is not coherent across NFS
#   clients and cannot be created on a read-only mount, so copy db + -wal to
#   scratch space and let SQLite replay the WAL there. A checkpoint racing the
#   copy would tear it, so retry until the main file did not change meanwhile.
snapshot_db() {
  local src="$1" dest="$2" journal attempt before after scratch
  mkdir -p "$(dirname "${dest}")"
  journal="$(dd if="${src}" bs=1 skip=18 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
  if [[ "${journal}" != "2" ]]; then
    sqlite3 -readonly "${src}" ".backup '${dest}'"
  else
    scratch="$(mktemp -d "${WORK_DIR}/wal.XXXXXX")"
    for attempt in 1 2 3 4 5; do
      before="$(stat -c '%s %y' "${src}")"
      cp "${src}" "${scratch}/db"
      if [[ -f "${src}-wal" ]]; then cp "${src}-wal" "${scratch}/db-wal"; else rm -f "${scratch}/db-wal"; fi
      after="$(stat -c '%s %y' "${src}")"
      [[ "${before}" == "${after}" ]] && break
      echo "WARNING: ${src} changed during copy (attempt ${attempt}); retrying" >&2
      before=""
      sleep 3
    done
    if [[ -z "${before}" || "${before}" != "${after}" ]]; then
      echo "ERROR: could not take a stable copy of ${src}" >&2
      return 1
    fi
    sqlite3 "${scratch}/db" ".backup '${dest}'"
    rm -rf "${scratch}"
  fi
  local result
  result="$(sqlite3 -readonly "${dest}" "PRAGMA integrity_check;")"
  if [[ "${result}" != "ok" ]]; then
    echo "ERROR: integrity_check failed for ${src}: ${result}" >&2
    return 1
  fi
  echo "OK: ${src} -> consistent copy ($(stat -c %s "${dest}") bytes), integrity_check ok"
}

UTC_TS="$(date -u +%Y%m%dT%H%M%SZ)"

case "${MODE}" in
  sqlite)
    : "${SQLITE_FILE:?SQLITE_FILE required for MODE=sqlite}"
    SRC="${DATA_DIR}/${SQLITE_FILE}"
    if [[ ! -s "${SRC}" ]]; then
      echo "ERROR: source database missing or empty: ${SRC}" >&2
      exit 1
    fi
    snapshot_db "${SRC}" "${WORK_DIR}/snapshot.sqlite3"
    ARTIFACT="${WORK_DIR}/artifact.sqlite3.gz"
    gzip -c "${WORK_DIR}/snapshot.sqlite3" > "${ARTIFACT}"
    EXT="sqlite3.gz"
    ;;
  tar)
    [[ -d "${DATA_DIR}" ]] || { echo "ERROR: ${DATA_DIR} is not a directory" >&2; exit 1; }
    cd "${DATA_DIR}"
    prune=()
    add_prune() {
      if ((${#prune[@]})); then prune+=(-o); fi
      prune+=("$@")
    }
    while IFS= read -r p; do
      [[ -n "${p}" ]] && add_prune -path "./${p#./}"
    done <<<"${TAR_EXCLUDE_ROOT:-}"
    while IFS= read -r p; do
      [[ -n "${p}" ]] && add_prune -path "*/${p}"
    done <<<"${TAR_EXCLUDE_ANY:-}"
    if ((${#prune[@]})); then
      prune=(\( "${prune[@]}" \) -prune -o)
    fi

    # NUL-separated file lists: everything that is not a directory/socket, plus
    # empty directories, minus excluded paths and (when auto-snapshotting) SQLite files.
    : >"${WORK_DIR}/data.list"
    : >"${WORK_DIR}/sqlite.list"
    find . "${prune[@]}" -type f -print0 >"${WORK_DIR}/all-files.list"
    while IFS= read -r -d '' f; do
      if [[ "${TAR_SQLITE_AUTO:-}" == "true" ]]; then
        case "${f}" in
          *.db | *.sqlite | *.sqlite3)
            if [[ "$(head -c 15 "${f}" 2>/dev/null)" == "SQLite format 3" ]]; then
              printf '%s\0' "${f}" >>"${WORK_DIR}/sqlite.list"
              continue
            fi
            ;;
          *.db-wal | *.db-shm | *.db-journal | *.sqlite-wal | *.sqlite-shm | *.sqlite3-wal | *.sqlite3-shm | *.sqlite3-journal)
            continue
            ;;
        esac
      fi
      printf '%s\0' "${f}" >>"${WORK_DIR}/data.list"
    done <"${WORK_DIR}/all-files.list"
    find . "${prune[@]}" \( -type l -o \( -type d -empty \) \) -print0 >>"${WORK_DIR}/data.list"

    while IFS= read -r -d '' f; do
      snapshot_db "${f}" "${STAGE}/${f#./}"
    done <"${WORK_DIR}/sqlite.list"
    (cd "${STAGE}" && find . -type f -print0) >"${WORK_DIR}/stage.list"

    if [[ -n "${RCON_HOST:-}" ]]; then
      : "${RCON_PASSWORD:?RCON_PASSWORD required with RCON_HOST}"
      export RCON_HOST RCON_PORT RCON_PASSWORD
      # Plain `save-all`: the `flush` argument does not exist on 1.7.10.
      rcon "save-off" "${RCON_SAVE_CMD:-save-all}"
      RCON_QUIESCED=true
    fi

    ARTIFACT="${WORK_DIR}/artifact.tar.gz"
    # tar exit 1 = "file changed as we read it" (warning); >=2 is fatal.
    set +e
    tar -czf "${ARTIFACT}" --null \
      -C "${DATA_DIR}" -T "${WORK_DIR}/data.list" \
      -C "${STAGE}" -T "${WORK_DIR}/stage.list"
    tar_rc=$?
    set -e
    if ((tar_rc > 1)); then
      echo "ERROR: tar failed with exit ${tar_rc}" >&2
      exit 1
    fi
    if [[ "${RCON_QUIESCED}" == "true" ]]; then
      rcon "save-on"
      RCON_QUIESCED=false
    fi
    gzip -t "${ARTIFACT}"
    EXT="tar.gz"
    ;;
  *)
    echo "ERROR: unknown MODE=${MODE}" >&2
    exit 1
    ;;
esac

if [[ ! -s "${ARTIFACT}" ]]; then
  echo "ERROR: backup artifact is empty" >&2
  exit 1
fi

OBJECT_KEY="${NAMESPACE}/${APP}/${UTC_TS}.${EXT}"
S3_URI="s3://${BUCKET}/${OBJECT_KEY}"
LOCAL_SIZE="$(stat -c %s "${ARTIFACT}")"

aws s3 cp --only-show-errors "${ARTIFACT}" "${S3_URI}"

# Verify the object exists with the size we sent.
REMOTE_SIZE="$(aws s3api head-object --bucket "${BUCKET}" --key "${OBJECT_KEY}" --query ContentLength --output text)"
if [[ "${REMOTE_SIZE}" != "${LOCAL_SIZE}" ]]; then
  echo "ERROR: head-object size ${REMOTE_SIZE} != local ${LOCAL_SIZE} for ${S3_URI}" >&2
  exit 1
fi

echo "Uploaded ${S3_URI} (${LOCAL_SIZE} bytes)"
