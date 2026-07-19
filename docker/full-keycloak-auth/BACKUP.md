# Panoramax — Backup & Recovery Strategy

Runbook for a `full-keycloak-auth` Panoramax deployment on **Coolify**, backing up to S3-compatible backup storage, with production images living in S3-compatible production storage, and a weekly copy to an external hard drive.

> Everything here is designed to live **in the repo** (scripts + a `backup` service in the compose file) so backups run automatically with no manual steps.

---

## 1. What needs backing up

A Panoramax instance is made of four kinds of state. Only three of them are irreplaceable.

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

## 2. Tooling & why

Two tools:

- **`restic`** → Postgres dumps, Keycloak export, and secrets/config. Encrypted, deduplicated, snapshotted, with trivial retention (`forget`/`prune`). Supports a wide variety of storage types. Encryption matters here because these blobs contain credentials.
- **`rclone`** → the images (production S3 → backup S3). Purpose-built for S3-to-S3, transfers only new/changed objects, and (with `copy`) never deletes from the backup. Panoramax picture files are **immutable** once written, so after the first big sync each run only ships newly-uploaded pictures.

Both run inside one small **`backup` sidecar** container defined in your compose file, driven by [`supercronic`](https://github.com/aptible/supercronic) (a container-friendly cron). Credentials are declared in code; schedule and retention are also declared in code but overridable via environment variables with sensible defaults (see §7.2 and §7.3).

---

## 3. Confirm how Keycloak stores its data (one command)

In this compose, Keycloak shares the **`geovisio` database** with the API but stores its tables in a dedicated **`keycloak` schema** (`KC_DB_SCHEMA: keycloak`, `KC_DB_URL: jdbc:postgresql://db/geovisio`). Because `pg_dump geovisio` captures all schemas by default, the database backup in §5 already covers Keycloak completely — there is only one database to back up. Confirm it:

```bash
docker compose -p geovisio-auth exec db \
  psql -U gvs -d geovisio -Atc "SELECT schema_name FROM information_schema.schemata;"
```

- If the list includes **`keycloak`** → ✅ Keycloak is in the `geovisio` DB. Covered automatically by §5's `pg_dump geovisio`.
- If it does **not** → Keycloak may be using its own database or a file store. Check `KC_DB*` env vars in the `auth` service, and either add that database to the dump loop in §5.2 or rely on the realm export in §5.4 as the primary Keycloak backup.

Either way, §5.4's `kc.sh export` gives you a **portable** realm+users snapshot as a safety net.

---

## 4. Backup S3 setup (one-time)

1. Create one bucket on your backup S3 provider, e.g. `panoramax-backup`. Two prefixes inside it are used: `restic/` (Postgres dumps, Keycloak export, secrets — via restic) and `images/` (picture files — via rclone).
2. Create an access key scoped to that bucket. Note the access key ID, secret key, endpoint URL, and region.
3. Turn on **Object Versioning** on the bucket and add a **Lifecycle rule** such as *"keep prior/hidden versions for 30 days"*. Because we use `rclone copy` (additive), a picture deleted in production stays in the backup; versioning is a second safety net if you later switch to `sync`.
4. **Record the restic password and backup S3 keys somewhere independent of the server** (password manager, and on the external drive's notes). You cannot restore an encrypted restic repo without them — see §8.

> **Alternative backends.** The scripts below use the generic S3 API on both ends, but rclone also has native remote types for other object stores — e.g. `b2:` for Backblaze B2 (its native API, rather than B2's S3-compatible endpoint) or a `[swift]` remote for OpenStack Swift. The script structure stays the same; just swap the `:s3,...:` connection string in §5.3 for `:b2,account=...,key=...:` or a configured `swift:` remote. Not covered in detail here.

---

## 5. The backup scripts

Create a `backup/` folder in your repo. Working files are written under `/backups` inside the container (a scratch volume), then shipped off-site.

### 5.1 Environment variables

In this deployment every environment variable is configured directly in the **Coolify UI** for each service — there is no `.env` file on disk (`env.example` in the repo is documentation only). The block below shows the variable names to add for the `backup` service in Coolify; it is a reference, not a file to create.

`RESTIC_PASSWORD`, `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY`, `BACKUP_S3_ENDPOINT`, `BACKUP_S3_BUCKET`, `FS_PERMANENT_URL`, `PG_PASSWORD`, `OAUTH_CLIENT_SECRET`, `FLASK_SECRET_KEY`, `KC_DB_PASSWORD`, and `KEYCLOAK_ADMIN_PASSWORD` are **required** — the compose snippet in §7.3 marks them with the `${VAR:?}` syntax (matching the rest of `docker-compose.yml`) so Coolify highlights them in red and the stack refuses to start with a clear error if any is left unset, rather than a backup silently failing at 2am. `BACKUP_S3_REGION`, `PGHOST`, `PGUSER`, and the schedule/retention variables below stay optional — they all have sensible defaults.

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

# ---------- Postgres (reuses your existing PG_PASSWORD) ----------
PGHOST=db
PGUSER=gvs

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
H="${PGHOST:-db}"; U="${PGUSER:-gvs}"

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

SRC=":s3,provider=Other,access_key_id=${SRC_ACCESS_KEY},secret_access_key=${SRC_SECRET_KEY},endpoint=${SRC_ENDPOINT},region=${SRC_REGION}:${SRC_BUCKET_PATH}"
DST=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint=${BACKUP_S3_ENDPOINT},region=${BACKUP_S3_REGION}:${BACKUP_S3_BUCKET}/images/permanent"

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

**Why skipping is safe.** Derivates (SD, thumbnail, tiles) are a cache derived from the permanent HD file. The permanent file is stored **already blurred**, so any regenerated derivate inherits the blur — skipping them creates no privacy regression.

**How they come back depends on `PICTURE_PROCESS_DERIVATES_STRATEGY`:**

- **`ON_DEMAND` (the default).** A missing derivate is generated from the HD original the first time it's requested, then cached. After a restore you do **nothing** — the cache refills lazily as people browse. This is the simplest posture and the reason skipping derivates is low-risk.

- **`PREPROCESS`.** All derivates are generated up front during processing.
  - If derivates are still served **through the API**, the on-demand path remains as a fallback, so a missing file self-heals on request anyway.
  - If you serve derivates **directly from S3** via `API_DERIVATES_PICTURES_PUBLIC_URL` (which *requires* `PREPROCESS`), the API is **not** in the request path, so missing files won't self-heal — you must regenerate them before they'll serve. Do a one-time **warm-up crawl** after restore (§7, step 6), or temporarily serve derivates through the API while the cache refills.

**Recommendation:** unless you have a strong reason to pre-generate, run `ON_DEMAND` so restores are zero-effort for images. If you're on `PREPROCESS` + direct-S3 serving, keep the warm-up script handy.

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
      PGHOST: ${PGHOST:-db}
      PGUSER: ${PGUSER:-gvs}
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

The `:?` suffix marks a variable as required, matching the convention used elsewhere in `docker-compose.yml`: Coolify highlights an unset required variable in red, and `docker compose up` refuses to start with a clear "variable is not set" error instead of silently passing an empty string into the container. Without it, a missing `RESTIC_PASSWORD` or `BACKUP_S3_*` value wouldn't fail until the first cron run — and possibly not until someone notices backups are missing weeks later. `BACKUP_S3_REGION` is left optional since many S3-compatible providers ignore it, and `PGHOST`/`PGUSER` default to the values used elsewhere in this stack (`db`/`gvs`).

`BACKUP_CRON_*` and `RESTIC_KEEP_*` are all optional, defaulting to today's fixed schedule (02:00/02:30/02:45 nightly, weekly integrity check) and retention (7 daily / 5 weekly / 12 monthly). Changing a `RESTIC_KEEP_*` value takes effect on the next scheduled run with no rebuild — just edit the Coolify env var and restart the container. Changing a `BACKUP_CRON_*` value also just needs a restart, but since `entrypoint.sh` renders `/etc/crontab` at container startup, a malformed cron expression will crash-loop the container until fixed (see §7.2) — check the container logs after changing a schedule.

Nothing else `depends_on` the `backup` service, so the `healthcheck:` block above doesn't gate any other container's startup — it exists purely so Coolify's UI surfaces "backups have stopped succeeding" instead of showing a container that's merely running. `backup-healthcheck.sh` is picked up automatically by the Dockerfile's `COPY *.sh` (§7.1), no separate wiring needed.

**First run:** `entrypoint.sh` initialises the restic repo automatically on container startup if it isn't already (it runs `restic snapshots` to detect an existing repo, falling back to `restic init` if that fails) — no manual step needed. After first deploy, trigger a manual run to validate, e.g. `docker compose -p geovisio-auth exec backup backup-db.sh`.

### 7.4 One-off backups

The nightly schedule (§7.2) doesn't need to be the only way a backup runs. `backup/backup-now.sh` runs all three jobs back-to-back, in the same order as the cron schedule (images, then db, then config — see §10 on why that order matters):

```bash
docker compose -p geovisio-auth exec backup backup-now.sh
```

Like the individual scripts, it uses `set -eu` with no error suppression, so it stops at the first failing step rather than continuing on to the next. It doesn't touch `crontab.template` or the container's cron schedule — it's purely an extra, manually-invoked entrypoint alongside the automated one. Useful before/after a risky change, or to validate the backup pipeline without waiting for 2am.

---

## 8. Weekly copy to the external hard drive

Both prefixes copy down cleanly using the same rclone connection-string style as §5.3 (substitute your `BACKUP_S3_*` values):

```bash
BACKUP=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint=${BACKUP_S3_ENDPOINT},region=${BACKUP_S3_REGION}:${BACKUP_S3_BUCKET}"

# Encrypted DB/secrets: copy the restic repo, or use restic's native repo-to-repo copy.
rclone sync "$BACKUP/restic" /mnt/hdd/panoramax/restic
# Images: plain, directly browsable.
rclone sync "$BACKUP/images" /mnt/hdd/panoramax/images
```

**The one decision that affects HDD feasibility:** keep the **images unencrypted** (as above) so the drive is directly browsable, but the DB/secrets live in an **encrypted restic repo**. That means the HDD copy of the DB is useless without the `RESTIC_PASSWORD` and backup S3 keys. **Store those credentials with the drive (offline) and in a password manager.** If you'd rather the HDD be fully self-sufficient with zero secrets, you'd have to drop restic encryption for the DB dumps — not recommended, since those dumps contain user data and password hashes.

---

## 9. Restore / disaster-recovery runbook

Assumes a fresh Coolify host and empty S3.

**0. Recover credentials.** From your password manager/HDD notes, get `RESTIC_PASSWORD` +
`BACKUP_S3_ACCESS_KEY`/`BACKUP_S3_SECRET_KEY`. Everything else can be pulled from restic.

**1. Restore config & secrets.**
```bash
restic restore latest --tag config --target /tmp/restore
# review /tmp/restore/config/secrets.env
```
Recreate the stack in Coolify from your git repo (docker-compose.yml, keycloak-realm.json, and themes come from there, not from restic), then paste the values from `secrets.env` back into the Coolify UI's environment variables for the relevant services.

**2. Bring up Postgres only**, then restore databases into empty targets (PostGIS wants the extension present before data loads):
```bash
restic restore latest --tag db --target /tmp/restore   # -> /tmp/restore/pg/*.dump, globals.sql

# roles (if the gvs role isn't already created by the image)
psql -h db -U gvs -d postgres -f /tmp/restore/pg/globals.sql   # ignore "already exists"

# geovisio
psql -h db -U gvs -d postgres -c "CREATE DATABASE geovisio;"
psql -h db -U gvs -d geovisio -c "CREATE EXTENSION IF NOT EXISTS postgis;"
pg_restore -h db -U gvs -d geovisio --no-owner /tmp/restore/pg/geovisio.dump   # test flags on your data

# keycloak (only if it was co-located)
psql -h db -U gvs -d postgres -c "CREATE DATABASE keycloak;"
pg_restore -h db -U gvs -d keycloak --no-owner /tmp/restore/pg/keycloak.dump
```
*(If you prefer the portable route for Keycloak: skip the keycloak dump and instead start a clean Keycloak with `--import-realm` pointing at the exported `geovisio-realm.json` from §5.4.)*

**3. Restore images.** Repopulate production S3 from the backup S3 (or point the instance at the backup S3 temporarily), using the same connection-string style as §5.3/§8:
```bash
BACKUP=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint=${BACKUP_S3_ENDPOINT},region=${BACKUP_S3_REGION}:${BACKUP_S3_BUCKET}/images/permanent"
PROD=":s3,provider=Other,access_key_id=<new-prod-access-key>,secret_access_key=<new-prod-secret-key>,endpoint=<new-prod-endpoint>,region=<new-prod-region>:<new-prod-bucket>/permanent"

rclone copy "$BACKUP" "$PROD" --transfers 16 --fast-list
```
Leave `derivates/` and `tmp/` empty.

**4. Start the rest** of the stack (keycloak → api → background-worker → website).

**5. Refresh cached DB views:**
`docker compose -p geovisio-auth run --rm --entrypoint bash api -c 'panoramax_backend db refresh'`
(the background worker also does this on `PICTURE_PROCESS_REFRESH_CRON`).

**6. Derivates.**
- `ON_DEMAND`: nothing to do — they rebuild as pictures are viewed.
- `PREPROCESS` + direct-S3 serving: run a warm-up so the cache is rebuilt from the HD originals:
```bash
# list picture ids, then request each derivate once to force regeneration
docker compose -p geovisio-auth exec db \
  psql -U gvs -d geovisio -Atc "SELECT id FROM pictures;" \
| while read id; do
    curl -fsS -o /dev/null "https://<your-domain>/api/pictures/$id/sd.jpg"    || true
    curl -fsS -o /dev/null "https://<your-domain>/api/pictures/$id/thumb.jpg" || true
  done
```

**7. Verify:** `curl --fail https://<your-domain>/api`; log in via Keycloak (confirms the `keycloak` DB/realm restored and `OAUTH_CLIENT_SECRET` still matches); open a picture (confirms HD present + derivate regeneration); spot-check collection/picture counts against expectations.

---

## 10. Operating notes

- **Sequence within a night:** images run first (02:00), DB second (02:30). A picture uploaded in between is captured next night; on restore, any DB row whose file isn't present yet is harmless and clears on the next cycle. Perfect point-in-time consistency isn't needed because picture files are immutable.
- **Test restores are the whole point.** Do a real restore into a scratch project at least quarterly, and after any major Panoramax or Keycloak upgrade (PostGIS/Keycloak schema versions must match between dump and restore target). Run `restic check` weekly.
- **Retention** defaults to 7 daily / 5 weekly / 12 monthly, overridable via `RESTIC_KEEP_DAILY`/`RESTIC_KEEP_WEEKLY`/`RESTIC_KEEP_MONTHLY` (§5.1, §7.3) — tune to taste. Images rely on `rclone copy` (additive) plus the backup S3 bucket's versioning/lifecycle rule.
- **Schedule** defaults to the times in §7.2, overridable via `BACKUP_CRON_IMAGES`/`BACKUP_CRON_DB`/`BACKUP_CRON_CONFIG`/`BACKUP_CRON_CHECK` — keep images before DB if you change them, since §10's point-in-time reasoning depends on that order.
- **Don't back up derivates or tmp** — ever. They're the free lunch here.

