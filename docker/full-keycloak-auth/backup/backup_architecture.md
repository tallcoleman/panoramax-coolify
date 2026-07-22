# Backup architecture

How the code in this directory works, and why it's built this way. This is an orientation guide for reading and modifying the backup system — you do not need any of it to run a one-off backup or perform a restore. For those, see [`backup_and_restore_instructions.md`](../../../backup_and_restore_instructions.md).

## Layout

Everything runs inside one small `backup` sidecar container defined in `docker-compose.yml`, driven by [`supercronic`](https://github.com/aptible/supercronic) (a container-friendly cron). Working files are written under `/backups` inside the container (a scratch volume), then shipped externally.

| File | Role |
| --- | --- |
| `Dockerfile` | Alpine base with `postgresql16-client`, `rclone`, `restic`, `gettext` (for `envsubst`), and a pinned `supercronic` binary. |
| `entrypoint.sh` | Renders the crontab from env vars, initialises the restic repo if needed, then execs supercronic. |
| `crontab.template` | The four scheduled jobs, with schedules as `${VAR}` placeholders. |
| `backup-db.sh` | Postgres dumps → restic. |
| `backup-images.sh` | Permanent pictures, production S3 → backup S3, via rclone. |
| `backup-config.sh` | Secrets + Keycloak realm export → restic. |
| `backup-now.sh` | Runs the three backup jobs back-to-back; manual entrypoint. |
| `restic-check.sh` | Weekly repository integrity check. |
| `backup-healthcheck.sh` | Container healthcheck; asserts each job succeeded recently. |
| `fix-object-acls.sh` | Standalone repair tool for object ACLs — not part of the automated jobs. |

## Why two tools

- **`restic`** handles Postgres dumps, the Keycloak export, and secrets/config. It is encrypted (some of this data contains credentials), deduplicated, snapshotted, and has trivial retention via `forget`/`prune`.
- **`rclone`** handles the images (production S3 → backup S3). It is purpose-built for S3-to-S3, transfers only new/changed objects, and — with `copy` rather than `sync` — never deletes from the backup. Panoramax picture files are **immutable** once written, so after the first big sync each run only ships newly-uploaded pictures.

The `copy`-not-`sync` choice is deliberate and load-bearing: an original removed from production is retained in the backup. Switching to `sync` would make the backup an exact mirror, propagating deletions.

## Where Keycloak's data lives

Keycloak shares the **`geovisio` database** with the API but stores its tables in a dedicated **`keycloak` schema** (`KC_DB_SCHEMA: keycloak`, `KC_DB_URL: jdbc:postgresql://db/geovisio`). Because `pg_dump geovisio` captures all schemas by default, the database backup covers Keycloak completely — there is only one database to back up.

This is why `backup-db.sh` needs no Keycloak-specific handling at all. If Keycloak were ever reconfigured onto its own database, the per-database loop described below would pick that up automatically too.

## `backup-db.sh`

Three steps, then a marker file:

1. `pg_dumpall --globals-only` captures roles including passwords (`gvs` is the cluster superuser here).
2. A loop over every non-template database in the cluster, dumping each with `pg_dump -Fc`. Enumerating the databases rather than naming them means a co-located *or* separate Keycloak database is captured either way. The custom format (`-Fc`) is compressed and restorable selectively with `pg_restore`.
3. `restic backup --tag db`, then `restic forget --tag db ... --prune` applying the `RESTIC_KEEP_*` retention.

`set -eu` with no error suppression means any failure aborts the script before the marker file is touched — see the healthcheck section below.

## `backup-images.sh`

Uses rclone "connection strings" so **no config file is needed** — everything comes from env.

The notable design choice is that the *source* side is parsed out of `FS_PERMANENT_URL` rather than re-entered as separate variables. `FS_PERMANENT_URL` is already configured for the api/background-worker services and is passed unchanged to the `backup` service, so production credentials live in exactly one place. The script decomposes the `s3://ACCESS_KEY:SECRET_KEY@bucket/prefix?endpoint_url=<url-encoded>&region=<region>` form with shell parameter expansion and `sed`, percent-decoding the secret key and endpoint.

Two constraints worth knowing before editing it:

- Endpoint and region are **single-quoted** inside the connection string. They may contain `:` (e.g. `https://host`), which rclone would otherwise misread as the connection-string/path separator.
- The parsing assumes `FS_PERMANENT_URL` uses the `s3://` scheme. If production storage moves to a different PyFilesystem backend, build the source connection string manually instead.

The destination is `${BACKUP_S3_BUCKET}/images/permanent`. Only the **permanent** prefix is referenced — `derivates/` and `tmp/` are never touched. That is the space saving.

## `backup-config.sh`

Secrets exist only as env vars injected by Coolify; there is no `.env` file on disk to copy. So the script serializes the ones the backup service has been given into `secrets.env` and ships that under the `config` tag.

`docker-compose.yml`, `keycloak-realm.json`, and themes are deliberately *not* backed up here — they are already in git, and a rebuild just re-deploys the repo in Coolify. The irreplaceable pieces are the secret values, which live solely in Coolify's env var store. Keeping an encrypted copy in restic means a full rebuild needs nothing that isn't backed up.

The same restic invocation also picks up `/backups/keycloak`, the read-only mount of the `kc_export` volume, so the realm export and the secrets land in the same nightly run.

## The `keycloak-export` sidecar

`kc.sh export` produces a portable, human-readable realm snapshot including users **and** password hashes, so it can fully rebuild the realm on a clean Keycloak. Since Keycloak is co-located in the shared Postgres, the DB dump already backs it up — this is a **bonus** safety net, not the primary mechanism.

`kc.sh export` reads directly from Postgres and doesn't need the live HTTP server. Rather than a manual Coolify Scheduled Task, it therefore runs as its own lightweight sidecar service (`keycloak-export`), reusing the same `Dockerfile.keycloak` build as `auth` but overriding the entrypoint with a sleep-loop (`keycloak-export-loop.sh`) instead of starting the server. This keeps the export fully in code, with nothing to configure outside the repo.

Two non-obvious details in its compose block:

- `user: "0:0"` — named volumes are root-owned by default, and Keycloak's image runs as uid 1000, which can't write to `/export` otherwise. This container never listens on a port and only invokes the CLI export, so running as root is low-risk here.
- It is gated on `keycloak-import` completing rather than on `auth`'s health, so it never races the realm import. `service_completed_successfully` is a safe hard dependency against a one-shot job that reliably terminates, unlike `auth`'s own known-flaky healthcheck. `keycloak-export-loop.sh` also retries internally as a defensive fallback.

## Scheduling

The schedule is a **template rendered at container start**, not baked into the image, so it can be overridden per-deployment via env vars without a rebuild. `entrypoint.sh` exports the four `BACKUP_CRON_*` variables with their defaults, runs `envsubst < /etc/crontab.template > /etc/crontab`, and execs supercronic.

This fails closed by design: if a schedule expression is malformed, supercronic errors parsing `/etc/crontab` at startup and the container crash-loops under `restart: unless-stopped` — loud and visible in Coolify's logs, rather than a schedule silently not running.

`entrypoint.sh` also initialises the restic repository on first start. It runs `restic snapshots` to detect an existing repo and falls back to `restic init` if that fails, which avoids erroring out on `init` when the repo already exists. No manual bootstrap step is needed on a new deployment.

## Healthcheck design

A container's health status shouldn't just mean "the cron daemon is alive": supercronic will happily keep running for weeks while `restic backup` fails every night on a bad credential.

So each of the three backup scripts touches a marker file (`/backups/.ok-images`, `.ok-db`, `.ok-config`) as its last line, reachable only if everything above it exited zero. `backup-healthcheck.sh` asserts that each marker exists and isn't stale. A missing marker (nothing has ever succeeded) and a stale one (something's been failing) both report unhealthy.

