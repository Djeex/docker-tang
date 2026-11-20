<h1 align="center">Docker Tang</h1>

**Docker Tang** - A maintained [tang](https://github.com/latchset/tang) server image, drop-in replacement for [`padhihomelab/tang`](https://github.com/padhi-homelab/docker_tang): same port, same `/db` layout, same variables, same key ownership, so existing clevis bindings keep working. Rebuilt every week on a pinned, upgraded Alpine base and scanned with Trivy.

> [!NOTE]
>_Github repo is a mirror of https://git.djeex.fr/Djeex/docker-tang. You'll find full package, history and release note there._

## 📑 Table of Contents

- [🚀 Features](#-features)
- [🔧 How It Works](#-how-it-works)
- [🛠️ Configuration](#️-configuration)
  - [Environment Variables](#environment-variables)
  - [Volumes and Ports](#volumes-and-ports)
- [🚢 Quick Start](#-quick-start)
  - [Using Docker Compose (Recommended)](#using-docker-compose-recommended)
  - [Using Docker Run](#using-docker-run)
- [🔁 Migrating from padhihomelab/tang](#-migrating-from-padhihomelabtang)
- [🏷️ Image Tags](#️-image-tags)
- [🔒 Maintenance and Security](#-maintenance-and-security)
- [🧪 Tests](#-tests)

## 🚀 Features

- **Drop-in replacement** for `padhihomelab/tang`: change the `image:` line, nothing else
- **Always up to date**: weekly rebuild with `apk upgrade`, base image and tang/jose versions tracked by Renovate
- **Scanned**: the build fails on any fixable HIGH or CRITICAL CVE (Trivy)
- **Non-root**: starts as root only to set up the user and `/db`, then runs tang as an unprivileged user
- **Compatibility tested**: every CI run starts `padhihomelab/tang` and this image on the same key directory and checks thumbprints, key files and a real `clevis encrypt`/`clevis decrypt` round trip

## 🔧 How It Works

1. **Init**: [tini](https://github.com/krallin/tini) runs as PID 1 and starts the entrypoint
2. **User setup**: the entrypoint creates the `DOCKER_USER`/`DOCKER_GROUP` user and group with `DOCKER_UID`/`DOCKER_GID` (`12345:23456` by default)
3. **Configuration**: the executable `*.sh` scripts in `ENTRYPOINT_D` run, including the built-in one that gives `/db` to that user (`chown -R`)
4. **Privilege drop**: `su-exec` starts `start-servers` as the unprivileged user
5. **Serving**: `socat` listens on port `8080` and runs one `tangd /db` per connection (inetd-style), exactly like `padhihomelab/tang`
6. **Keys**: on the first `/adv` request with an empty `/db`, tangd generates one signing (ES512) and one exchange (ECMR) key, saved as `<thumbprint>.jwk` with mode `0440`. Existing keys are never regenerated
7. **Healthcheck**: `check-servers` requests `/adv` on each enabled listener

## 🛠️ Configuration

### Environment Variables

All variables are the ones `padhihomelab/tang` (and its `padhihomelab/alpine-base` entrypoint) accepts, with the same defaults.

| Variable | Default | Description | Example |
|----------|---------|-------------|---------|
| `DOCKER_UID` | `12345` | User ID tang runs as and owner of `/db` | `1000` |
| `DOCKER_GID` | `23456` | Group ID tang runs as and group of `/db` | `1000` |
| `DOCKER_USER` | `user` | Name of the unprivileged user | `tang` |
| `DOCKER_GROUP` | `user` | Name of the unprivileged group | `tang` |
| `ENABLE_IPv4` | `1` | Listen on IPv4 (`1` to enable) | `0`, `1` |
| `ENABLE_IPv6` | `0` | Listen on IPv6 (`1` to enable) | `0`, `1` |
| `ENTRYPOINT_D` | `/etc/docker-entrypoint.d` | Directory of configuration scripts run at startup | `/config.d` |
| `ENTRYPOINT_RUN_AS_ROOT` | - | If non-empty, keeps root and skips the `/db` chown (not recommended) | `1` |
| `ENTRYPOINT_SKIP_CONFIG` | - | If non-empty, skips the configuration scripts (including the `/db` chown) | `1` |
| `ENTRYPOINT_LOG_THRESHOLD` | `1` | Minimum entrypoint log level: `1` debug, `2` info, `3` warning, `4` error, `5` silent | `2` |

If `DOCKER_UID` or `DOCKER_GID` already belongs to a user or group of the image (e.g. GID `100` = `users`), that one is reused.

### Volumes and Ports

| Path / Port | Description |
|-------------|-------------|
| `/db` | tang key directory (`*.jwk`). Bind mount it to keep your keys |
| `8080` | tang HTTP port (`/adv`, `/rec`) |

## 🚢 Quick Start

### Using Docker Compose (Recommended)

1. Create a `compose.yaml` file:
```yaml
services:
  tang:
    restart: unless-stopped
    container_name: tang
    volumes:
      - /docker/tang/db:/db
    ports:
      - 1234:8080
    stdin_open: true
    tty: true
    image: git.djeex.fr/djeex/docker-tang
```

2. Start the service:
```bash
docker compose up -d
```

3. Check it answers:
```bash
curl -sf http://localhost:1234/adv
```

### Using Docker Run

```bash
docker run -d \
  --name tang \
  --restart unless-stopped \
  -v /docker/tang/db:/db \
  -p 1234:8080 \
  git.djeex.fr/djeex/docker-tang
```

The image is also published on `ghcr.io/djeex/docker-tang`.

## 🔁 Migrating from padhihomelab/tang

Only one line changes in your compose file:

```diff
-    image: padhihomelab/tang
+    image: git.djeex.fr/djeex/docker-tang
```

Keep the same volume, ports and variables. The key files are read as they are: same names, same `0440` mode, same `12345:23456` owner (or your own `DOCKER_UID`/`DOCKER_GID`), no `chown` needed.

**Verification procedure** (keep the LUKS passphrase at hand for step 4):

1. Write down the current thumbprints, from a machine with `curl` and `jose` (installed with clevis):
   ```bash
   curl -sf https://tang.example.com/adv | jose fmt -j- -g payload -u- | jose b64 dec -i- | jose jwk thp -i- | sort > before.txt
   ```
   They also match the file names in the key directory (`ls /docker/tang/db`).
2. Change the `image:` line and redeploy:
   ```bash
   docker compose pull && docker compose up -d
   ```
3. Check the thumbprints are identical and the container is healthy:
   ```bash
   curl -sf https://tang.example.com/adv | jose fmt -j- -g payload -u- | jose b64 dec -i- | jose jwk thp -i- | sort | diff before.txt - && echo "OK: same keys"
   docker inspect -f '{{.State.Health.Status}}' tang
   ls -ln /docker/tang/db   # same files, no new key
   ```
4. Test the clevis unlock on a client, e.g. without rebooting:
   ```bash
   clevis luks list -d /dev/sdX                     # shows the tang binding
   clevis luks unlock -d /dev/sdX -n test-unlock    # opens it through tang
   cryptsetup close test-unlock
   ```
   For a root device already open, `clevis luks pass -d /dev/sdX -s <slot>` prints the passphrase recovered through tang without touching the mapping.

Rollback: put the `padhihomelab/tang` line back. Both images use the same key directory.

## 🏷️ Image Tags

| Tag | Updated | Content |
|-----|---------|---------|
| `latest` | every release and every weekly rebuild | current image |
| `X.Y.Z`, `X.Y` | every release | image as released from this repo (`VERSION`) |
| `tangNN` | every release and every weekly rebuild | latest image for tang major `NN` (e.g. `tang16`) |
| `tangNN-YYYYMMDD` | every release and every weekly rebuild | immutable build of that day |

## 🔒 Maintenance and Security

- **Why tang is built from source**: Alpine has no `tang` package (only `jose` 14, older than the one `padhihomelab/tang` uses). tang and jose are built from their upstream release tags (`latchset/tang` v16, `latchset/jose` v15), the same code as `padhihomelab/tang`, in a separate build stage. Only the binaries reach the final image.
- **Base image**: `alpine` pinned by digest; Renovate proposes base digest and tang/jose tag updates as PRs.
- **Weekly rebuild**: every Monday the CI rebuilds without cache, so `apk upgrade` pulls the latest Alpine fixes, runs all tests and the scan, then republishes `latest`, `tangNN` and `tangNN-YYYYMMDD`.
- **Trivy**: the build fails on any fixable HIGH or CRITICAL vulnerability.
- **Minimal image**: tang, jose, socat, tini and su-exec only; busybox `wget` serves the healthcheck. No secret in the image.

## 🧪 Tests

| Suite | What it checks |
|-------|----------------|
| `tests/entrypoint.bats` | user/group creation and reuse, UID/GID validation, `/db` ownership, `ENTRYPOINT_*` behaviours, logs |
| `tests/tang.bats` | lazy key generation, key file names/modes/owner, no regeneration, signed `/adv`, 404 paths, IPv4/IPv6 listeners, healthcheck |
| `tests/compat.sh` | `padhihomelab/tang` then this image on the same volume: same thumbprints, untouched key files, healthy, no error, `clevis encrypt` with the old image and `clevis decrypt` with the new one |

Run them locally:
```bash
docker build --target test -t tang:test .
docker run --rm tang:test bats /app/tests

docker build -t tang:ci .
docker build --target padhi-reference -t tang:padhi-reference .
docker build --target clevis -t tang:clevis .
bash tests/compat.sh
```

## 📄 License

MIT for this repository. The image ships [tang](https://github.com/latchset/tang) (GPL-3.0) and [jose](https://github.com/latchset/jose) (Apache-2.0), built from their unmodified upstream sources.
