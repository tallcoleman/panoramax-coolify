# Panoramax — Backup & Recovery Strategy

Runbook for a `full-keycloak-auth` Panoramax deployment on **Coolify**, backing up to S3-compatible archive storage, with production images living in S3-compatible application storage, and a weekly copy to an external hard drive.

> Everything here is designed to live **in the repo** (scripts + a `backup` service in the compose file) so backups run automatically with no manual steps. Coolify Scheduled Tasks are offered as an alternative where useful.

---

## 1. What needs backing up

A Panoramax instance is made of four kinds of state. Only three of them are irreplaceable.

| Data                                                                                                                                                                                                       | Where it lives                                         | Replaceable?                    | Back up?            |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------- | ------------------- |
| **Postgres `geovisio` DB** (PostGIS) — all metadata: accounts, collections, sequences, picture records + their file paths, semantics, `configurations` (live settings), TOS pages, excluded areas, reports | `db` service                                           | ❌ No                            | ✅ **Yes**           |
| **Keycloak data** — realm config, clients, **users + password hashes**                                                                                                                                     | Postgres `keycloak` DB *or* a Keycloak volume (see §3) | ❌ No                            | ✅ **Yes**           |
| **Permanent (HD) pictures** — the original, already-blurred, high-definition files                                                                                                                         | OVHcloud S3 (`FS_PERMANENT_URL`)                       | ❌ No                            | ✅ **Yes**           |
| **Derivates** — SD, thumbnail, and 360° tiles                                                                                                                                                              | OVHcloud S3 (`derivates/`)                             | ✅ **Yes — regenerated from HD** | 🚫 **Skip** (see §6) |
| **`tmp/`** — pictures mid-blur                                                                                                                                                                             | OVHcloud S3 or disk                                    | ✅ Transient                     | 🚫 Skip              |
| **Secrets & config** — `.env`, `docker-compose.yml`, `keycloak-realm.json`, custom themes                                                                                                                  | Your repo + Coolify                                    | ❌ No (secrets)                  | ✅ **Yes**           |

Panoramax splits picture storage into `permanent` (irreplaceable originals) and `derivates` (a disposable cache). The CLI even has `panoramax_backend cleanup --cache` whose only job is to delete derivates — they are explicitly throwaway. Regeneration is covered in §6.

---

## 2. Tooling & why

Two tools:

- **`restic`** → Postgres dumps, Keycloak export, and secrets/config. Encrypted, deduplicated, snapshotted, with trivial retention (`forget`/`prune`). Supports a wide variety of storage types. Encryption matters here because these blobs contain credentials.
- **`rclone`** → the images (OVHcloud S3 → Backblaze B2). Purpose-built for S3-to-S3, transfers only new/changed objects, and (with `copy`) never deletes from the backup. Panoramax picture files are **immutable** once written, so after the first big sync each run only ships newly-uploaded pictures.

