# Panoramax — Backup & Restore Instructions

Backup and Recovery instructions for a `full-keycloak-auth` Panoramax deployment on **Coolify**, backing up to S3-compatible backup storage, with production images living in S3-compatible production storage, and a weekly copy to an external hard drive.

With the exception of the external hard drive backup, the backups are designed to run automatically with no manual steps and all the key configuration contained within the environment variables managed by Coolify.

If you also do the external hard drive backup on a regular schedule, this should allow you to fully implement the [3-2-1 strategy](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/).

Several steps below require running commands inside one of the deployment's containers. Coolify appends unique IDs to container names, so see [running commands in Docker](./deployment_instructions.md#appendix-running-commands-in-docker) for how to find the right name.

For details of how the backup code itself works, see [`backup_architecture.md`](./docker/full-keycloak-auth/backup/backup_architecture.md).

---

## 1. What is backed up

Here is the data used and needed for a functioning application:

| Data                                                                                                                                                                                                       | Where it lives                                         | Replaceable?                    | Back up?            |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------- | ------------------- |
| **Postgres `geovisio` DB** (PostGIS) — all metadata: accounts, collections, sequences, picture records + their file paths, semantics, `configurations` (live settings), TOS pages, excluded areas, reports | `db` service                                           | ❌ No                            | ✅ **Yes**           |
| **Keycloak data** — realm config, clients, **users + password hashes**                                                                                                                                     | Postgres `geovisio` DB, in a dedicated `keycloak` schema | ❌ No                            | ✅ **Yes**           |
| **Permanent (HD) pictures** — the original, already-blurred, high-definition files                                                                                                                         | S3 (`FS_PERMANENT_URL`)                                | ❌ No                            | ✅ **Yes**           |
| **Derivates** — SD, thumbnail, and 360° tiles                                                                                                                                                              | S3 (`FS_DERIVATES_URL`)                                | ✅ **Yes — regenerated from HD** | 🚫 **Skip** (see §3) |
| **`tmp/`** — pictures mid-blur                                                                                                                                                                             | S3 (`FS_TMP_URL`) or disk                              | ✅ Transient                     | 🚫 Skip              |
| **Secrets & config** — Coolify env vars (secrets), `docker-compose.yml`, `keycloak-realm.json`, custom themes                                                                                              | Coolify UI + your repo                                 | ❌ No (secrets)                  | ✅ **Yes**           |

Panoramax splits picture storage into `permanent` (irreplaceable originals) and `derivates` (a disposable cache). The CLI even has `panoramax_backend cleanup --cache` whose only job is to delete derivates — they are explicitly throwaway. Regeneration is covered in §3.

### How it is backed up

Two tools, both running on a nightly schedule inside a single `backup` sidecar container:

- **`restic`** ships the Postgres dumps, Keycloak export, and secrets/config. Encrypted (since some of the data contains credentials), deduplicated, snapshotted, with retention applied automatically.
- **`rclone`** ships the images (production S3 → backup S3), transferring only new pictures after the first run and never deleting from the backup.

Because Keycloak stores its tables in a `keycloak` schema inside the shared `geovisio` database, a single database dump covers both the API and Keycloak. A separate portable realm export is also taken as a safety net.