- The staleness window is 26 hours — a bit past the daily cadence, so the 2am run isn't flagged.
- It uses `find -mmin`, not `stat`, so it works unmodified against BusyBox's `find` in the Alpine base image.
- The compose `healthcheck:` block's `start_period` absorbs the first day, before any backup has had a chance to run.

Nothing else `depends_on` the `backup` service, so this healthcheck doesn't gate any other container's startup. It exists purely so Coolify's UI surfaces "backups have stopped succeeding" instead of showing a container that's merely running.

## Compose wiring

All of the `backup` service's configuration comes from Coolify UI environment variables. Two things are derived rather than entered:

- `RESTIC_REPOSITORY` is composed from `BACKUP_S3_ENDPOINT` and `BACKUP_S3_BUCKET`.
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` are set from the `BACKUP_S3_*` values, because restic's S3 backend reads those standard names for any S3-compatible endpoint.

The operator therefore enters the backup S3 credentials once. The same applies to `FS_PERMANENT_URL`, reused from the api/background-worker config and parsed at runtime by `backup-images.sh`.

Required variables use the `${VAR:?}` suffix, matching the convention used elsewhere in `docker-compose.yml`. Without it, a missing `RESTIC_PASSWORD` or `BACKUP_S3_*` value wouldn't fail until the first cron run — and possibly not until someone noticed backups were missing weeks later. `BACKUP_S3_REGION` is left optional since many S3-compatible providers ignore it.

`PGHOST`/`PGUSER` are hardcoded rather than env-driven. Coolify's Docker Compose buildpack injects every app-level env var into all services, not just the ones referencing it, so a `PGHOST` meant only for `backup` previously broke the `db` service's own init script.

`backup-healthcheck.sh` and the other scripts are picked up automatically by the Dockerfile's `COPY *.sh`, so adding a script needs no separate wiring.
