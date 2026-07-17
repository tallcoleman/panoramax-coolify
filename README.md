# panoramax-coolify

Deployment files for running [Panoramax](https://panoramax.fr) on [Coolify](https://coolify.io), based on the [`docker/full-keycloak-auth`](https://gitlab.com/panoramax/server/api/-/tree/develop/docker/full-keycloak-auth) example from the upstream [panoramax/server/api](https://gitlab.com/panoramax/server/api) repository.

The deployment runs:
- **Panoramax API** (pre-built image from [Docker Hub](https://hub.docker.com/r/panoramax/api))
- **Keycloak 26** identity provider, pre-configured with the Panoramax realm
- **PostGIS 16** database (shared by both the API and Keycloak)
- **nginx** reverse proxy routing `/api`, `/oauth`, and `/` to the correct services
- **Panoramax website** frontend
- **Background workers** for image processing (blur + derivate generation)

See `CHANGELOG.md` for a summary of changes made relative to the upstream example.

---

## Prerequisites

- A domain with TLS termination handled upstream (Coolify/Traefik does this)
- An S3-compatible object store for pictures (e.g. OVH Cloud Object Storage)
- An SMTP server for Keycloak email verification

---

## Deployment

1. Copy `docker/full-keycloak-auth/env.example` to `docker/full-keycloak-auth/.env` and fill in all values.
2. Point Coolify at this repository, set the compose file path to `docker/full-keycloak-auth/docker-compose.yml`.
3. Deploy. Coolify/Traefik handles TLS; nginx routes internally on port 80.

On first deploy Keycloak will import the realm automatically. The `migrations` service runs database migrations before the API starts and exits cleanly (Coolify will not restart it).

---

## Syncing with upstream

The upstream deployment files live at `docker/full-keycloak-auth/` in the [panoramax/server/api](https://gitlab.com/panoramax/server/api) repo. Because this repo uses the same path, git can diff them directly.

**One-time setup:**
```bash
git remote add upstream https://gitlab.com/panoramax/server/api.git
git fetch upstream
```

**See what changed upstream in the files this repo tracks:**
```bash
git diff HEAD upstream/develop -- docker/full-keycloak-auth/
```

**Inspect a specific file:**
```bash
git show upstream/develop:docker/full-keycloak-auth/nginx.conf
```

**Pull in a specific updated file:**
```bash
git checkout upstream/develop -- docker/full-keycloak-auth/nginx.conf
```

**Note:** `docker-compose.yml` will always show one intentional divergence in the diff — the top-level `x-base-geovisio` anchor uses `image: panoramax/api:${GEOVISIO_IMAGE_TAG:-latest}` here instead of a `build:` block, since this repo does not include the API source code. Any other diffs indicate upstream changes worth reviewing.