The default schedule is 02:00 images, 02:30 database, 02:45 config, with a weekly integrity check; retention defaults to 7 daily / 5 weekly / 12 monthly snapshots. Both are adjustable — see [`configuration_options.md`](./configuration_options.md#backup-schedule-and-retention).

---

## 2. Confirming backups work on a new instance

After deploying a new instance, verify the backup pipeline rather than waiting until you need it.

**The restic repository initialises itself.** On container startup the `backup` service detects an uninitialised repo and runs `restic init` automatically — there is no manual bootstrap step.

**Trigger a manual run to validate.** This is the fastest way to catch a bad credential or a misconfigured endpoint:

```bash
docker exec <backup_container_name> backup-db.sh
```

The scripts use `set -eu` with no error suppression, so any failure surfaces immediately rather than being swallowed.

**Confirm Keycloak's data is inside the database being dumped:**

```bash
docker exec <db_container_name> \
  psql -U gvs -d geovisio -Atc "SELECT schema_name FROM information_schema.schemata;"
```

- If the list includes **`keycloak`** → ✅ Keycloak is in the `geovisio` DB and is covered by the database backup.
- If it does **not** → Keycloak may be using its own database or a file store. Check the `KC_DB*` env vars on the `auth` service; the dump loop enumerates every database in the cluster, so a separate Keycloak database is still captured, and the realm export is an additional fallback.

**Watch the container's health status in Coolify.** The `backup` container's healthcheck does not merely report whether cron is alive — each of the three jobs writes a success marker, and the healthcheck reports unhealthy if any marker is missing or older than 26 hours. So:

- **Healthy** → all three jobs (images, db, config) succeeded within the last day.
- **Unhealthy** → something has been failing. Check the container logs.

The healthcheck has a 26-hour start period, so a freshly deployed instance will not report healthy until the first night's runs have completed. Nothing else depends on this container, so an unhealthy `backup` service never blocks the rest of the stack.

**Verify the snapshots actually landed** by listing them from any machine with restic installed (see §6 step 1 for the credential-passing pattern), or wait for the weekly `restic-check.sh` integrity check.

---

## 3. Derivates: why they are skipped, and regenerating on restore

Derivates (SD, thumbnail, tiles) are a cache derived from the permanent HD file. The permanent file is stored already blurred, so any regenerated derivate inherits the blur, and skipping them creates no privacy regression.

How derivates are restored depends on `PICTURE_PROCESS_DERIVATES_STRATEGY`:

- **`PREPROCESS`:** All derivates are generated up front during processing.
  - If derivates are still served through the API, the on-demand path remains as a fallback, so a missing file self-heals on request anyway.
  - If you serve derivates directly from S3 via `API_DERIVATES_PICTURES_PUBLIC_URL` (which *requires* `PREPROCESS`), the API is not in the request path, so missing files won't self-heal — you must requeue every picture for `prepare` after restore (§6, step 6), or temporarily serve derivates through the API while the cache refills.

- **`ON_DEMAND`:** A missing derivate is generated from the HD original the first time it's requested, then cached.

---

## 4. One-off backups

The nightly schedule doesn't need to be the only way a backup runs. `backup-now.sh` runs all three jobs back-to-back, in the same order as the cron schedule (images, then db, then config — see §8 on why that order matters):

```bash
docker exec <backup_container_name> backup-now.sh
```

Like the individual scripts, it uses `set -eu` with no error suppression, so it stops at the first failing step rather than continuing on to the next. It doesn't touch the container's cron schedule — it's purely an extra, manually-invoked entrypoint alongside the automated one. Useful before/after a risky change, or to validate the backup pipeline without waiting for 2am.

You can also run the three jobs individually: `backup-images.sh`, `backup-db.sh`, `backup-config.sh`.

---

## 5. Weekly copy to the external hard drive

Both prefixes copy down cleanly using rclone connection strings (substitute your `BACKUP_S3_*` values):

```bash
BACKUP=":s3,provider=Other,access_key_id=${BACKUP_S3_ACCESS_KEY},secret_access_key=${BACKUP_S3_SECRET_KEY},endpoint='${BACKUP_S3_ENDPOINT}',region='${BACKUP_S3_REGION}':${BACKUP_S3_BUCKET}"

# Encrypted DB/secrets: copy the restic repo, or use restic's native repo-to-repo copy.
rclone sync "$BACKUP/restic" /mnt/hdd/panoramax/restic
# Images: plain, directly browsable.
rclone sync "$BACKUP/images" /mnt/hdd/panoramax/images
```

For the HDD, keep the images unencrypted (as above) so the drive is directly browsable, but the DB/secrets live in an encrypted restic repo. That means the HDD copy of the DB is useless without the `RESTIC_PASSWORD` and backup S3 keys. Store those credentials with the drive (offline) and in a password manager.

---

## 6. Restore / disaster-recovery runbook

Assumes a fresh Coolify project and empty S3.

### 0. Recover credentials.

From your password manager/HDD notes, get `RESTIC_PASSWORD` + `BACKUP_S3_ACCESS_KEY`/`BACKUP_S3_SECRET_KEY`. Everything else can be pulled from restic.

### 1. Restore config & secrets.

From any machine with [restic installed](https://restic.readthedocs.io/en/stable/020_installation.html) and network access to the S3 endpoint (e.g. your own computer), run the following to get the secrets that should be copied into the Coolify UI along with the other environment variables documented in [`configuration_options.md`](./configuration_options.md).

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

### 2. Deploy the full stack, then restore the databases.

Set up the new instance by following [`deployment_instructions.md`](./deployment_instructions.md) — Coolify application settings, S3 buckets, and environment variables — using the secrets you recovered in step 1. If you are restoring onto new storage (e.g. for restore testing or if changing S3-compatible storage providers), you will need to create the three buckets from scratch as described there.

> **⚠️ Overwrite the auto-generated secrets *before* the very first deploy.** Five secrets — `OAUTH_CLIENT_SECRET`, `FLASK_SECRET_KEY`, `PG_PASSWORD`, `KC_DB_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD` — are Coolify Magic Environment Variables (`SERVICE_PASSWORD_64_*`) that Coolify generates *fresh* when you save the compose configuration. Those generated values will not match your backup. As soon as they appear in the Environment Variables UI (after saving the configuration, but **before** you click Deploy), replace each one with the value from your restored `secrets.env`, matching by name — `secrets.env`'s `OAUTH_CLIENT_SECRET` goes into Coolify's `SERVICE_PASSWORD_64_OAUTH_CLIENT_SECRET`, `FLASK_SECRET_KEY` into `SERVICE_PASSWORD_64_FLASK_SECRET_KEY`, and so on — then **double-check every pasted value.** If you deploy with the generated values, `keycloak-import` bakes the wrong `OAUTH_CLIENT_SECRET` into the imported realm and the API won't be able to authenticate (you'd then have to fix the values and redeploy). `RESTIC_PASSWORD` is *not* a magic variable — enter the one you recovered in step 0 the same as any normal variable.

With everything configured, launch the fresh instance. This compose file has a `migrations` service (`db-upgrade`, `restart: "no"`) that `api` waits on via `condition: service_completed_successfully`, and a `keycloak-import` service that imports the realm. Both run automatically on a fresh deploy and create the `geovisio` and `keycloak` schemas — empty of rows, but not empty databases. This is expected: `api`/`background-worker`/website will come up successfully with no data, not crash-loop.

To restore, you will then overwrite the databases with the backup data. Run the restore itself inside the running **`backup`** container — it already bundles `restic`, `psql`, and `pg_restore` and sits on the same Docker network as `db`, so no extra tooling or file-copying between machines is needed:

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

If Keycloak ever uses its own database instead — see the schema check in §2 — restore it the same way: 

```bash
pg_restore -v -h db -U gvs -d keycloak --clean --if-exists /tmp/restore/backups/pg/keycloak.dump
```

Or take the portable route: skip the dump and start a clean Keycloak with an import pointing at the exported `geovisio-realm.json` — that file comes from the `config` tag, not `db`; see step 1 above.

Once the dump is restored, redeploy the project so that `api`, `auth`, and `background-worker` pick up the restored data.

If the restore target's domain differs from the original (true for any test restore per §8's quarterly-drill recommendation, and for a real disaster recovery onto a new domain) — fix the Keycloak `geovisio` client's Root URL, or login will fail with `Invalid parameter: redirect_uri`. `docker-compose.yml` templates the client's `rootUrl` from `GEOVISIO_BASE_URL` (`https://${DOMAIN}`) at realm-import time, but that only happens once, on the *original* instance — the resulting absolute URL is baked into the DB as literal text. The fresh realm import on this new deploy sets it correctly for the new domain, but the `pg_restore --clean --if-exists` you just ran overwrites the `keycloak` schema with the old backed-up realm data, reintroducing the original domain. `redirectUris` is stored as a relative path (`/api/auth/redirect`), so only `rootUrl` needs fixing:

