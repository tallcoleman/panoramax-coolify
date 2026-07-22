# Changelog

All changes relative to the upstream [`docker/full-keycloak-auth`](https://gitlab.com/panoramax/server/api/-/tree/develop/docker/full-keycloak-auth) example.

---

## Pre-built image

**`docker-compose.yml`** — replaced the `x-base-geovisio` build anchor (which pointed at the API source tree) with `image: panoramax/api:${GEOVISIO_IMAGE_TAG:-latest}`. This decouples the deployment repo from the API source code so it can be maintained independently. The image is published to [Docker Hub](https://hub.docker.com/r/panoramax/api).

**`env.example`** — uncommented and clarified `GEOVISIO_IMAGE_TAG` so operators can pin to a specific release.

---

## Coolify platform compatibility

Coolify has several constraints that differ from plain Docker Compose:

- **Named networks removed** — Coolify does not support custom named networks in compose files; the default bridge network is used instead.
- **`deploy.replicas` replaced with explicit services** — Coolify ignores `deploy.replicas`, so the single `background-worker` service with `deploy.replicas: 4` was replaced with four explicitly named services (`background-worker-1` through `background-worker-4`).
- **Bind mounts replaced with baked-in files** — Coolify resolves bind mount paths relative to the Docker host, not the helper container, so files that were bind-mounted into images (`nginx.conf`, `robots.txt`, `1-init-keycloak-db.sh`, `keycloak-realm.json`) are now copied into their respective images at build time via the Dockerfiles.
- **`restart: no` on migrations** — Coolify injects `restart: unless-stopped` on all services; without an explicit override the `migrations` service (which exits 0 on success) would restart in a tight loop.
- **Image tag conflict resolved** — removed the named `panoramax/api:local` tag from the build anchor; BuildKit was persisting the tag across Coolify redeployments and causing conflicts.
- **Traefik labels added** — internal services (`auth`, `api`, `background-worker-*`) have `traefik.enable=false` so Coolify/Traefik does not try to route public traffic directly to them; all external traffic flows through nginx.
- **`exclude_from_hc: true`** on `migrations` and `background-worker-*` — tells Coolify not to include these services in its deployment health gate (migrations exits intentionally; workers have no HTTP health endpoint).

---

## Nginx and proxy fixes

- **Port 80** — changed nginx from port 8080 to port 80 so Traefik's default routing works without configuration.
- **Host port binding removed from `reverseproxy`** — Traefik routes to the internal port; exposing it on the host caused conflicts.
- **RFC 7239 `Forwarded` header stripped** — Traefik sets the `Forwarded` header (RFC 7239) but without a port, which caused Keycloak's `ForwardedHeadersParser` to log errors and misidentify the request origin. nginx now strips it before forwarding to Keycloak: `proxy_set_header Forwarded "";`
- **`Host` header added to `/oauth` proxy block** — ensures Keycloak sees the correct hostname when constructing redirect URLs.
- **`reverseproxy` healthcheck added** — Coolify needs a health signal before marking the stack healthy.
- **`website` healthcheck added** — `curl -sf http://localhost:3000` so Coolify can gate on the frontend being ready.

---

## Keycloak 26.x compatibility

- **Admin bootstrap variable names updated** — Keycloak 26 renamed the bootstrap admin credentials from `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD` to `KC_BOOTSTRAP_KEYCLOAK_ADMIN`/`KC_BOOTSTRAP_KEYCLOAK_ADMIN_PASSWORD`. Updated to match upstream; the `.env` variable names (`KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`) are unchanged.
- **`KC_HOSTNAME_PATH: /oauth`** — tells Keycloak it is deployed under the `/oauth` path prefix so it generates correct redirect URLs and asset paths through nginx.
- **`KC_HTTP_MANAGEMENT_HEALTH_ENABLED: "true"`** — enables Keycloak's management health endpoint on port 9000, required for the healthcheck probe.
- **Auth healthcheck updated** — Keycloak 26's management health endpoints are not reliably available in this build configuration. The healthcheck now hits `/oauth/realms/master` over HTTP/1.0, which proves the database is up, the realm is loaded, and Keycloak is serving requests.
- **Login theme fixed** — the `geovisio` Keycloak client had `loginTheme: "base"` which rendered an unstyled login page. Corrected to `"keycloak"`.

---

## S3 object storage

Migrated from local filesystem storage to S3-compatible object storage:

- Replaced the single `FS_URL` environment variable with three separate variables: `FS_TMP_URL`, `FS_PERMANENT_URL`, and `FS_DERIVATES_URL`, allowing each storage tier to be pointed at a different bucket or prefix.
- Added `S3_PERMANENT_PUBLIC_URL` and `S3_DERIVATES_PUBLIC_URL` for serving pictures directly from S3 without proxying through the API.
- Removed local volume mounts for picture storage from the nginx and API services.
- **nginx `/permanent/` and `/derivates/` location blocks removed** — the upstream config served pictures directly from a local `pic_data` volume via these location blocks. With S3 storage those paths are handled by clients going directly to S3 via `S3_PERMANENT_PUBLIC_URL`/`S3_DERIVATES_PUBLIC_URL`, so the blocks and their UUID-to-path rewrite rule are not needed.
- **`FS_URL` explicitly blanked in compose** — the pre-built `panoramax/api` image has `ENV FS_URL="/data/geovisio"` baked in. Setting `FS_URL: ""` in the `migrations`, `api`, and `background-worker-*` environment blocks overrides it so the split S3 variables are used instead.

---

## Keycloak realm hardening

- **Self-registration disabled** — `registrationAllowed: false` in the realm config; accounts must be created by an admin.
- **Email verification required** — `verifyEmail: true` added to the realm config.
- **`API_REGISTRATION_IS_OPEN`** — added to `docker-compose.yml` and `env.example` (defaults to `False`) to surface the registration policy in the website UI and federation metadata.

---

## Required variable enforcement

Variables that have no default and will cause a broken or cryptic deployment if unset are marked with `:?` in `docker-compose.yml`. Docker Compose (and Coolify) will refuse to start and report a clear error listing any missing variables, rather than silently passing empty strings into containers.

Required variables: `DOMAIN`, `OAUTH_CLIENT_SECRET`, `KEYCLOAK_ADMIN_PASSWORD`, `KC_DB_PASSWORD`, `PG_PASSWORD`, `FLASK_SECRET_KEY`, `FS_TMP_URL`, `FS_PERMANENT_URL`, `FS_DERIVATES_URL`, `S3_PERMANENT_PUBLIC_URL`, `S3_DERIVATES_PUBLIC_URL`.

SMTP variables (`SMTP_HOST`, `SMTP_FROM`, `SMTP_USER`, `SMTP_PASSWORD`) are left as optional bare variables — Keycloak starts without them, email just won't work until configured.

---

## Miscellaneous

- **`WEBSITE_IMAGE_TAG`** introduced as a separate variable from `GEOVISIO_IMAGE_TAG` — the website image is on Docker Hub and needs its own tag; using the same variable caused incorrect image references when deploying non-DockerHub API images.
- **`INFRA_NB_PROXIES=2`** set explicitly — with both Traefik (Coolify) and nginx in the request path before the API, two proxy hops must be declared so Flask trusts the correct `X-Forwarded-For` header for URL generation and rate limiting.
- **`KC_DB_PASSWORD`** parameterised — replaced a hardcoded password in `1-init-keycloak-db.sh` and `docker-compose.yml` with the `KC_DB_PASSWORD` environment variable.
- **`VITE_TITLE`, `VITE_META_TITLE`, `VITE_META_DESCRIPTION`** — made configurable via environment variables with sensible defaults, instead of being hardcoded in the compose file.
- **`INSTANCE_NAME` defaults aligned** — the website's `VITE_INSTANCE_NAME` fell back to `A geovisio instance` while the API's `API_SUMMARY` fell back to `A Panoramax instance`. An operator who left the variable unset got a different name in the site header than in the API summary and federation metadata. Both now default to `A Panoramax instance`.

---

## Backup runbook added

`BACKUP.md` — comprehensive runbook for backing up a production Panoramax instance to Backblaze B2, covering:
- PostgreSQL dumps (geovisio + keycloak schemas) encrypted with restic
- Permanent HD pictures synced S3-to-S3 with rclone (derivates deliberately excluded)
- Keycloak realm export as a portable recovery artefact
- Secrets and config backup
- Full disaster-recovery procedure
- Weekly copy to an external hard drive

---

## Backup service implemented

The `backup/` sidecar described in `BACKUP.md` §5/§7 is now wired into the stack:

- **New `backup/` directory** — `Dockerfile` (Alpine + restic, rclone, `postgresql16-client`, `supercronic`), `entrypoint.sh` (renders the cron schedule from env vars via `envsubst`), `crontab.template`, and the backup scripts (`backup-db.sh`, `backup-images.sh`, `backup-config.sh`, `backup-healthcheck.sh`, `restic-check.sh`).
- **`docker-compose.yml`** — added the `backup` service (restic repository derived from `BACKUP_S3_*`, all required secrets/credentials reused rather than re-entered), a `backup_scratch` volume for working files, and a `kc_export` volume for the portable Keycloak realm snapshot (see "Keycloak realm export automated" below).
- **`env.example`** — documented the new `BACKUP_S3_*`, `RESTIC_PASSWORD`, `PGHOST`/`PGUSER`, `BACKUP_CRON_*`, and `RESTIC_KEEP_*` variables.

Out of scope (operational, not code): the weekly HDD copy (§8) and the disaster-recovery runbook (§9).

---

## Keycloak realm export automated

`BACKUP.md` §5.4 originally called for a Coolify Scheduled Task to trigger `kc.sh export` — the one manual step in an otherwise all-code backup setup. Replaced with a code-only approach:

- **New `keycloak-export-loop.sh`** — a sleep-loop entrypoint that calls `kc.sh export --optimized --dir /export --users realm_file --realm geovisio` once at startup and then every `KC_EXPORT_INTERVAL_SECONDS` (default daily). `kc.sh export` reads directly from Postgres and doesn't need the live HTTP server, so this runs as its own sidecar rather than inside the running `auth` process.
- **`Dockerfile.keycloak`** — copies the loop script into the image (`COPY --chmod=755`); the default `auth` entrypoint/command is unaffected.
- **`docker-compose.yml`** — added a `keycloak-export` service reusing the `auth` service's build (via a new `x-base-keycloak` anchor) but overriding the entrypoint to the export loop and running with only the DB connection env vars it actually needs. Runs as `user: "0:0"` — the `kc_export` named volume is root-owned by default and Keycloak's image runs as uid 1000, which can't write to it otherwise; this container never listens on a port and only invokes the CLI export, so the tradeoff is low-risk.
- **`backup/backup-config.sh`** — the restic `config` backup now also includes `/backups/keycloak` (the read-only `kc_export` mount), so the realm snapshot ships in the same nightly run as the secrets it already backs up.

A dedicated Keycloak-based sidecar was necessary rather than folding this into the existing Alpine `backup` container: `kc.sh export` requires the full Keycloak/Quarkus JVM runtime built for glibc, which can't be cleanly embedded in the musl-based Alpine image without re-basing it entirely.

---

## Backup sidecar crash-loop fixes

The `backup` and `keycloak-export` sidecars both crash-looped in practice after initial rollout; each was root-caused and fixed independently:

- **supercronic `-no-reap`** — supercronic's zombie-reaping only activates when it detects it's running as PID 1, and that reaping logic crashed immediately on startup (before any cron job ran), restarting the `backup` container in a tight loop. Runs with `-no-reap` now and lets Docker's own init (tini) handle reaping.
- **`kc.sh export --optimized`** — plain `kc.sh export` re-augments the Quarkus build config at runtime, and since `KC_DB=postgres` is a build-time property not mirrored as a runtime env var on `keycloak-export`, re-augmentation silently dropped the Postgres JDBC driver config and broke every export. `--optimized` reuses the build already baked into the image, matching how `auth` itself runs `start --optimized`.
- **Auto-initialize the restic repo** — fresh deploys crash-looped every backup/check job overnight because the restic S3 repo was never initialized. `entrypoint.sh` now detects an uninitialized repo and runs `restic init` automatically instead of requiring a manual first-run step.
- **rclone connection strings quoted** — rclone's inline connection-string syntax uses `:` as the remote/path separator, so an unquoted `endpoint=https://host` value was misparsed into an "unsupported protocol scheme" error. `endpoint`/`region` are now single-quoted in `backup-images.sh` and the matching `BACKUP.md` examples.
- **`backup-images.sh` logs transfer stats** — rclone's default log level (NOTICE) suppresses the final "Transferred:" summary, so a clean nightly run produced no output at all. Added `-v` so the stats line always prints, making it possible to confirm from logs alone that a sync did something.

---

## Keycloak realm import stability

`auth`'s `start --optimized --import-realm` was re-importing the realm file on every boot instead of once, and `keycloak-export` intermittently raced it during startup. Root-caused and fixed as a sequence:

- **One-shot `keycloak-import` service** — `--import-realm` triggers Keycloak's own internal restart after import completes, but that self-restart was happening before the import's DB write committed, so every subsequent boot still found no realm, re-imported, and restarted again — an infinite loop (`auth` cycling every ~15-25s, `keycloak-export` perpetually failing with "realm not found by realm name 'geovisio'"). A new `keycloak-import` service (`restart: "no"`) now runs `kc.sh import` once against the DB before `auth` or `keycloak-export` start; `auth` starts with plain `start --optimized` (no import flag), and both `auth` and `keycloak-export` gate on `keycloak-import`'s `service_completed_successfully`.
- **`keycloak-import` points `--file` at the realm file directly** — `--dir /opt/keycloak/data/import` only logged a directory scan and never actually imported `geovisio_realm.json` (no `SingleFileImportProvider` log line). Master realm bootstrap succeeded regardless, masking the failure until `keycloak-export` surfaced it. Pointing `--file` directly at `geovisio_realm.json` is unambiguous.
- **`keycloak-export` retries with backoff instead of exiting** — with no ordering dependency on `auth`, `keycloak-export` could run before the realm was imported and fail with "realm not found." Under `set -eu` that exited the script and restarted the whole container on `restart: unless-stopped`, triggering a full JVM boot on every retry with no backoff — a second Keycloak JVM competing for CPU/DB alongside `auth` and likely contributing to `auth`'s own startup instability. The export loop now retries in place every 30s until it succeeds, without restarting the container.
- **`keycloak-export` serialized after `auth`'s healthcheck, then that dependency reverted** — both `auth` and `keycloak-export` run Keycloak's Liquibase migration on boot; on a fresh schema they raced to create the changelog table, crashing `keycloak-export` with "relation databasechangelog already exists." Adding `depends_on: auth: condition: service_healthy` fixed the race but turned `auth`'s already-flaky healthcheck into a hard deploy blocker, which Coolify then retried as a full redeploy loop — so the hard dependency was reverted once `keycloak-export`'s own retry-with-backoff loop (above) made the race self-healing without needing compose-level ordering.
- **`auth` healthcheck downgraded to a bare TCP-connect check** — the previous check sent a real GET to `/oauth/realms/master` requiring a 200, which only succeeds once realm import fully finishes. On Coolify, something restarts unhealthy containers on a shorter timeout than compose's own `start_period` (observed ~23-29s restarts vs. a configured 60s `start_period` + 5x5s retries), so `auth` never got far enough into startup to pass before being killed and restarted, looping indefinitely. The healthcheck is now a bare TCP-connect (liveness, not readiness) — dependents may see a few seconds of 503s from `auth` right after it's marked healthy.
- **`PGHOST`/`PGUSER` hardcoded** — both always matched the `db` service's own name/user, so making them Coolify-configurable had no real use case and was a footgun: Coolify's Docker Compose buildpack injects every app-level env var into all services, and a `PGHOST` meant only for `backup` previously broke `db`'s own local init script when set. Removed from `env.example`; hardcoded in `docker-compose.yml` and `backup-db.sh`.

---

## Backup operator tooling

- **`backup/backup-now.sh`** — combines the images/db/config scripts into a single manually-invoked entrypoint for one-off backup runs, layered on top of the existing daily cron schedule.
- **`backup/fix-object-acls.sh`** — some S3-compatible providers (e.g. OVH) don't support bucket policies, so making objects publicly readable after a restore requires setting `public-read` ACL per-object. Parallelizes the calls and reports progress.

---

## S3 public-read ACLs for public paths

Added `public-read` ACL to the public S3 paths in `env.example` so the website can load pictures directly from S3 (via `S3_PERMANENT_PUBLIC_URL`/`S3_DERIVATES_PUBLIC_URL`) without a bucket policy — needed on providers that don't support them (see `fix-object-acls.sh` above for backfilling existing objects).

---

## `BACKUP.md` §9 restore procedure corrected

The restore runbook's "bring up Postgres only, then `CREATE DATABASE`" steps didn't reflect how this stack actually starts: the `migrations` and `auth` (`--import-realm`, later `keycloak-import`) services auto-create empty `geovisio`/`keycloak` schemas on a fresh deploy, so a restore lands on top of a pre-existing empty schema rather than a blank database. Rewritten so `pg_restore` uses `--clean --if-exists` to overwrite that pre-existing schema, clarifies which commands run in the `backup` container vs. any machine, and states that the derivates warm-up is mandatory (not optional) for this deployment's `PREPROCESS` + direct-S3-serving configuration.