Both run inside one small **`backup` sidecar** container defined in your compose file, driven by [`supercronic`](https://github.com/aptible/supercronic) (a container-friendly cron). All schedules, retention, and credentials are declared in code.

---

## 3. Confirm how Keycloak stores its data (one command)

This compose *usually* runs Keycloak against the **same Postgres cluster** as the API (a separate `keycloak` database on the `db` service). If so, the database backup in §5 already covers Keycloak completely and you need nothing extra. Confirm it:

```bash
docker compose -p geovisio-auth exec db \
  psql -U gvs -d postgres -Atc "SELECT datname FROM pg_database WHERE datistemplate=false;"
```

- If the list includes **`keycloak`** → co-located. ✅ Covered automatically by §5's dump loop.
- If it does **not** → Keycloak is using its own DB or a file store. Find its volume in
 `docker-compose.yml` (look at the `keycloak` service's `volumes:` and `KC_DB*` env), and either point the DB dump at that database too, or rely on the realm export in §5.4 as the primary Keycloak backup.

Either way, §5.4's `kc.sh export` gives you a **portable** realm+users snapshot as a safety net.

---

## 4. Backblaze B2 setup (one-time)

1. Create two buckets, e.g. `panoramax-backups` (restic) and `panoramax-images-backup` (rclone).
2. Create an **Application Key** scoped to those buckets. Note the `keyID` and `applicationKey`.
3. On `panoramax-images-backup`, turn on **Object Versioning** and add a **Lifecycle rule** such as *"keep prior/hidden versions for 30 days"*. Because we use `rclone copy` (additive), a picture deleted in production stays in the backup; versioning is a second safety net if you later switch to `sync`.
4. **Record the restic password and B2 keys somewhere independent of the server** (password manager, and on the external drive's notes). You cannot restore an encrypted restic repo without them — see §8.

---

## 5. The backup scripts

Create a `backup/` folder in your repo. Working files are written under `/backups` inside the container (a scratch volume), then shipped off-site.

### 5.1 `.env` additions

```dotenv
# ---------- Backblaze B2 ----------
B2_ACCOUNT_ID=xxxxxxxxxxxx
B2_ACCOUNT_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
RESTIC_REPOSITORY=b2:panoramax-backups:restic
RESTIC_PASSWORD=<LONG-RANDOM-PASSPHRASE-STORED-OFFSITE>

# ---------- Image backup: source (OVH S3) ----------
OVH_S3_ACCESS_KEY=xxxx
OVH_S3_SECRET_KEY=xxxx
OVH_S3_ENDPOINT=https://s3.gra.io.cloud.ovh.net   # adjust to your OVH region
OVH_S3_REGION=gra
# bucket/prefix holding the HD originals. If you used a single FS_URL, this is
# "<bucket>/permanent". If you set FS_PERMANENT_URL directly, use that bucket/prefix.
OVH_PERMANENT_PATH=my-ovh-bucket/permanent

# ---------- Image backup: destination (B2) ----------
B2_IMAGES_BUCKET=panoramax-images-backup

# ---------- Postgres (reuses your existing PG_PASSWORD) ----------
PGHOST=db
PGUSER=gvs
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

# 3) Ship encrypted to B2, then apply retention.
restic backup --host panoramax --tag db "$OUT"
restic forget --host panoramax --tag db \
  --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
```

### 5.3 `backup/backup-images.sh` — OVH S3 → B2 (permanent only)

Uses rclone "connection strings" so **no config file** is needed — everything comes from env.

```sh
#!/bin/sh
set -eu

SRC=":s3,provider=Other,access_key_id=${OVH_S3_ACCESS_KEY},secret_access_key=${OVH_S3_SECRET_KEY},endpoint=${OVH_S3_ENDPOINT},region=${OVH_S3_REGION}:${OVH_PERMANENT_PATH}"
DST=":b2,account=${B2_ACCOUNT_ID},key=${B2_ACCOUNT_KEY}:${B2_IMAGES_BUCKET}/permanent"

# 'copy' is additive: it never deletes from the backup, so originals removed in
# production are retained. Swap to 'sync' only if you want an exact mirror.
rclone copy "$SRC" "$DST" \
  --transfers 16 --checkers 32 --fast-list --stats-one-line
```

Note we deliberately reference only the **permanent** prefix — `derivates/` and `tmp/` are never touched. That is the space saving.

### 5.4 `backup/backup-keycloak.sh` — portable realm export (optional but recommended)

If Keycloak is co-located in the shared Postgres (§3), the DB dump already backs it up fully and this is a **bonus** portable/human-readable snapshot. `kc.sh export` includes users **and** password hashes, so it can fully rebuild the realm on a clean Keycloak.

The clean, socket-free way is to let Keycloak write the export to a **shared named volume** that the backup container also mounts, then let restic pick it up. Trigger the export with a Coolify Scheduled Task on the `keycloak` container:

```bash
# Coolify Scheduled Task → container: keycloak → schedule: 0 3 * * *
/opt/keycloak/bin/kc.sh export --dir /export --users realm_file --realm geovisio
```

…where the compose gives both services a shared volume:

```yaml
  keycloak:
    volumes:
      - kc_export:/export
  backup:
    volumes:
      - kc_export:/backups/keycloak:ro
volumes:
  kc_export:
```

The nightly restic run (below) then includes `/backups/keycloak`. `kc.sh export` runs as a one-shot command and does not bind the HTTP port, so it's safe alongside the running server — but test it once on your version.

### 5.5 `backup/backup-config.sh` — secrets & config

```sh
#!/bin/sh
set -eu
OUT=/backups/config
rm -rf "$OUT"; mkdir -p "$OUT"

# Mount your stack dir read-only into the backup container at /stack (see compose).
cp /stack/.env                  "$OUT/env.bak"            2>/dev/null || true
cp /stack/docker-compose.yml    "$OUT/"                   2>/dev/null || true
cp /stack/keycloak-realm.json   "$OUT/"                   2>/dev/null || true
cp -r /stack/themes             "$OUT/themes" 2>/dev/null || true

restic backup --host panoramax --tag config "$OUT"
restic forget --host panoramax --tag config \
  --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
```

> Your `docker-compose.yml`, `keycloak-realm.json`, and themes are already in git — the irreplaceable secret is `.env` (it holds `FLASK_SECRET_KEY`, `OAUTH_CLIENT_SECRET`, `PG_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`). Keeping an encrypted copy in restic means a full rebuild needs nothing that isn't backed up.

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

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache postgresql16-client rclone restic ca-certificates tzdata curl \
 && curl -fsSL -o /usr/local/bin/supercronic \
      https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
 && chmod +x /usr/local/bin/supercronic
COPY *.sh /usr/local/bin/
COPY crontab /etc/crontab
RUN chmod +x /usr/local/bin/*.sh
CMD ["supercronic", "/etc/crontab"]
```

### 7.2 `backup/crontab`

```cron
# min hour dom mon dow  command
0 2 * * *   backup-images.sh     # nightly: new HD pictures OVH -> B2
30 2 * * *  backup-db.sh         # nightly: geovisio + keycloak + roles -> B2 (encrypted)
45 2 * * *  backup-config.sh     # nightly: .env + compose + realm + themes -> B2 (encrypted)
0 4 * * 0   restic-check.sh      # weekly integrity check (optional)
```

`restic-check.sh` can be a one-liner: `restic check --read-data-subset=5%`.

### 7.3 compose service (add to `docker-compose.yml`)

```yaml
  backup:
    build: ./backup
    restart: unless-stopped
    depends_on: [db]
    environment:
      PG_PASSWORD: ${PG_PASSWORD}
      PGHOST: ${PGHOST}
      PGUSER: ${PGUSER}
      RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}
      RESTIC_PASSWORD: ${RESTIC_PASSWORD}
      B2_ACCOUNT_ID: ${B2_ACCOUNT_ID}
      B2_ACCOUNT_KEY: ${B2_ACCOUNT_KEY}
      OVH_S3_ACCESS_KEY: ${OVH_S3_ACCESS_KEY}
      OVH_S3_SECRET_KEY: ${OVH_S3_SECRET_KEY}
      OVH_S3_ENDPOINT: ${OVH_S3_ENDPOINT}
      OVH_S3_REGION: ${OVH_S3_REGION}
      OVH_PERMANENT_PATH: ${OVH_PERMANENT_PATH}
      B2_IMAGES_BUCKET: ${B2_IMAGES_BUCKET}
    volumes:
      - backup_scratch:/backups
      - kc_export:/backups/keycloak:ro          # from §5.4, if used
      - /path/to/your/stack:/stack:ro           # so backup-config.sh can read .env etc.
volumes:
  backup_scratch:
  kc_export:
```

**First run:** initialise the restic repo once (from the backup container):
`docker compose -p geovisio-auth exec backup restic init`. Then trigger a manual run to validate,
e.g. `docker compose -p geovisio-auth exec backup backup-db.sh`.

### 7.4 Alternative: Coolify Scheduled Tasks (no sidecar)

If you'd rather not add a container, put the same scripts on a small volume and register three Coolify Scheduled Tasks that run them (Coolify executes a command inside a chosen service's container on a cron). Trade-off: the schedule then lives in Coolify's config rather than your git repo, which is slightly less "one place." Coolify also has a **native Postgres backup-to-S3** feature, but it targets Coolify-*managed* database resources; a DB running as part of a compose stack (as here) is best served by the `pg_dump` approach above.

---

## 8. Weekly copy to the external hard drive

Both destinations copy down cleanly:

```bash
# Encrypted DB/secrets: copy the restic repo, or use restic's native repo-to-repo copy.
rclone sync b2:panoramax-backups /mnt/hdd/panoramax/restic
# Images: plain, directly browsable.
rclone sync b2:panoramax-images-backup /mnt/hdd/panoramax/images
```

**The one decision that affects HDD feasibility:** keep the **images unencrypted** (as above) so the drive is directly browsable, but the DB/secrets live in an **encrypted restic repo**. That means the HDD copy of the DB is useless without the `RESTIC_PASSWORD` and B2 keys. **Store those credentials with the drive (offline) and in a password manager.** If you'd rather the HDD be fully self-sufficient with zero secrets, you'd have to drop restic encryption for the DB dumps — not recommended, since those dumps contain user data and password hashes.

---

## 9. Restore / disaster-recovery runbook

Assumes a fresh Coolify host and empty S3.

**0. Recover credentials.** From your password manager/HDD notes, get `RESTIC_PASSWORD` +
`B2_ACCOUNT_ID`/`B2_ACCOUNT_KEY`. Everything else can be pulled from restic.

**1. Restore config & secrets.**
```bash
restic restore latest --tag config --target /tmp/restore
# review /tmp/restore/config/env.bak -> becomes your .env; recover compose/realm/themes
```
Recreate the stack in Coolify from your repo + restored `.env`.

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

**3. Restore images.** Repopulate OVH from B2 (or point the instance at B2 temporarily):
```bash
rclone copy b2:panoramax-images-backup/permanent ovh:my-ovh-bucket/permanent \
  --transfers 16 --fast-list
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
- **Retention** is set in the `forget` flags (7 daily / 5 weekly / 12 monthly) — tune to taste. Images rely on `rclone copy` (additive) plus B2 versioning/lifecycle.
- **Don't back up derivates or tmp** — ever. They're the free lunch here.

