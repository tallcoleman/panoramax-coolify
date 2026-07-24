#!/bin/sh
# Periodically runs `kc.sh export` so a portable realm+users snapshot lands on
# the kc_export volume for the backup service to restic (see backup/backup_architecture.md,
# "The keycloak-export sidecar").
# kc.sh export reads directly from Postgres, not the live HTTP server, so this
# runs as its own sleep-loop entrypoint rather than inside the running `auth` process.
set -u
INTERVAL="${KC_EXPORT_INTERVAL_SECONDS:-86400}"

# Exit immediately on shutdown. As PID 1 a shell blocked in a foreground `sleep`
# ignores SIGTERM until SIGKILL, making the container sit out its whole grace
# period on every stop/redeploy. Trap the signal and background the sleep with
# `wait` so the signal interrupts it and the container exits right away.
trap 'exit 0' TERM INT

while true; do
  # This container has no ordering dependency on auth (see docker-compose.yml),
  # so on a fresh deploy the geovisio realm may not exist yet when this runs.
  # Retry with a backoff instead of exiting: exiting would restart the whole
  # container into another full JVM boot at full loop speed, which previously
  # produced a tight crash loop that starved auth of CPU during its own startup.
  if /opt/keycloak/bin/kc.sh export --optimized --dir /export --users realm_file --realm geovisio; then
    sleep "$INTERVAL" & wait $!
  else
    echo "kc.sh export failed (realm may not be imported yet) - retrying in 30s" >&2
    sleep 30 & wait $!
  fi
done
