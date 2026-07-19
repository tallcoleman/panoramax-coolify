#!/bin/sh
set -eu
OUT=/backups/config
rm -rf "$OUT"; mkdir -p "$OUT"

# Secrets live only as env vars injected by Coolify — there's no .env file on
# disk to copy. Serialize the ones the backup service has been given (see the
# `backup` service's environment: block in §7.3).
cat > "$OUT/secrets.env" <<EOF
OAUTH_CLIENT_SECRET=${OAUTH_CLIENT_SECRET}
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
PG_PASSWORD=${PG_PASSWORD}
KC_DB_PASSWORD=${KC_DB_PASSWORD}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
EOF

restic backup --host panoramax --tag config "$OUT"
restic forget --host panoramax --tag config \
  --keep-daily "${RESTIC_KEEP_DAILY:-7}" \
  --keep-weekly "${RESTIC_KEEP_WEEKLY:-5}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY:-12}" \
  --prune

# Success marker for the container healthcheck (§7.3).
touch /backups/.ok-config
