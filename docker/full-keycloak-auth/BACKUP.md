# Panoramax — Backup & Recovery Strategy

Backup and Recovery instructions for a `full-keycloak-auth` Panoramax deployment on **Coolify**, backing up to S3-compatible backup storage, with production images living in S3-compatible production storage, and a weekly copy to an external hard drive.

With the exception of the external hard drive backup, the backups are designed to run automatically with no manual steps and all the key configuration contained within the environment variables managed by Coolify.

If you also do the external hard drive backup on a regular schedule, this should allow you to fully implement the [3-2-1 strategy](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/).

---

## 1. What needs backing up

Here is the data used and needed for a functioning application:

| Data                                                                                                                                                                                                       | Where it lives                                         | Replaceable?                    | Back up?            |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------- | ------------------- |
| **Postgres `geovisio` DB** (PostGIS) — all metadata: accounts, collections, sequences, picture records + their file paths, semantics, `configurations` (live settings), TOS pages, excluded areas, reports | `db` service                                           | ❌ No                            | ✅ **Yes**           |
| **Keycloak data** — realm config, clients, **users + password hashes**                                                                                                                                     | Postgres `keycloak` DB *or* a Keycloak volume (see §3) | ❌ No                            | ✅ **Yes**           |
| **Permanent (HD) pictures** — the original, already-blurred, high-definition files                                                                                                                         | S3 (`FS_PERMANENT_URL`)                                | ❌ No                            | ✅ **Yes**           |
| **Derivates** — SD, thumbnail, and 360° tiles                                                                                                                                                              | S3 (`FS_DERIVATES_URL`)                                | ✅ **Yes — regenerated from HD** | 🚫 **Skip** (see §6) |
| **`tmp/`** — pictures mid-blur                                                                                                                                                                             | S3 (`FS_TMP_URL`) or disk                              | ✅ Transient                     | 🚫 Skip              |
| **Secrets & config** — Coolify env vars (secrets), `docker-compose.yml`, `keycloak-realm.json`, custom themes                                                                                              | Coolify UI + your repo                                 | ❌ No (secrets)                  | ✅ **Yes**           |

Panoramax splits picture storage into `permanent` (irreplaceable originals) and `derivates` (a disposable cache). The CLI even has `panoramax_backend cleanup --cache` whose only job is to delete derivates — they are explicitly throwaway. Regeneration is covered in §6.

---

## 2. Tools used

Two tools:

- **`restic`** → Postgres dumps, Keycloak export, and secrets/config. Encrypted (since some of the data contains credentials), deduplicated, snapshotted, with trivial retention (`forget`/`prune`). Supports a wide variety of storage types.
- **`rclone`** → the images (production S3 → backup S3). Purpose-built for S3-to-S3, transfers only new/changed objects, and (with `copy`) never deletes from the backup. Panoramax picture files are **immutable** once written, so after the first big sync each run only ships newly-uploaded pictures.

