# Configuration options

Every environment variable used by this deployment, what it does, and whether you need to set it.

In this deployment, every environment variable is configured directly in the **Coolify UI**, in the Environment Variables menu for the application — there is no `.env` file on disk.

## Required vs optional

Variables marked **Required** below are declared in `docker-compose.yml` with the `${VAR:?}` syntax. That suffix means Coolify highlights the variable in red while it is unset, and `docker compose up` refuses to start with a clear "variable is not set" error rather than silently passing an empty string into the container. Without it, a missing value wouldn't fail until something tried to use it — and possibly not until someone noticed weeks later that, say, backups had never run.

Variables marked **Optional** have a sensible default baked into `docker-compose.yml`; the default is listed with each one.

Note that `PGHOST` and `PGUSER` are **not Coolify-settable at all** — they are hardcoded to `db`/`gvs` directly in `docker-compose.yml` and `backup/backup-db.sh`. Coolify's Docker Compose buildpack injects every app-level env var into all services (not just the ones referencing it), and a `PGHOST` meant only for `backup` interferes with the `db` service's own local init script.

---

## Instance identity

| Variable | Required | Description |
| --- | --- | --- |
| `INSTANCE_NAME` | Optional (default `A Panoramax instance`) | The name of your instance which will appear in the top left of the website. |
| `DOMAIN` | **Required** | URL of your own domain (without a scheme or a path, just the domain). Must match the domain you set for the `reverseproxy` service in Coolify. |

## Secrets

