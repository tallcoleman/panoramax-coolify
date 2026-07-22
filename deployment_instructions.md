# Deploying a Panoramax instance to Coolify

Step-by-step instructions for deploying a new `full-keycloak-auth` Panoramax instance on [Coolify](https://coolify.io).

If you are restoring an existing instance from a backup rather than starting fresh, follow this document first to get a working empty instance, then continue with [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md).

---

## 1. Prerequisites

- A domain with TLS termination handled upstream (Coolify/Traefik does this)
- An S3-compatible object store for pictures (e.g. OVH Cloud Object Storage, Backblaze B2)
- Optionally, an SMTP server. It is not needed to deploy, and is not configured by environment variables — the realm imports with no email settings and Keycloak sends no verification or password-reset emails until an admin sets SMTP up manually in the Keycloak console (see step 6).

---

## 2. Set up S3-compatible object storage

You need three S3-compatible buckets:

- **Production Public** (used for `FS_PERMANENT_URL`, `FS_DERIVATES_URL`, `S3_PERMANENT_PUBLIC_URL`, and `S3_DERIVATES_PUBLIC_URL`): encryption is good, but you don't need versioning or object lock set for this one. You will have to make it publicly accessible and set CORS headers (see below).
- **Production Private** (`FS_TMP_URL`): encryption is good, but you don't need versioning or object lock set for this one. This should not be public.
- **Backup** (for all the `BACKUP_S3_*` environment variables): for this one you should enable encryption, versioning, and a lifecycle rule that objects are retained for 30 days. This should not be public.

Terminology and set-up vary between providers (e.g. as of 2026-07 Backblaze automatically enables versioning), so make sure to check your provider-specific documentation as well.

### 2.1 Backup bucket details

Two prefixes are used inside the backup bucket: `restic/` (Postgres dumps, Keycloak export, secrets — via restic) and `images/` (picture files — via rclone). You do not need to create these by hand; the backup service creates them on first run.

Create an access key scoped to that bucket, and note the access key ID, secret key, endpoint URL, and region (if applicable).

Turn on **Object Versioning** and add a **Lifecycle rule** such as *"keep prior/hidden versions for 30 days"*. Because the backup service uses `rclone copy` (additive), a picture deleted in production stays in the backup; versioning is a second safety net if you later switch to `sync`.

> **Record the restic password and backup S3 keys somewhere independent of the server** (password manager, and on the external drive's notes). You cannot restore an encrypted restic repo without them.

> **Alternative backends.** The backup scripts use the generic S3 API on both ends, but rclone also has native remote types for other object stores — e.g. `b2:` for Backblaze B2 (its native API, rather than B2's S3-compatible endpoint) or a `[swift]` remote for OpenStack Swift. The script structure stays the same; just swap the `:s3,...:` connection string for `:b2,account=...,key=...:` or a configured `swift:` remote. Not covered in detail here.

### 2.2 CORS and public access on the Production Public bucket

Usually to manage access and CORS headers, you have to use the S3 api. The examples below assume you are using an auth profile; more [information on setting up authentication for the S3 API can be found in the official docs](https://docs.aws.amazon.com/cli/v1/userguide/cli-configure-files.html).

#### Step A — Add CORS rules to Production Public:

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

#### Step B — Make Production Public assets publicly readable:

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

---

## 3. Create the Coolify application

Follow the [instructions for a Coolify docker compose deployment](https://coolify.io/docs/applications/build-packs/docker-compose), pointing Coolify at this repository with the following settings:

- Git source: https://github.com/tallcoleman/panoramax-coolify.git
- Base directory: `/docker/full-keycloak-auth`
- Docker compose location: `/docker-compose.yml` (slight change, default is `.yaml`)
- Fill out "domain for reverseproxy" (leave the others blank) and make sure to put the same domain (without the `https://` prefix) in the `DOMAIN` environment variable as well

---

## 4. Set the environment variables

Every environment variable is configured directly in the Coolify UI, in the Environment Variables menu — there is no `.env` file on disk.

See [`configuration_options.md`](./configuration_options.md) for the full list of variables, which ones are required, and what each one does.

---

## 5. Deploy

Deploy from the Coolify UI. Coolify/Traefik handles TLS; nginx routes internally on port 80.

On first deploy Keycloak will import the realm automatically. The `migrations` service runs database migrations before the API starts and exits cleanly (Coolify will not restart it).

---

## 6. After deploying

- Configure SMTP manually in the Keycloak admin console (`<YOUR_INSTANCE_DOMAIN>/oauth`, Realm settings > Email). It is deliberately left out of the automated realm import, so password reset and email verification will not work until you set it up.
- Confirm the automatic backups are running — see [Confirming backups work on a new instance](./backup_and_restore_instructions.md#confirming-backups-work-on-a-new-instance).

---

## Appendix: running commands in Docker

Several steps in this document and in the backup instructions require running commands in one of the docker containers being run by the service. Coolify appends unique IDs to the container names on each deployment, so you will need to find the container name or ID before you can run a command. The beginning of the container name will be the same as the service name in the docker compose file; you can also double check you have the right container by looking at the "logs" menu in Coolify.

If you want to modify the information shown by this command, see the [docker ps documentation](https://docs.docker.com/reference/cli/docker/container/ls/):

```bash
# list running containers
docker ps --format "table {{.ID}}\t{{.CreatedAt}}\t{{.Names}}"
```

Alternatively, you can connect to a shell inside any running container by using the "terminal" menu in the Coolify UI. In this case, just run the portion of the command that comes after `... exec <container_name>`.
