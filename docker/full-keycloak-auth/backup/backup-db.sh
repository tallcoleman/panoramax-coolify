#!/bin/sh
set -eu
OUT=/backups/pg
rm -rf "$OUT"; mkdir -p "$OUT"

export PGPASSWORD="${PG_PASSWORD}"
H=db; U=gvs

# 1) Global objects: roles incl. passwords (gvs is the cluster superuser here)
pg_dumpall -h "$H" -U "$U" --globals-only > "$OUT/globals.sql"

# 2) Every real database in the cluster — captures geovisio AND keycloak if co-located.
#    Custom format (-Fc) = compressed and restorable selectively with pg_restore.
DBS=$(psql -h "$H" -U "$U" -d postgres -Atqc \
  "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres';")
for db in $DBS; do
  pg_dump -h "$H" -U "$U" -Fc "$db" > "$OUT/${db}.dump"
done

# 3) Ship encrypted to the backup S3, then apply retention.
restic backup --host panoramax --tag db "$OUT"
restic forget --host panoramax --tag db \
  --keep-daily "${RESTIC_KEEP_DAILY:-7}" \
  --keep-weekly "${RESTIC_KEEP_WEEKLY:-5}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY:-12}" \
  --prune

# 4) Success marker for the container healthcheck (§7.3) — only reached if
#    everything above exited zero, thanks to `set -eu`.
touch /backups/.ok-db