Via Keycloak Admin Console (`<YOUR_INSTANCE_DOMAIN>/oauth`): Clients → `geovisio` → Root URL → set to `https://<new-domain>` → Save. Step 7's login check won't work until this is fixed.

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

Repopulate production S3 from the backup S3 (or point the instance at the backup S3 temporarily), using the same connection-string style as §5:

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

#### Fixing object ACLs after a restore

If you accidentally uploaded or copied over some images without setting them as public, you can fix their acls with `backup/fix-object-acls.sh`. This script parallelizes the `put-object-acl` calls (default 20 concurrent; override with `PARALLEL=n`), shows a live `n/total` progress count per prefix, and logs any failed keys so a retry only needs to touch those (the script is idempotent, so simply re-running it is also safe):

Run it from any machine with `aws` configured (the `backup` container doesn't have the AWS CLI installed, since it's not otherwise needed for the automated nightly jobs):

```bash
docker/full-keycloak-auth/backup/fix-object-acls.sh \
  <PRODUCTION_AUTH_PROFILE_NAME> <PRODUCTION_PUBLIC_BUCKET_NAME> <PRODUCTION_PUBLIC_BUCKET_ENDPOINT> permanent derivates
```
(needs only `bash`, `aws`, and `xargs`.)

This only fixes **existing** objects at the time you run it — it is not a substitute for correctly configuring `FS_PERMANENT_URL`/`FS_DERIVATES_URL` or setting a bucket policy, both covered in [`deployment_instructions.md`](./deployment_instructions.md).