| Variable | Required | Description |
| --- | --- | --- |
| `OAUTH_CLIENT_SECRET` | **Required** | A secret key for the geovisio oauth client in keycloak. |
| `FLASK_SECRET_KEY` | **Required** | [Flask's secret key](https://flask.palletsprojects.com/en/3.0.x/config/#SECRET_KEY). A secret key used among other things for securely signing the session cookie. For production should be provided with a long random string as stated in flask's documentation. |
| `KEYCLOAK_ADMIN` | Optional (default `admin`) | Name of the Keycloak admin account. |
| `KEYCLOAK_ADMIN_PASSWORD` | **Required** | Password of the Keycloak admin account. |
| `PG_PASSWORD` | **Required** | Password of the postgres db account. |
| `KC_DB_PASSWORD` | **Required** | Password for the `keycloak_user` postgres account (used by Keycloak to connect to its DB schema). |

These five values (`OAUTH_CLIENT_SECRET`, `FLASK_SECRET_KEY`, `PG_PASSWORD`, `KC_DB_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`) live solely in Coolify's env var store, so they are the irreplaceable part of your configuration. The backup service keeps an encrypted copy of them — see [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md).

## Picture storage (production S3)

| Variable | Required | Description |
| --- | --- | --- |
| `FS_TMP_URL` | **Required** | Storage for pictures mid-blur. Should point at the private bucket. |
| `FS_PERMANENT_URL` | **Required** | Storage for the original, already-blurred, high-definition pictures. Public bucket. |
| `FS_DERIVATES_URL` | **Required** | Storage for SD, thumbnail, and 360° tiles. Public bucket. |

All three are S3 storage URLs with the credentials embedded in the URL:

```
s3://ACCESS_KEY:SECRET_KEY@bucket-name/subdir?endpoint_url=<url-encoded-endpoint>&region=<region>
```

The `endpoint_url` value must be percent-encoded (e.g. `https://` → `https%3A%2F%2F`) so the URL parser can correctly distinguish it from the rest of the query string. The public bucket URLs should have `&acl=public-read` added to ensure that uploaded assets are public.

Example for OVH Cloud (replace `gra` with your region, and fill in real credentials and bucket names):

```
FS_TMP_URL=s3://ACCESS_KEY:SECRET_KEY@panoramax-private/tmp?endpoint_url=https%3A%2F%2Fs3.gra.io.cloud.ovh.net&region=gra
FS_PERMANENT_URL=s3://ACCESS_KEY:SECRET_KEY@panoramax-public/main-pictures?endpoint_url=https%3A%2F%2Fs3.gra.io.cloud.ovh.net&region=gra&acl=public-read
FS_DERIVATES_URL=s3://ACCESS_KEY:SECRET_KEY@panoramax-public/derivates?endpoint_url=https%3A%2F%2Fs3.gra.io.cloud.ovh.net&region=gra&acl=public-read
```

## Public picture URLs

| Variable | Required | Description |
| --- | --- | --- |
| `S3_PERMANENT_PUBLIC_URL` | **Required** | Public-facing base URL for serving permanent pictures. |
| `S3_DERIVATES_PUBLIC_URL` | **Required** | Public-facing base URL for serving derivates. |

These carry no credentials — they are used by clients to fetch images directly from S3. Example for OVH Cloud: `https://panoramax-public.s3.gra.io.cloud.ovh.net/main-pictures`

## API and instance behaviour

| Variable | Required | Description |
| --- | --- | --- |
| `GEOVISIO_IMAGE_TAG` | Optional (default `latest`) | Tag of the `panoramax/api` image to deploy. Pin to a specific version (e.g. `1.2.3`) to control when you upgrade, or leave as `latest` to always pull the newest release. |
| `INFRA_NB_PROXIES` | Optional (default `2`) | Number of proxies in front of GeoVisio. The default of 2 accounts for Traefik (Coolify) plus nginx, both of which set `X-Forwarded-For`. This parameter is used so that geovisio can trust the `X-Forwarded-` headers for URL generation (more details in the [Flask documentation](https://flask.palletsprojects.com/en/2.2.x/deploying/proxy_fix/)). |
| `API_REGISTRATION_IS_OPEN` | Optional (default `False`) | Whether the instance is open to self-registration (shown in the website UI and federation metadata). Leave as `False` if account creation is admin-only. |
| `BLUR_API` | Optional (default `https://blur.panoramax.openstreetmap.fr`) | Change this if you have your own blur API instance. |

## Website

| Variable | Required | Description |
| --- | --- | --- |
| `WEBSITE_IMAGE_TAG` | Optional (default `latest`) | Tag of the `panoramax/website` image to deploy. Pin to a specific version to control when you upgrade. |
| `VITE_TITLE` | Optional | The title for the `<title>` tag of the HTML. Defaults to `My Panoramax: The free alternative to photo-mapping territories`. |
| `VITE_META_TITLE` | Optional | The title used in meta tags. Same default as `VITE_TITLE`. |
| `VITE_META_DESCRIPTION` | Optional | The description for meta tags, which is useful for SEO. Defaults to a generic description of Panoramax. |

Further website settings are documented in the [Panoramax website settings docs](https://docs.panoramax.fr/website/03_Settings/); only the variables above are wired up to Coolify in this deployment.

---

**Number of picture workers:** not an environment variable — add or remove `background-worker-N` services in `docker-compose.yml` to adjust the count.

**SMTP** is not configured via env vars. The realm imports with no email settings, and Keycloak sends no verification/reset emails until an admin configures SMTP manually in the Keycloak console (Realm settings > Email).

---

## Backup destination

The `backup` service ships encrypted Postgres/Keycloak/secrets dumps (via restic) and copies permanent pictures (via rclone) to an S3-compatible bucket separate from the production buckets above.

| Variable | Required | Description |
| --- | --- | --- |
| `BACKUP_S3_ACCESS_KEY` | **Required** | Access key for the backup bucket. |
| `BACKUP_S3_SECRET_KEY` | **Required** | Secret key for the backup bucket. |
| `BACKUP_S3_ENDPOINT` | **Required** | Endpoint URL for the backup bucket. |
| `BACKUP_S3_BUCKET` | **Required** | Backup bucket name, e.g. `panoramax-backup`. |
| `BACKUP_S3_REGION` | Optional | Region for the backup bucket. Left optional because many S3-compatible providers ignore it or encode it in the endpoint. |
| `RESTIC_PASSWORD` | **Required** | Passphrase protecting the restic repository (Postgres dumps, Keycloak export, secrets). **Store it somewhere independent of the server — it cannot be recovered.** |

You only enter the backup S3 credentials once. `RESTIC_REPOSITORY` and the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION` names that restic's S3 backend expects are *derived* from the `BACKUP_S3_*` values in `docker-compose.yml`, not entered separately.

`FS_PERMANENT_URL` is likewise reused rather than re-entered: the `backup` service is given the same value already set for the api/background-worker services and parses it at runtime, so production credentials are only ever entered once.

## Backup schedule and retention

All optional, with the defaults shown. Changing a retention value takes effect on the next scheduled run with no rebuild — just edit the Coolify env var and restart the container. Changing a schedule also just needs a restart, but a malformed cron expression will crash-loop the backup container until fixed, so check the container logs after changing one.

| Variable | Default | Description |
| --- | --- | --- |
| `BACKUP_CRON_IMAGES` | `0 2 * * *` | When to copy new permanent pictures to the backup bucket. |
| `BACKUP_CRON_DB` | `30 2 * * *` | When to dump and ship the databases. |
| `BACKUP_CRON_CONFIG` | `45 2 * * *` | When to ship secrets and the Keycloak realm export. |
| `BACKUP_CRON_CHECK` | `0 4 * * 0` | When to run the restic integrity check. |
| `RESTIC_KEEP_DAILY` | `7` | Daily restic snapshots to retain. |
| `RESTIC_KEEP_WEEKLY` | `5` | Weekly restic snapshots to retain. |
| `RESTIC_KEEP_MONTHLY` | `12` | Monthly restic snapshots to retain. |
| `KC_EXPORT_INTERVAL_SECONDS` | `86400` | How often the `keycloak-export` sidecar runs `kc.sh export`. The resulting portable realm+users snapshot is picked up by the backup service. |

**Keep the images job scheduled before the DB job if you change the times.** A picture uploaded between the two runs is captured the next night; on restore, a DB row whose file isn't present yet is harmless and clears on the next cycle. Reversing the order breaks that reasoning.
