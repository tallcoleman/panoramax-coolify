#!/bin/sh
# Delete orphaned HD originals from the PRODUCTION permanent bucket — files that
# have no matching row in the `pictures` table (e.g. left behind by an interrupted
# or failed delete). Reconciles production against the database so `rclone sync`
# (see backup-images.sh) then mirrors the cleanup into the backup on its next run.
#
# Scope: the permanent bucket only (FS_PERMANENT_URL) — the only bucket that is
# backed up. Derivates/tmp are regenerable and left untouched.
#
# Usage:
#   prune-orphan-images.sh            # dry run: list orphans, delete nothing
#   prune-orphan-images.sh --delete   # actually delete the orphaned files
#   prune-orphan-images.sh --delete --force   # skip the >50%-orphaned safety abort
set -eu

DELETE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=1 ;;
    --force)  FORCE=1 ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

# --- Parse production creds/bucket out of FS_PERMANENT_URL (same block as backup-images.sh) ---
# Format: s3://ACCESS_KEY:SECRET_KEY@bucket/prefix?endpoint_url=<url-encoded>&region=<region>
rest=${FS_PERMANENT_URL#s3://}
creds=${rest%%@*}
after_at=${rest#*@}
SRC_ACCESS_KEY=${creds%%:*}
secret_enc=${creds#*:}
SRC_SECRET_KEY=$(printf '%b' "$(echo "$secret_enc" | sed 's/%/\\x/g')")
SRC_BUCKET_PATH=${after_at%%\?*}
query=${after_at#*\?}
endpoint_enc=$(echo "$query" | sed -n 's/.*endpoint_url=\([^&]*\).*/\1/p')
SRC_ENDPOINT=$(printf '%b' "$(echo "$endpoint_enc" | sed 's/%/\\x/g')")
SRC_REGION=$(echo "$query" | sed -n 's/.*region=\([^&]*\).*/\1/p')

# endpoint/region are single-quoted: they may contain ':' (e.g. "https://host")
# which would otherwise be misread as the connection-string/path separator.
SRC=":s3,provider=Other,access_key_id=${SRC_ACCESS_KEY},secret_access_key=${SRC_SECRET_KEY},endpoint='${SRC_ENDPOINT}',region='${SRC_REGION}':${SRC_BUCKET_PATH}"

EXPECTED=$(mktemp)
ACTUAL=$(mktemp)
ORPHANS=$(mktemp)
trap 'rm -f "$EXPECTED" "$ACTUAL" "$ORPHANS"' EXIT

# 1) Expected key for every picture, derived exactly like Panoramax's getHDPicturePath:
#    /{id[0:2]}/{id[2:4]}/{id[4:6]}/{id[6:8]}/{id[9:]}.jpg  (UUID text, dashes kept;
#    the index-8 dash is dropped). SQL substr() is 1-indexed, so Python [9:] -> substr(,10).
export PGPASSWORD="${PG_PASSWORD}"
psql -h db -U gvs -d geovisio -Atc \
  "SELECT substr(id::text,1,2)||'/'||substr(id::text,3,2)||'/'||substr(id::text,5,2)||'/'||substr(id::text,7,2)||'/'||substr(id::text,10)||'.jpg' FROM pictures;" \
  | sort > "$EXPECTED"
exp_n=$(wc -l < "$EXPECTED")

# Safety: never treat an empty or failed DB read as "everything is an orphan".
if [ "$exp_n" -eq 0 ]; then
  echo "Refusing to run: the pictures table returned 0 rows (empty DB or failed query)." >&2
  exit 1
fi

# 2) Actual HD files in the production permanent bucket (restricted to .jpg so a stray
#    non-picture object is never considered for deletion).
rclone lsf --files-only -R "$SRC" | grep -E '\.jpg$' | sort > "$ACTUAL"
act_n=$(wc -l < "$ACTUAL")

# 3) Orphans = actual - expected.
comm -23 "$ACTUAL" "$EXPECTED" > "$ORPHANS"
orph_n=$(wc -l < "$ORPHANS")

echo "DB pictures: $exp_n   bucket HD files: $act_n   orphans: $orph_n"

if [ "$orph_n" -eq 0 ]; then
  echo "Nothing to prune."
  exit 0
fi

# Safety: bail if orphans are an implausibly large share of the bucket (wrong bucket /
# wrong DB / schema surprise) unless the operator explicitly overrides with --force.
if [ "$FORCE" -ne 1 ] && [ $(( orph_n * 2 )) -gt "$act_n" ]; then
  echo "Refusing: >50% of bucket files look orphaned. Re-run with --force if this is expected." >&2
  exit 1
fi

if [ "$DELETE" -ne 1 ]; then
  echo "Dry run — the following would be deleted (pass --delete to remove them):"
  cat "$ORPHANS"
  exit 0
fi

echo "Deleting $orph_n orphaned file(s) from the production permanent bucket..."
rclone delete --files-from-raw "$ORPHANS" "$SRC" -v
echo "Done. The next backup-images.sh (sync) run will mirror these deletions to the backup."