### 4. Confirm the stack is healthy. 

The full stack was already deployed in step 2 and restarted after the DB restore, so there's nothing further to start here — just confirm `auth`, `api`, `background-worker`, and the website are all up in Coolify.

### 5. Refresh cached DB views:

```bash
docker exec <api-container-name> \
panoramax_backend db refresh
```

(the background worker also does this on `PICTURE_PROCESS_REFRESH_CRON`).

### 6. Derivates.

This deployment hard-codes `PICTURE_PROCESS_DERIVATES_STRATEGY: PREPROCESS` and serves derivates directly from S3 via `API_DERIVATES_PICTURES_PUBLIC_URL` — the API isn't in the request path, so missing derivates won't self-heal (see §3). Derivates are only ever produced by the `background-worker-*` containers pulling `prepare` jobs off the `job_queue` table; restoring the `geovisio` dump does **not** recreate those queue rows (they were already drained the first time these pictures were processed, before the backup was taken), so every picture needs to be requeued after a restore:

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

## 7. Rotating secrets & credentials

Use this when a secret is **compromised**, or when the set of authorized users changes and every credential must be re-issued as a precaution. This is not part of a normal restore — nothing is being recovered — but it is a "restore-like" action: you are replacing live secrets in place, and it reuses the same containers and credential-passing patterns as §6.

**The core caveat:** for several secrets, editing the value in the Coolify **Environment Variables** UI is *not* enough. The secret was baked into a Postgres role, into the Keycloak realm, or into the encrypted restic repository at first boot, so changing only the env var makes the running copy and the stored copy silently drift apart — breaking logins, DB connections, or backups the next time the affected service restarts. The table below shows which secrets need extra handling.

The five auto-generated secrets appear in the Coolify UI under their `SERVICE_PASSWORD_64_*` names (e.g. `OAUTH_CLIENT_SECRET` is edited as `SERVICE_PASSWORD_64_OAUTH_CLIENT_SECRET`) — the same mapping used in §6 step 2. `RESTIC_PASSWORD` and the S3 credentials are plain variables under their own names.

As in §6, several steps run commands inside a container; see [running commands in Docker](./deployment_instructions.md#appendix-running-commands-in-docker) for finding the Coolify-suffixed container name.

Wherever a step below asks for a new secret value (`<NEW_...>`), generate a strong random one the same way the deployment docs recommend for `RESTIC_PASSWORD`:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(64))"
```

Its output is URL-safe (only letters, digits, `-`, and `_`), so the same value is also safe to drop into the `postgres://` connection strings that carry `PG_PASSWORD` and `KC_DB_PASSWORD` (§7.3) without further escaping.

