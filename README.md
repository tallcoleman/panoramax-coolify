# panoramax-coolify

Deployment files for running [Panoramax](https://panoramax.fr) on [Coolify](https://coolify.io), based on the [`docker/full-keycloak-auth`](https://gitlab.com/panoramax/server/api/-/tree/develop/docker/full-keycloak-auth) example from the upstream [panoramax/server/api](https://gitlab.com/panoramax/server/api) repository.

The deployment runs:
- **Panoramax API** (pre-built image from [Docker Hub](https://hub.docker.com/r/panoramax/api))
- **Keycloak 26** identity provider, pre-configured with the Panoramax realm
- **PostGIS 16** database (shared by both the API and Keycloak)
- **nginx** reverse proxy routing `/api`, `/oauth`, and `/` to the correct services
- **Panoramax website** frontend
- **Background workers** for image processing (blur + derivate generation)
- **Backup sidecar** shipping encrypted database/secrets snapshots and picture copies to S3

See `CHANGELOG.md` for a summary of changes made relative to the upstream example.

---

## Documentation

| Document | What it covers |
| --- | --- |
| [`deployment_instructions.md`](./deployment_instructions.md) | Deploying a new instance to Coolify, including S3 bucket setup. |
| [`configuration_options.md`](./configuration_options.md) | Every environment variable — required vs optional, and what each does. |
| [`backup_and_restore_instructions.md`](./backup_and_restore_instructions.md) | Running one-off backups, verifying automatic backups, and the full restore runbook. |
| [`docker/full-keycloak-auth/backup/backup_architecture.md`](./docker/full-keycloak-auth/backup/backup_architecture.md) | How the backup code works — for reading and modifying it, not for operating it. |

---

## Syncing with upstream

The upstream deployment files live at `docker/full-keycloak-auth/` in the [panoramax/server/api](https://gitlab.com/panoramax/server/api) repo on the `main` branch. Because this repo uses the same path, git can diff them directly.

**One-time setup:**
```bash
git remote add upstream https://gitlab.com/panoramax/server/api.git
git fetch upstream
```

**See what changed upstream in the files this repo tracks:**
```bash
git diff HEAD upstream/main -- docker/full-keycloak-auth/
```

**Inspect a specific file:**
```bash
git show upstream/main:docker/full-keycloak-auth/nginx.conf
```

**Pull in a specific updated file:**
```bash
git checkout upstream/main -- docker/full-keycloak-auth/nginx.conf
```

**Note:** `docker-compose.yml` will always show one intentional divergence in the diff — the top-level `x-base-geovisio` anchor uses `image: panoramax/api:${GEOVISIO_IMAGE_TAG:-latest}` here instead of a `build:` block, since this repo does not include the API source code. Any other diffs indicate upstream changes worth reviewing.
