#!/bin/sh
# Periodically runs `kc.sh export` so a portable realm+users snapshot lands on
# the kc_export volume for the backup service to restic (BACKUP.md §5.4).
# kc.sh export reads directly from Postgres, not the live HTTP server, so this
# runs as its own sleep-loop entrypoint rather than inside the running `auth` process.
set -eu
INTERVAL="${KC_EXPORT_INTERVAL_SECONDS:-86400}"
while true; do
  /opt/keycloak/bin/kc.sh export --optimized --dir /export --users realm_file --realm geovisio
  sleep "$INTERVAL"
done