| Secret (Coolify name)                                                    | Baked into                                              | Extra step beyond the env var?                                  |
| ------------------------------------------------------------------------ | ------------------------------------------------------ | -------------------------------------------------------------- |
| `FLASK_SECRET_KEY` (`SERVICE_PASSWORD_64_FLASK_SECRET_KEY`)              | nothing (runtime session-signing key)                  | **No** — env var + redeploy `api` (§7.1)                        |
| `OAUTH_CLIENT_SECRET` (`SERVICE_PASSWORD_64_OAUTH_CLIENT_SECRET`)        | Keycloak `geovisio` client (realm import, one-time)    | **Yes** — update it in Keycloak *and* the env var, in sync (§7.2) |
| `PG_PASSWORD` (`SERVICE_PASSWORD_64_PG_PASSWORD`)                        | Postgres `gvs` role (set at first DB init only)        | **Yes** — `ALTER USER gvs …` in the DB (§7.3)                   |
| `KC_DB_PASSWORD` (`SERVICE_PASSWORD_64_KC_DB_PASSWORD`)                  | Postgres `keycloak_user` role (first DB init only)     | **Yes** — `ALTER USER keycloak_user …` in the DB (§7.3)         |
| `KEYCLOAK_ADMIN_PASSWORD` (`SERVICE_PASSWORD_64_KEYCLOAK_ADMIN_PASSWORD`) | Keycloak master-realm admin user (first `auth` boot)   | **Yes** — reset inside Keycloak; env var alone does nothing (§7.4) |
| `RESTIC_PASSWORD`                                                        | the encryption of the entire restic repo               | **Yes, critical** — re-key the repo *before* the env var (§7.5) |
| Production S3 keys (in `FS_TMP_URL`/`FS_PERMANENT_URL`/`FS_DERIVATES_URL`) | nothing in the DB                                     | Rotate at vendor, update all three URLs (§7.6)                  |
| Backup S3 keys (`BACKUP_S3_ACCESS_KEY`/`BACKUP_S3_SECRET_KEY`)           | nothing in the DB                                      | Rotate at vendor, update both vars (§7.6)                       |

After **any** rotation, take a one-off backup (§7.7) — otherwise your newest backup still contains the *old* secrets.

### 7.1 Env-var-only: `FLASK_SECRET_KEY`

This is a pure runtime value (Flask uses it to sign session cookies) with nothing baked into the DB. Rotating it is just: edit `SERVICE_PASSWORD_64_FLASK_SECRET_KEY` in Coolify → redeploy `api`. Rotating it **invalidates every active session**, so all users are logged out and must sign in again — expected, and exactly what you want if a compromise is suspected.

### 7.2 `OAUTH_CLIENT_SECRET` — must match on both sides

This secret exists in two places that must stay identical: the `geovisio` client record inside Keycloak (baked into the `keycloak` schema when the realm was imported — the import runs `--override false`, so re-importing will **never** update it), and the `api` service's env var, which the API sends to Keycloak during the OAuth token exchange. If the two differ, login fails (token exchange is rejected).

Update Keycloak **first**, then the env var:

Via the Keycloak Admin Console (`<YOUR_INSTANCE_DOMAIN>/oauth`, master realm): Clients → `geovisio` → **Credentials** tab → **Regenerate** the secret (or paste a chosen value) → copy the resulting value.

Or via `kcadm.sh`, reusing the pattern from §6 step 2:

```bash
docker exec -it <auth_container_name> sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
CID=$(/opt/keycloak/bin/kcadm.sh get clients -r geovisio -q clientId=geovisio --fields id --format csv --noquotes | tail -1)
/opt/keycloak/bin/kcadm.sh update clients/$CID -r geovisio -s "secret=<NEW_SECRET>"
'
```

Then paste the **same** value into `SERVICE_PASSWORD_64_OAUTH_CLIENT_SECRET` in Coolify and redeploy `api`. Verify by logging in (as in §6 step 7).

