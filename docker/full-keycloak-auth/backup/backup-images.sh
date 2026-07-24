#!/bin/sh
set -eu

# --- Parse production creds/bucket out of FS_PERMANENT_URL (no separate vars needed) ---
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
DST=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint='${BACKUP_S3_ENDPOINT}',region='${BACKUP_S3_REGION}':${BACKUP_S3_BUCKET}/images/permanent"

# 'sync' (default) makes the backup an exact mirror of production's permanent
# bucket: a picture removed in production is removed from the backup on the next
# run. The backup bucket's object-versioning + 30-day lifecycle rule is the
# safety net for accidental deletions (see deployment_instructions.md §2.1).
# To keep deleted pictures in the backup indefinitely, change 'sync' to 'copy'
# below (additive: never deletes from the backup) — and/or lengthen the backup
# bucket's retention window.
# -v is required for rclone to print the final transfer stats at all — at the
# default NOTICE log level a clean run is otherwise completely silent.
rclone sync "$SRC" "$DST" \
  --transfers 16 --checkers 32 --fast-list --stats-one-line -v

# Success marker for the container healthcheck (§7.3).
touch /backups/.ok-images