Both run inside one small **`backup` sidecar** container defined in your compose file, driven by [`supercronic`](https://github.com/aptible/supercronic) (a container-friendly cron). Credentials are declared in code; schedule and retention are also declared in code but overridable via environment variables with sensible defaults (see §7.2 and §7.3).

### Running Commands in Docker

Several of these steps require running commands in one of the docker containers being run by the service. Coolify appends unique IDs to the container names on each deployment, so you will need to find the container name or ID before you can run a command. The beginning of the container name will be the same as the service name in the docker compose file; you can also double check you have the right container by looking at the "logs" menu in Coolify.

If you want to modify the information shown by this command, see the [docker ps documentation](https://docs.docker.com/reference/cli/docker/container/ls/):

```bash
# list running containers
docker ps --format "table {{.ID}}\t{{.CreatedAt}}\t{{.Names}}"
```

Alternatively, you can connect to a shell inside any running container by using the "terminal" menu in the Coolify UI. In this case, just run the portion of the command that comes after `... exec <container_name>`.

---

## 3. Confirm how Keycloak stores its data (one command)

In this compose, Keycloak shares the **`geovisio` database** with the API but stores its tables in a dedicated **`keycloak` schema** (`KC_DB_SCHEMA: keycloak`, `KC_DB_URL: jdbc:postgresql://db/geovisio`). Because `pg_dump geovisio` captures all schemas by default, the database backup in §5 already covers Keycloak completely — there is only one database to back up. 

You can confirm this with:

```bash
docker exec <db_container_name> \
  psql -U gvs -d geovisio -Atc "SELECT schema_name FROM information_schema.schemata;"
```

- If the list includes **`keycloak`** → ✅ Keycloak is in the `geovisio` DB. Covered automatically by §5's `pg_dump geovisio`.
- If it does **not** → Keycloak may be using its own database or a file store. Check `KC_DB*` env vars in the `auth` service, and either add that database to the dump loop in §5.2 or rely on the realm export in §5.4 as the primary Keycloak backup.

Either way, §5.4's `kc.sh export` gives you a **portable** realm+users snapshot as a safety net.

---

## 4. Backup S3 setup (one-time)

1. Create one bucket on your backup S3 provider, e.g. `panoramax-backup`. Two prefixes inside it are used: `restic/` (Postgres dumps, Keycloak export, secrets — via restic) and `images/` (picture files — via rclone).
2. Create an access key scoped to that bucket. Note the access key ID, secret key, endpoint URL, and region (if applicable).
3. Turn on **Object Versioning** on the bucket and add a **Lifecycle rule** such as *"keep prior/hidden versions for 30 days"*. Because we use `rclone copy` (additive), a picture deleted in production stays in the backup; versioning is a second safety net if you later switch to `sync`.
4. **Record the restic password and backup S3 keys somewhere independent of the server** (password manager, and on the external drive's notes). You cannot restore an encrypted restic repo without them — see §8.

> **Alternative backends.** The scripts below use the generic S3 API on both ends, but rclone also has native remote types for other object stores — e.g. `b2:` for Backblaze B2 (its native API, rather than B2's S3-compatible endpoint) or a `[swift]` remote for OpenStack Swift. The script structure stays the same; just swap the `:s3,...:` connection string in §5.3 for `:b2,account=...,key=...:` or a configured `swift:` remote. Not covered in detail here.

---

## 5. The backup scripts

The relevant files are in the `backup/` folder in this repo. Working files are written under `/backups` inside the container (a scratch volume), then saved externally.

### 5.1 Environment variables

In this deployment, every environment variable is configured directly in the **Coolify UI** for each service — there is no `.env` file on disk (`env.example` in the repo is documentation only). The block below shows the variable names to add for the `backup` service in Coolify; it is a reference, not a file to create.

`RESTIC_PASSWORD`, `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY`, `BACKUP_S3_ENDPOINT`, `BACKUP_S3_BUCKET`, `FS_PERMANENT_URL`, `PG_PASSWORD`, `OAUTH_CLIENT_SECRET`, `FLASK_SECRET_KEY`, `KC_DB_PASSWORD`, and `KEYCLOAK_ADMIN_PASSWORD` are **required** — the compose snippet in §7.3 marks them with the `${VAR:?}` syntax (matching the rest of `docker-compose.yml`) so Coolify highlights them in red and the stack refuses to start with a clear error if any is left unset to prevent a silent backup failure.

`BACKUP_S3_REGION` and the schedule/retention variables are optional; not all S3 providers need the region to be specified and the schedule/retention variables all have sensible defaults. 

`PGHOST`/`PGUSER` are not Coolify-settable at all — they're hardcoded to `db`/`gvs` directly in `docker-compose.yml` and `backup-db.sh`, since Coolify's Docker Compose buildpack injects every app-level env var into all services (not just ones referencing it), and a `PGHOST` meant only for `backup` interferes with the `db` service's own local init script.

```dotenv
# ---------- Backup destination (S3-compatible) ----------
BACKUP_S3_ACCESS_KEY=xxxx
BACKUP_S3_SECRET_KEY=xxxx
BACKUP_S3_ENDPOINT=https://s3.<region>.<provider>.example.com
BACKUP_S3_REGION=xxxx
BACKUP_S3_BUCKET=panoramax-backup

RESTIC_PASSWORD=<LONG-RANDOM-PASSPHRASE-STORED-OFFSITE>

# ---------- Production S3 — reused, not re-entered ----------
# FS_PERMANENT_URL is already set on the api/background-worker services; the
# backup service is simply given the same value (see §7.3) and parses it at
# runtime, so production credentials are only ever entered once.

# ---------- Schedule (optional — cron syntax, defaults shown) ----------
BACKUP_CRON_IMAGES=0 2 * * *
BACKUP_CRON_DB=30 2 * * *
BACKUP_CRON_CONFIG=45 2 * * *
BACKUP_CRON_CHECK=0 4 * * 0

# ---------- Retention (optional — restic snapshot counts, defaults shown) ----------
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=5
RESTIC_KEEP_MONTHLY=12

# ---------- Keycloak realm export cadence (optional, seconds, default shown) ----------
# Set on the `keycloak-export` service (§5.4), not `backup` — listed here for completeness.
KC_EXPORT_INTERVAL_SECONDS=86400
```

### 5.2 `backup/backup-db.sh` — Postgres (geovisio + keycloak + roles)

```sh
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
```

### 5.3 `backup/backup-images.sh` — production S3 → backup S3 (permanent only)

Uses rclone "connection strings" so **no config file** is needed — everything comes from env. The source side is **parsed out of `FS_PERMANENT_URL`** (already configured for the api/background-worker services) rather than re-entered, so production credentials live in exactly one place.

```sh
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

# 'copy' is additive: it never deletes from the backup, so originals removed in
# production are retained. Swap to 'sync' only if you want an exact mirror.
rclone copy "$SRC" "$DST" \
  --transfers 16 --checkers 32 --fast-list --stats-one-line

# Success marker for the container healthcheck (§7.3).
touch /backups/.ok-images
```

Note we deliberately reference only the **permanent** prefix — `derivates/` and `tmp/` are never touched. That is the space saving. This parsing assumes `FS_PERMANENT_URL` uses the `s3://` scheme shown above; if your production storage uses a different PyFilesystem backend, build `SRC` manually instead.

### 5.4 `keycloak-export` service — portable realm export (optional but recommended)

If Keycloak is co-located in the shared Postgres (§3), the DB dump already backs it up fully and this is a **bonus** portable/human-readable snapshot. `kc.sh export` includes users **and** password hashes, so it can fully rebuild the realm on a clean Keycloak.

`kc.sh export` reads directly from Postgres — it doesn't need the live HTTP server — so rather than a manual Coolify Scheduled Task, it runs as its own lightweight sidecar service (`keycloak-export`), reusing the same `Dockerfile.keycloak` build as `auth` but overriding the entrypoint with a sleep-loop (`keycloak-export-loop.sh`) instead of starting the server. This keeps the export fully in code, with nothing to configure outside the repo:

```yaml
  auth:
    <<: *keycloak-build
    command: start --optimized --import-realm
    # ...

  keycloak-export:
    <<: *keycloak-build
    entrypoint: ["/usr/local/bin/keycloak-export-loop.sh"]
    environment:
      KC_DB_USERNAME: keycloak_user
      KC_DB_PASSWORD: ${KC_DB_PASSWORD:?}
      KC_DB_SCHEMA: keycloak
      KC_DB_URL: jdbc:postgresql://db/geovisio
      KC_EXPORT_INTERVAL_SECONDS: ${KC_EXPORT_INTERVAL_SECONDS:-86400}
    user: "0:0"   # named volumes are root-owned; Keycloak's default uid 1000 can't write to /export otherwise
    volumes:
      - kc_export:/export

  backup:
    volumes:
      - kc_export:/backups/keycloak:ro
volumes:
  kc_export:
```

`keycloak-export-loop.sh` runs the export once at container start and then every `KC_EXPORT_INTERVAL_SECONDS` (default 86400 = daily):

```sh
/opt/keycloak/bin/kc.sh export --dir /export --users realm_file --realm geovisio
```

`backup-config.sh` (§5.5) picks up `/backups/keycloak` alongside the secrets it already ships, so both land in the same nightly restic run.

### 5.5 `backup/backup-config.sh` — secrets

```sh
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

# /backups/keycloak is the kc_export volume, populated by the keycloak-export
# service (§5.4) — bundled here so both land in the same nightly restic run.
restic backup --host panoramax --tag config "$OUT" /backups/keycloak
restic forget --host panoramax --tag config \
  --keep-daily "${RESTIC_KEEP_DAILY:-7}" \
  --keep-weekly "${RESTIC_KEEP_WEEKLY:-5}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY:-12}" \
  --prune

# Success marker for the container healthcheck (§7.3).
touch /backups/.ok-config
```

> `docker-compose.yml`, `keycloak-realm.json`, and themes are already in git and don't need backing up here — a rebuild just re-deploys the repo in Coolify. The irreplaceable pieces are the secret values above (`FLASK_SECRET_KEY`, `OAUTH_CLIENT_SECRET`, `PG_PASSWORD`, `KC_DB_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`), which live solely in Coolify's env var store. Keeping an encrypted copy in restic means a full rebuild needs nothing that isn't backed up.

---

## 6. Derivates: skipping them, and regenerating on restore

Derivates (SD, thumbnail, tiles) are a cache derived from the permanent HD file. The permanent file is stored already blurred, so any regenerated derivate inherits the blur, and skipping them creates no privacy regression.

How derivates are restored depends on `PICTURE_PROCESS_DERIVATES_STRATEGY`:

- **`PREPROCESS`:** All derivates are generated up front during processing.
  - If derivates are still served through the API, the on-demand path remains as a fallback, so a missing file self-heals on request anyway.
  - If you serve derivates directly from S3 via `API_DERIVATES_PICTURES_PUBLIC_URL` (which *requires* `PREPROCESS`), the API is not in the request path, so missing files won't self-heal — you must requeue every picture for `prepare` after restore (§9, step 6), or temporarily serve derivates through the API while the cache refills.

- **`ON_DEMAND`:** A missing derivate is generated from the HD original the first time it's requested, then cached.

---

## 7. Wiring it into the stack (code-first)

### 7.1 `backup/Dockerfile`

The schedule is a template rendered at container start (not baked into the image), so it can be overridden per-deployment via env vars without a rebuild:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache postgresql16-client rclone restic ca-certificates tzdata curl gettext \
 && curl -fsSL -o /usr/local/bin/supercronic \
      https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
 && chmod +x /usr/local/bin/supercronic
COPY *.sh /usr/local/bin/
COPY crontab.template /etc/crontab.template
RUN chmod +x /usr/local/bin/*.sh
CMD ["entrypoint.sh"]
```

(`gettext` provides `envsubst`, used below to render the schedule from env vars.)

### 7.2 `backup/crontab.template` and `backup/entrypoint.sh`

```cron
# min hour dom mon dow  command
${BACKUP_CRON_IMAGES}   backup-images.sh     # new HD pictures, production S3 -> backup S3
${BACKUP_CRON_DB}       backup-db.sh         # geovisio + keycloak + roles -> backup S3 (encrypted)
${BACKUP_CRON_CONFIG}   backup-config.sh     # secrets -> backup S3 (encrypted)
${BACKUP_CRON_CHECK}    restic-check.sh      # integrity check (optional)
```

```sh
#!/bin/sh
set -eu
export BACKUP_CRON_IMAGES="${BACKUP_CRON_IMAGES:-0 2 * * *}"
export BACKUP_CRON_DB="${BACKUP_CRON_DB:-30 2 * * *}"
export BACKUP_CRON_CONFIG="${BACKUP_CRON_CONFIG:-45 2 * * *}"
export BACKUP_CRON_CHECK="${BACKUP_CRON_CHECK:-0 4 * * 0}"
envsubst < /etc/crontab.template > /etc/crontab
exec supercronic /etc/crontab
```

`envsubst` fails closed: if a schedule expression is malformed, supercronic errors parsing `/etc/crontab` at startup and the container crash-loops under `restart: unless-stopped` — loud and visible in Coolify's logs, rather than a schedule silently not running. `restic-check.sh` can be a one-liner: `restic check --read-data-subset=5%`.

### 7.3 compose service (add to `docker-compose.yml`)

**`backup/backup-healthcheck.sh`** — the container's health status shouldn't just mean "the cron daemon is alive": supercronic will happily keep running for weeks while `restic backup` fails every night on a bad credential. Instead, each script from §5 touches a marker file on success (last line of `backup-images.sh`/`backup-db.sh`/`backup-config.sh`), and the healthcheck asserts each marker exists and isn't stale:

```sh
#!/bin/sh
set -eu
MAX_AGE_MIN=1560   # 26h — a bit past the daily cadence, so the 2am run isn't flagged as stale
for marker in /backups/.ok-images /backups/.ok-db /backups/.ok-config; do
  [ -f "$marker" ] || exit 1
  find "$marker" -mmin +"$MAX_AGE_MIN" -print -quit | grep -q . && exit 1
done
exit 0
```

This uses `find -mmin` (not `stat`) so it works unmodified against BusyBox's `find` in the Alpine base image. A missing marker (nothing has ever succeeded) or a stale one (something's been failing) both report unhealthy; the compose `healthcheck:` block's `start_period` below absorbs the first day before any backup has had a chance to run.

```yaml
  backup:
    build: ./backup
    restart: unless-stopped
    depends_on: [db]
    environment:
      PG_PASSWORD: ${PG_PASSWORD:?}
      # Hardcoded, not Coolify-settable — see the comment in docker-compose.yml.
      PGHOST: db
      PGUSER: gvs
      OAUTH_CLIENT_SECRET: ${OAUTH_CLIENT_SECRET:?}
      FLASK_SECRET_KEY: ${FLASK_SECRET_KEY:?}
      KC_DB_PASSWORD: ${KC_DB_PASSWORD:?}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD:?}
      FS_PERMANENT_URL: ${FS_PERMANENT_URL:?}     # reused from the api/background-worker config
      RESTIC_PASSWORD: ${RESTIC_PASSWORD:?}
      RESTIC_REPOSITORY: s3:${BACKUP_S3_ENDPOINT:?}/${BACKUP_S3_BUCKET:?}/restic
      AWS_ACCESS_KEY_ID: ${BACKUP_S3_ACCESS_KEY:?}    # restic's S3 backend reads these names
      AWS_SECRET_ACCESS_KEY: ${BACKUP_S3_SECRET_KEY:?}
      AWS_DEFAULT_REGION: ${BACKUP_S3_REGION}
      BACKUP_S3_ACCESS_KEY: ${BACKUP_S3_ACCESS_KEY:?} # used directly by backup-images.sh (rclone)
      BACKUP_S3_SECRET_KEY: ${BACKUP_S3_SECRET_KEY:?}
      BACKUP_S3_ENDPOINT: ${BACKUP_S3_ENDPOINT:?}
      BACKUP_S3_REGION: ${BACKUP_S3_REGION}
      BACKUP_S3_BUCKET: ${BACKUP_S3_BUCKET:?}
      BACKUP_CRON_IMAGES: ${BACKUP_CRON_IMAGES:-0 2 * * *}
      BACKUP_CRON_DB: ${BACKUP_CRON_DB:-30 2 * * *}
      BACKUP_CRON_CONFIG: ${BACKUP_CRON_CONFIG:-45 2 * * *}
      BACKUP_CRON_CHECK: ${BACKUP_CRON_CHECK:-0 4 * * 0}
      RESTIC_KEEP_DAILY: ${RESTIC_KEEP_DAILY:-7}
      RESTIC_KEEP_WEEKLY: ${RESTIC_KEEP_WEEKLY:-5}
      RESTIC_KEEP_MONTHLY: ${RESTIC_KEEP_MONTHLY:-12}
    healthcheck:
      test: ["CMD", "backup-healthcheck.sh"]
      interval: 1h
      timeout: 10s
      retries: 1
      start_period: 26h
    volumes:
      - backup_scratch:/backups
      - kc_export:/backups/keycloak:ro          # populated by keycloak-export, see §5.4
volumes:
  backup_scratch:
  kc_export:
```

All of the `${...}` values above are Coolify UI environment variables for the `backup` service — set them there, not in a file. `RESTIC_REPOSITORY` and the `AWS_*` credentials are *derived* from `BACKUP_S3_*` rather than entered separately: restic's S3 backend reads the standard `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION` names for any S3-compatible endpoint, so the operator only enters the backup S3 credentials once.

The `:?` suffix marks a variable as required, matching the convention used elsewhere in `docker-compose.yml`: Coolify highlights an unset required variable in red, and `docker compose up` refuses to start with a clear "variable is not set" error instead of silently passing an empty string into the container. Without it, a missing `RESTIC_PASSWORD` or `BACKUP_S3_*` value wouldn't fail until the first cron run — and possibly not until someone notices backups are missing weeks later. `BACKUP_S3_REGION` is left optional since many S3-compatible providers ignore it. `PGHOST`/`PGUSER` are hardcoded (not env-driven) — see §5.1.

`BACKUP_CRON_*` and `RESTIC_KEEP_*` are all optional, defaulting to today's fixed schedule (02:00/02:30/02:45 nightly, weekly integrity check) and retention (7 daily / 5 weekly / 12 monthly). Changing a `RESTIC_KEEP_*` value takes effect on the next scheduled run with no rebuild — just edit the Coolify env var and restart the container. Changing a `BACKUP_CRON_*` value also just needs a restart, but since `entrypoint.sh` renders `/etc/crontab` at container startup, a malformed cron expression will crash-loop the container until fixed (see §7.2) — check the container logs after changing a schedule.

Nothing else `depends_on` the `backup` service, so the `healthcheck:` block above doesn't gate any other container's startup — it exists purely so Coolify's UI surfaces "backups have stopped succeeding" instead of showing a container that's merely running. `backup-healthcheck.sh` is picked up automatically by the Dockerfile's `COPY *.sh` (§7.1), no separate wiring needed.

**First run:** `entrypoint.sh` initialises the restic repo automatically on container startup if it isn't already (it runs `restic snapshots` to detect an existing repo, falling back to `restic init` if that fails) — no manual step needed. After first deploy, trigger a manual run to validate, e.g. `docker exec <backup_container_name> backup-db.sh`.

### 7.4 One-off backups

The nightly schedule (§7.2) doesn't need to be the only way a backup runs. `backup/backup-now.sh` runs all three jobs back-to-back, in the same order as the cron schedule (images, then db, then config — see §10 on why that order matters):

```bash
docker exec <backup_container_name> backup-now.sh
```

Like the individual scripts, it uses `set -eu` with no error suppression, so it stops at the first failing step rather than continuing on to the next. It doesn't touch `crontab.template` or the container's cron schedule — it's purely an extra, manually-invoked entrypoint alongside the automated one. Useful before/after a risky change, or to validate the backup pipeline without waiting for 2am.

---

## 8. Weekly copy to the external hard drive

Both prefixes copy down cleanly using the same rclone connection-string style as §5.3 (substitute your `BACKUP_S3_*` values):

```bash
BACKUP=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint='${BACKUP_S3_ENDPOINT}',region='${BACKUP_S3_REGION}':${BACKUP_S3_BUCKET}"

# Encrypted DB/secrets: copy the restic repo, or use restic's native repo-to-repo copy.
rclone sync "$BACKUP/restic" /mnt/hdd/panoramax/restic
# Images: plain, directly browsable.
rclone sync "$BACKUP/images" /mnt/hdd/panoramax/images
```

For the HDD, keep the images unencrypted (as above) so the drive is directly browsable, but the DB/secrets live in an encrypted restic repo. That means the HDD copy of the DB is useless without the `RESTIC_PASSWORD` and backup S3 keys. Store those credentials with the drive (offline) and in a password manager.

---

## 9. Restore / disaster-recovery runbook

Assumes a fresh Coolify project and empty S3.

### 0. Recover credentials.

From your password manager/HDD notes, get `RESTIC_PASSWORD` + `BACKUP_S3_ACCESS_KEY`/`BACKUP_S3_SECRET_KEY`. Everything else can be pulled from restic.

### 1. Restore config & secrets.

From any machine with [restic installed](https://restic.readthedocs.io/en/stable/020_installation.html) and network access to the S3 endpoint (e.g. your own computer), run the following to get the secrets that should be copied into the Coolify UI along with the other environment variables documented in `env.example`.

```bash
RESTIC_REPOSITORY="s3:<BACKUP_S3_ENDPOINT>/<BACKUP_S3_BUCKET>/restic" \
RESTIC_PASSWORD="<YOUR_RESTIC_PASSWORD>" \
AWS_ACCESS_KEY_ID="<BACKUP_S3_ACCESS_KEY>" \
AWS_SECRET_ACCESS_KEY="<BACKUP_S3_SECRET_KEY>" \
AWS_DEFAULT_REGION="<BACKUP_S3_REGION>" \ # optional, many S3-compatible providers ignore it
restic restore latest --tag config --target /tmp/restore

# review /tmp/restore/config/secrets.env
# can use any text editor of your choice or e.g. on mac
cat /private/tmp/restore/backups/config/secrets.env
```

Other Coolify configuration notes:

- Git source: https://github.com/tallcoleman/panoramax-coolify.git
- Base directory: /docker/full-keycloak-auth
- Docker compose location: /docker-compose.yml (slight change, default is .yaml)
- Fill out "domain for reverseproxy" (leave the others blank) and make sure to put the same domain (without the https:// prefix) in the DOMAIN environment variable as well

#### S3 Configuration

In some cases (e.g. for restore testing or if changing S3-compatible storage providers), you will also need to set up three new S3-compatible object storage buckets:
- Production Public (used for `FS_PERMANENT_URL`, `FS_DERIVATES_URL`, `S3_PERMANENT_PUBLIC_URL`, and `S3_DERIVATES_PUBLIC_URL`): encryption is good, but you don't need versioning or object lock set for this one. You will have to make it publicly accessible and set CORS headers (see notes below).
- Production Private (`FS_TMP_URL`): encryption is good, but you don't need versioning or object lock set for this one. This should not be public.
- Backup (for all the `BACKUP_S3_*` environment variables): for this one you should enable encryption, versioning, and a lifecycle rule that objects are retained for 30 days. This should not be public.

Terminology and set-up vary between providers (e.g. as of 2026-07 Backblaze automatically enables versioning), so make sure to check your provider-specific documentation as well.

Usually to manage access and CORS headers, you have to use the S3 api. The examples below assume you are using an auth profile; more [information on setting up authentication for the S3 API can be found in the official docs](https://docs.aws.amazon.com/cli/v1/userguide/cli-configure-files.html).

##### Step A — Add CORS rules to Production Public:

```bash
# Set CORS rules. This example allows any site, but you can be more specific if needed.
aws s3api put-bucket-cors \
--profile <PRODUCTION_AUTH_PROFILE_NAME> \
--bucket <PRODUCTION_PUBLIC_BUCKET_NAME> \
--endpoint-url <PRODUCTION_PUBLIC_BUCKET_ENDPOINT> \
--cors-configuration '{
  "CORSRules": [{
    "AllowedOrigins": ["*"],
         "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["*"],
         "MaxAgeSeconds": 3000
       }]
     }'

# Check updated CORS rules to confirm 
aws s3api get-bucket-cors \
--profile <PRODUCTION_AUTH_PROFILE_NAME>
--bucket <PRODUCTION_PUBLIC_BUCKET_NAME> \
--endpoint-url <PRODUCTION_PUBLIC_BUCKET_ENDPOINT> \

# Expected successful CORS rules should look like:
{
    "CORSRules": [
        {
            "AllowedHeaders": ["*"],
            "AllowedMethods": ["GET", "HEAD"],
            "AllowedOrigins": ["*"],
            "MaxAgeSeconds": 3000
        }
    ]
}
```

##### Step B — Make Production Public assets publicly readable:

If you use the website/API's direct-S3 links (`API_DERIVATES_PICTURES_PUBLIC_URL` etc.), then the `&acl=public-read` part of `FS_PERMANENT_URL`/`FS_DERIVATES_URL` should ensure that the images and derivates uploaded to S3-compatible storage are publicly viewable. This applies to new uploads as well as any generated (or re-generated) derivates.

Alternatively, if your S3-compatible storage provider supports it, you can set a policy on the bucket:

```bash
aws s3api put-bucket-policy \
  --profile <PRODUCTION_AUTH_PROFILE_NAME> \
  --bucket <PRODUCTION_PUBLIC_BUCKET_NAME> \
  --endpoint-url <PRODUCTION_PUBLIC_BUCKET_ENDPOINT> \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::<PRODUCTION_PUBLIC_BUCKET_NAME>/*"
    }]
  }'

# Check updated policy to confirm:
aws s3api get-bucket-policy \
  --profile <PRODUCTION_AUTH_PROFILE_NAME> \
  --bucket <PRODUCTION_PUBLIC_BUCKET_NAME> \
  --endpoint-url <PRODUCTION_PUBLIC_BUCKET_ENDPOINT>
```

If you run into an issue where some part of the service needs listing rights, you can allow that by setting an acl as well:

```bash
# Bucket ACL — still needed for anonymous listing behavior on some providers.
aws s3api put-bucket-acl \
  --profile <PRODUCTION_AUTH_PROFILE_NAME> \
  --bucket <PRODUCTION_PUBLIC_BUCKET_NAME> \
  --endpoint-url <PRODUCTION_PUBLIC_BUCKET_ENDPOINT> \
  --acl public-read

# Check updated access control list to confirm
aws s3api get-bucket-acl \
  --profile <PRODUCTION_AUTH_PROFILE_NAME> \
  --bucket <PRODUCTION_PUBLIC_BUCKET_NAME> \
  --endpoint-url <PRODUCTION_PUBLIC_BUCKET_ENDPOINT>

# Expected successful permissions list should include:
{
    "Grantee": {
        "Type": "Group",
        "URI": "http://acs.amazonaws.com/groups/global/AllUsers"
    },
    "Permission": "READ"
},
```

If you accidentally uploaded or copied over some images without setting them as public, you can fix their acls with `backup/fix-object-acls.sh`. This script parallelizes the `put-object-acl` calls (default 20 concurrent; override with `PARALLEL=n`), shows a live `n/total` progress count per prefix, and logs any failed keys so a retry only needs to touch those (the script is idempotent, so simply re-running it is also safe):

Run it from any machine with `aws` configured (the `backup` container doesn't have the AWS CLI installed, since it's not otherwise needed for the automated nightly jobs):

```bash
docker/full-keycloak-auth/backup/fix-object-acls.sh \
  <PRODUCTION_AUTH_PROFILE_NAME> <PRODUCTION_PUBLIC_BUCKET_NAME> <PRODUCTION_PUBLIC_BUCKET_ENDPOINT> permanent derivates
```
(needs only `bash`, `aws`, and `xargs`.)

This only fixes **existing** objects at the time you run it — it is not a substitute for correctly configuring `FS_PERMANENT_URL`/`FS_DERIVATES_URL` or setting a bucket policy.


### 2. Deploy the full stack, then restore the databases.

With everything configured, launch the fresh instance. This compose file has a `migrations` service (`db-upgrade`, `restart: "no"`) that `api` waits on via `condition: service_completed_successfully`, and `auth` runs `start --optimized --import-realm`. Both run automatically on a fresh deploy and create the `geovisio` and `keycloak` schemas — empty of rows, but not empty databases. This is expected: `api`/`background-worker`/website will come up successfully with no data, not crash-loop.

To restore, you will then overwrite the databases with the backup data. Run the restore itself inside the running **`backup`** container — it already bundles `restic`, `psql`, and `pg_restore` (§7.1) and sits on the same Docker network as `db`, so no extra tooling or file-copying between machines is needed:

```bash
docker exec -it <backup_container_name> sh
```

Inside that shell, run restic restore for the db and then load the restored data. At this point, there are two sets of restic credentials: one used to create the backup being loaded from the old instance, and one for the backup config on the new instance. The container will have the new config, so like before, you'll have to run restic with the env variables specified so it can pull the data from the old instance backup.

```bash
RESTIC_REPOSITORY="s3:<BACKUP_S3_ENDPOINT>/<BACKUP_S3_BUCKET>/restic" \
RESTIC_PASSWORD="<YOUR_RESTIC_PASSWORD>" \
AWS_ACCESS_KEY_ID="<BACKUP_S3_ACCESS_KEY>" \
AWS_SECRET_ACCESS_KEY="<BACKUP_S3_SECRET_KEY>" \
AWS_DEFAULT_REGION="<BACKUP_S3_REGION>" \ # optional, many S3-compatible providers ignore it
restic restore latest --tag db --target /tmp/restore   
# -> /tmp/restore/backups/pg/*.dump, globals.sql
```

For the `psql` and `pg_restore` command below, enter the value for the `PG_PASSWORD` secret if needed.

```bash
# roles (if the gvs role isn't already created by the image)
psql -h db -U gvs -d postgres -f /tmp/restore/backups/pg/globals.sql   
# ignore "already exists"
```

Restore the `geovisio` database, which includes the data for the api and for keycloak (each lives in a specific schema within the database).

```bash
# geovisio — schema already exists (created by the migrations service), so overwrite it
pg_restore -v -h db -U gvs -d geovisio --clean --if-exists /tmp/restore/backups/pg/geovisio.dump
```

If Keycloak ever uses its own database instead — see the fallback in §3 — restore it the same way: 

```bash
pg_restore -v -h db -U gvs -d keycloak --clean --if-exists /tmp/restore/backups/pg/keycloak.dump
```

Or take the portable route: skip the dump and start a clean Keycloak with `--import-realm` pointing at the exported `geovisio-realm.json` — that file comes from the `config` tag, not `db`; see step 1 above and §5.4.)

Once the dump is restored, redeploy the project so that `api`, `auth`, and `background-worker` pick up the restored data.

If the restore target's domain differs from the original (true for any test restore per §10's quarterly-drill recommendation, and for a real disaster recovery onto a new domain) — fix the Keycloak `geovisio` client's Root URL, or login will fail with `Invalid parameter: redirect_uri`. `docker-compose.yml` templates the client's `rootUrl` from `GEOVISIO_BASE_URL` (`https://${DOMAIN}`) at `--import-realm` time, but that only happens once, on the *original* instance — the resulting absolute URL is baked into the DB as literal text. The fresh `--import-realm` on this new deploy (§9 step 2) sets it correctly for the new domain, but the `pg_restore --clean --if-exists` you just ran overwrites the `keycloak` schema with the old backed-up realm data, reintroducing the original domain. `redirectUris` is stored as a relative path (`/api/auth/redirect`), so only `rootUrl` needs fixing:

Via Keycloak Admin Console (`<YOUR_INSTANCE_DOMAIN>/oauth`): Clients → `geovisio` → Root URL → set to `https://<new-domain>` → Save.) §9 step 7's login check won't work until this is fixed.

Alternatively, you can do it via command:

```bash
docker exec -it <auth_container_name> sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
  --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"
CID=$(/opt/keycloak/bin/kcadm.sh get clients -r geovisio -q clientId=geovisio --fields id --format csv --noquotes | tail -1)
/opt/keycloak/bin/kcadm.sh update clients/$CID -r geovisio -s "rootUrl=https://<new-domain>"
'
```

### 3. Restore images.

Repopulate production S3 from the backup S3 (or point the instance at the backup S3 temporarily), using the same connection-string style as §5.3/§8:

Like with before, remember that the BACKUP var should point to the backup files you are loading from the old instance, not the backup S3 for the new instance (if they are different).

If your provider does not need region specified (e.g. if region is in the endpoint URL), then remove `,region='<BACKUP_S3_REGION>'` and `,region='<NEW_PROD_REGION>'` from the two connection strings below.

The destination prefix must match `FS_PERMANENT_URL` exactly. `<NEW_PROD_BUCKET_PATH>` below is whatever bucket/prefix is actually set in `FS_PERMANENT_URL` on the `auth`/`api`/`background-worker` services (e.g. it may be `my-bucket/main-pictures`, not `my-bucket/permanent`). Check it first — `docker exec <api_container_name> printenv FS_PERMANENT_URL` — and copying to the wrong prefix will silently "succeed" (rclone reports files transferred) while the picture workers still can't find any of them, since they read the path back out of that same env var.

```bash
BACKUP=":s3,provider=Other,access_key_id=<BACKUP_S3_ACCESS_KEY>,secret_access_key=<BACKUP_S3_SECRET_KEY>,endpoint='<BACKUP_S3_ENDPOINT>',region='<BACKUP_S3_REGION>':<BACKUP_S3_BUCKET>/images/permanent"

PROD=":s3,provider=Other,access_key_id=<NEW_PROD_ACCESS_KEY>,secret_access_key=<NEW_PROD_SECRET_KEY>,endpoint='<NEW_PROD_ENDPOINT>',region='<NEW_PROD_REGION>':<NEW_PROD_BUCKET_PATH>"

rclone copy "$BACKUP" "$PROD" --transfers 16 --s3-acl public-read --fast-list --progress
```
Leave `derivates/` and `tmp/` empty.

If you accidentally restore to the wrong prefix, you can fix it with an in-place `rclone move`:

```bash
WRONG=":s3,provider=Other,access_key_id=<NEW_PROD_ACCESS_KEY>,secret_access_key=<NEW_PROD_SECRET_KEY>,endpoint='<NEW_PROD_ENDPOINT>',region='<NEW_PROD_REGION>':<NEW_PROD_BUCKET>/<wrong-prefix>"
CORRECT=":s3,provider=Other,access_key_id=<NEW_PROD_ACCESS_KEY>,secret_access_key=<NEW_PROD_SECRET_KEY>,endpoint='<NEW_PROD_ENDPOINT>',region='<NEW_PROD_REGION>':<NEW_PROD_BUCKET_PATH>"

rclone move "$WRONG" "$CORRECT" --transfers 16 --s3-acl public-read --fast-list --progress
```

### 4. Confirm the stack is healthy. 

The full stack was already deployed in step 2 and restarted after the DB restore, so there's nothing further to start here — just confirm `auth`, `api`, `background-worker`, and the website are all up in Coolify.

### 5. Refresh cached DB views:

```bash
docker exec <api-container-name> \
panoramax_backend db refresh
```

(the background worker also does this on `PICTURE_PROCESS_REFRESH_CRON`).

### 6. Derivates.

This deployment hard-codes `PICTURE_PROCESS_DERIVATES_STRATEGY: PREPROCESS` and serves derivates directly from S3 via `API_DERIVATES_PICTURES_PUBLIC_URL` — the API isn't in the request path, so missing derivates won't self-heal (see §6). Derivates are only ever produced by the `background-worker-*` containers pulling `prepare` jobs off the `job_queue` table; restoring the `geovisio` dump does **not** recreate those queue rows (they were already drained the first time these pictures were processed, before the backup was taken), so every picture needs to be requeued after a restore:

```bash
# make sure to fill in db-container-name
# skip_blurring: true avoids re-sending every HD original through the external
# blur API — permanent originals are already blurred (see §1), only the
# derivates (SD/thumbnail/tiles) are actually missing.
docker exec <db-container-name> \
  psql -U gvs -d geovisio -c "
INSERT INTO job_queue (picture_id, task, args)
SELECT id, 'prepare', '{\"skip_blurring\": true}'::jsonb
FROM pictures
ON CONFLICT (picture_id) DO NOTHING;
"
```

The `background-worker-*` services pick these up automatically — no restart needed. Watch the queue drain:

```bash
docker exec <db-container-name> \
  psql -U gvs -d geovisio -Atc "SELECT count(*) FROM job_queue;"
```

It should reach 0 over the next few minutes (check `background-worker-*` logs if it stalls).

### 7. Verify:

Some steps to try:

- `curl --fail https://<your-domain>/api`
- log in via Keycloak (confirms the `keycloak` DB/realm restored and `OAUTH_CLIENT_SECRET` still matches)
- open a picture (confirms HD present + derivate regeneration)
- spot-check collection/picture counts against expectations
- try uploading new images via the panoramax_cli tool

---

## 10. Operating notes

- **Sequence within a night:** images run first (02:00), DB second (02:30). A picture uploaded in between is captured next night; on restore, any DB row whose file isn't present yet is harmless and clears on the next cycle. Perfect point-in-time consistency isn't needed because picture files are immutable.
- **Important! Test that you can restore before you _need_ to restore!!** Do a real restore into a scratch project at least quarterly, and after any major Panoramax or Keycloak upgrade (PostGIS/Keycloak schema versions must match between dump and restore target). Run `restic check` weekly.
- **Retention** defaults to 7 daily / 5 weekly / 12 monthly, overridable via `RESTIC_KEEP_DAILY`/`RESTIC_KEEP_WEEKLY`/`RESTIC_KEEP_MONTHLY` (§5.1, §7.3) — tune to taste. Images rely on `rclone copy` (additive) plus the backup S3 bucket's versioning/lifecycle rule.
- **Schedule** defaults to the times in §7.2, overridable via `BACKUP_CRON_IMAGES`/`BACKUP_CRON_DB`/`BACKUP_CRON_CONFIG`/`BACKUP_CRON_CHECK` — keep images before DB if you change them, since §10's point-in-time reasoning depends on that order.