### 7.3 Postgres role passwords: `PG_PASSWORD` and `KC_DB_PASSWORD`

Both are Postgres role passwords stored in the database. They are applied only at first DB initialisation — `gvs` from `POSTGRES_PASSWORD`, and `keycloak_user` from `1-init-keycloak-db.sh` — so changing the env var alone leaves the actual role password unchanged, and on the next restart the service can't connect. You must change the password **in the database first**, then update the env var to match, then redeploy the consumers.

Change it in the DB (enter the *current* `PG_PASSWORD` if prompted):

```bash
# PG_PASSWORD — the gvs role (used in every DB_URL)
docker exec -it <db_container_name> \
  psql -U gvs -d geovisio -c "ALTER USER gvs WITH PASSWORD '<NEW_PG_PASSWORD>';"

# KC_DB_PASSWORD — the keycloak_user role
docker exec -it <db_container_name> \
  psql -U gvs -d geovisio -c "ALTER USER keycloak_user WITH PASSWORD '<NEW_KC_DB_PASSWORD>';"
```

Then update the env var in Coolify (`SERVICE_PASSWORD_64_PG_PASSWORD` / `SERVICE_PASSWORD_64_KC_DB_PASSWORD`) to the **exact** same value, and redeploy the services that use it:

- `PG_PASSWORD`: everything with `DB_URL` — `api`, all `background-worker-*`, `migrations` — plus the `backup` service (which also carries `PG_PASSWORD` for `pg_dump`).
- `KC_DB_PASSWORD`: `auth`, `keycloak-export`, `keycloak-import` — plus the `backup` service (it carries this value for the config backup) and the `db` service.

The simplest correct approach is to update the value and redeploy the whole stack, so every consumer picks it up together. A mismatch between the DB and the env var surfaces as connection failures in the affected containers' logs.

### 7.4 `KEYCLOAK_ADMIN_PASSWORD`

The Keycloak master-realm admin password is bootstrapped into the DB the first time `auth` starts (from `KC_BOOTSTRAP_KEYCLOAK_ADMIN_PASSWORD`) and then hashed and stored. Changing the env var afterward has **no effect** on the stored password — you must reset it inside Keycloak.

Via the Keycloak Admin Console (master realm): Users → the admin user (`admin` by default) → **Credentials** → **Reset password** → set a new one (untick "Temporary").

Or via `kcadm.sh`:

```bash
docker exec -it <auth_container_name> sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
/opt/keycloak/bin/kcadm.sh set-password -r master --username "$KEYCLOAK_ADMIN" --new-password "<NEW_ADMIN_PASSWORD>"
'
```

Then update `SERVICE_PASSWORD_64_KEYCLOAK_ADMIN_PASSWORD` in Coolify to the same value — not because the running `auth` service needs it (it doesn't re-read it), but so it stays correct for the `backup` service's `secrets.env` and for any future fresh deploy. (`KEYCLOAK_ADMIN`, the admin *username*, is a plain variable you can likewise change here if desired.)

### 7.5 `RESTIC_PASSWORD` — re-key the repo, do **not** just swap the variable

`RESTIC_PASSWORD` is the key that decrypts the entire restic repository. **Do not** simply change the env var: the existing repo is still encrypted with the old password, so the `backup` container would no longer be able to open it and *every* nightly backup and *every* restore would fail. Instead, add a new key to the existing repo, verify it works, remove the old one, and only then change the env var. Restic keys are repository-level, so a new key grants access to **all** existing snapshots — no history is lost.

From inside the `backup` container (it already has `restic` configured against the repo via its env):

```bash
docker exec -it <backup_container_name> sh

# See the current keys
restic key list

# Add a new key; restic prompts for the NEW password (twice).
# (This authenticates using the current RESTIC_PASSWORD already in the container's env.)
restic key add

# Confirm the new password opens the repo, then remove the OLD key by its ID from `restic key list`.
restic key remove <OLD_KEY_ID>
```

(`restic key passwd` does the add-then-remove in one step if you prefer.) Only **after** the repo is re-keyed, update `RESTIC_PASSWORD` in Coolify to the new value and redeploy `backup`. Finally, update the copy stored in your password manager and with the external drive's offline notes (per §5) — that copy is the only way to decrypt the backups if the server is lost.

### 7.6 S3 bucket credentials

For issuing new keys and revoking the old ones, **follow your S3 vendor's process** — this varies by provider. Below are only the instance-side updates needed so Panoramax keeps working with the new keys. As a safety rule, revoke the old keys at the vendor **only after** confirming the instance works with the new ones (a redeploy plus a successful one-off backup, §7.7) — otherwise a typo locks the instance out of its own storage.

**Production buckets.** The production S3 credentials are embedded *inside* the storage URLs rather than passed as separate variables. The same access key and secret appear in **all three** of `FS_TMP_URL`, `FS_PERMANENT_URL`, and `FS_DERIVATES_URL`, in the form:

```
s3://ACCESS_KEY:SECRET_KEY@bucket/prefix?endpoint_url=<url-encoded-endpoint>&region=<region>
```

Update the `ACCESS_KEY:SECRET_KEY` portion in **each of the three** variables (see the URL format in [`configuration_options.md`](./configuration_options.md)). If the new secret contains URL-special characters (`:`, `/`, `@`, `?`, `&`, `%`, …), **percent-encode** it, or the URL will parse wrong. Then redeploy `api`, all `background-worker-*`, **and** `backup` — the `backup` service reuses `FS_PERMANENT_URL` to sync images each night, so a stale value there silently breaks the nightly image copy.

**Backup bucket.** Update `BACKUP_S3_ACCESS_KEY` and `BACKUP_S3_SECRET_KEY` in Coolify and redeploy `backup`. Both restic (which reads them as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) and rclone read them at runtime, so no repo reconfiguration is required. This is independent of `RESTIC_PASSWORD` and the repo's encryption — rotating the S3 keys does not touch the backup contents. (If you keep an HDD copy per §5, update the same keys in that offline note too.)

### 7.7 After rotating: take a one-off backup

The nightly config backup serialises the five auto-generated secrets into an encrypted `secrets.env`, and the DB dump captures the Postgres role password hashes and Keycloak credentials. Until a fresh backup runs, your most recent snapshot still holds the **old** secrets — so a restore from it would bring the old values back and, worse, wouldn't match a repo you just re-keyed. After rotating, run a one-off backup (see §4):

```bash
docker exec <backup_container_name> backup-now.sh
```

At minimum run `backup-config.sh` (refreshes `secrets.env`), plus `backup-db.sh` whenever you changed a Postgres role password or a Keycloak secret so the dump reflects the new hashes. Note that a config/db backup written *after* a `RESTIC_PASSWORD` re-key is encrypted under the new key — make sure the new password is the one saved in your password manager.

---

## 8. Operating notes

- **Sequence within a night:** images run first (02:00), DB second (02:30). A picture uploaded in between is captured next night; on restore, any DB row whose file isn't present yet is harmless and clears on the next cycle. Perfect point-in-time consistency isn't needed because picture files are immutable.
- **Important! Test that you can restore before you _need_ to restore!!** Do a real restore into a scratch project at least quarterly, and after any major Panoramax or Keycloak upgrade (PostGIS/Keycloak schema versions must match between dump and restore target). Run `restic check` weekly.
- **Retention** defaults to 7 daily / 5 weekly / 12 monthly, overridable via `RESTIC_KEEP_DAILY`/`RESTIC_KEEP_WEEKLY`/`RESTIC_KEEP_MONTHLY` — tune to taste. Images rely on `rclone copy` (additive) plus the backup S3 bucket's versioning/lifecycle rule.
- **Schedule** defaults to 02:00/02:30/02:45 nightly with a weekly integrity check, overridable via `BACKUP_CRON_IMAGES`/`BACKUP_CRON_DB`/`BACKUP_CRON_CONFIG`/`BACKUP_CRON_CHECK` — keep images before DB if you change them, since the point-in-time reasoning above depends on that order.
