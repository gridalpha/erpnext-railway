# ERPNext on Railway

A thin layer over the official [`frappe/erpnext`](https://hub.docker.com/r/frappe/erpnext)
production image that makes the Frappe stack deployable on Railway.

The image builds two roles from the same Dockerfile, selected by `ROLE`:

| `ROLE` | Runs | Needs a volume | Public |
|---|---|---|---|
| `app` (default) | nginx, gunicorn, `queue-short`, `queue-long`, `scheduler` under supervisord | yes, at `/home/frappe/frappe-bench/sites` | yes |
| `websocket` | `socketio.js`, the Frappe realtime server | no | no |

## Why the roles are packed the way they are

Upstream's `compose.yaml` runs the web, worker and scheduler containers against a
single shared `sites` volume: background jobs read and write the same uploaded
files the web tier serves. Railway volumes are strictly one-per-service and
cannot be shared, so those three roles share a container instead. The realtime
server needs none of those files — it reads redis from the environment and
authenticates by calling back to the public origin — so it stays a separate
service, as upstream deploys it.

## Companion services

* **MariaDB** — the `mariadb:11.8` image with `utf8mb4` and
  `--skip-character-set-client-handshake`, on its own volume. Frappe needs the
  root login once, at site creation.
* **Redis (cache)** and **Redis (queue)** — two instances, matching upstream.
  Keeping them apart means clearing the cache can never drop queued jobs.

## Variables

Required:

| Variable | Meaning |
|---|---|
| `ADMIN_PASSWORD` | Password for the `Administrator` user. Read once, when the site is created. |
| `FRAPPE_SECRET` | One high-entropy secret. The site's database password and the Fernet encryption key are derived from it at boot — neither can be a Railway variable, and both have to be byte-identical across every container and redeploy. |
| `DB_ROOT_PASSWORD` | MariaDB root password, used to create the site's database and user. |

Everything else has a working default:

| Variable | Default | Notes |
|---|---|---|
| `ROLE` | `app` | `websocket` for the realtime service. |
| `SITE_NAME` | `erpnext.local` | Internal site identity. Not a hostname — the deployment answers on any host. |
| `SITE_DB_NAME` | `erpnext` | |
| `DB_HOST` / `DB_PORT` | `mariadb.railway.internal` / `3306` | |
| `DB_ROOT_USER` | `root` | |
| `REDIS_CACHE_URL` / `REDIS_QUEUE_URL` | `redis://redis-cache.railway.internal:6379` / `…redis-queue…` | |
| `SOCKETIO_HOST` / `SOCKETIO_PORT` | `websocket.railway.internal` / `9000` | |
| `PORT` | `8080` | nginx listen port. |
| `GUNICORN_WORKERS` / `GUNICORN_THREADS` / `GUNICORN_TIMEOUT` | `2` / `4` / `120` | |
| `CLIENT_MAX_BODY_SIZE` / `PROXY_READ_TIMEOUT` | `50m` / `120` | |
| `DISABLE_SIGNUP` | `1` | Closes public sign-up once, on first boot. |
| `RESET_ADMIN_PASSWORD` | `0` | Set to `1` for one deploy to re-apply `ADMIN_PASSWORD`, then set it back. |
| `ENCRYPTION_KEY` / `SITE_DB_PASSWORD` | derived from `FRAPPE_SECRET` | Override only when migrating an existing site in. |

## First boot

Creating the site installs the whole ERPNext schema and takes several minutes,
during which the container is not yet listening. Health checks should allow for
it; `/railway/health` is the path once it is up.

## Custom domains

The site is addressed by a fixed internal name, not by `Host`, so attaching a
custom domain in Railway needs no changes here. `host_name` — what ERPNext puts
in emails and password-reset links — is re-resolved from `RAILWAY_PUBLIC_DOMAIN`
on every boot; set `host_name` through `bench set-config` if you want a custom
domain to win instead.

## Upgrades

The image tracks the `v16` line. When a redeploy lands newer frappe/erpnext apps
than the schema on disk, the entrypoint runs `bench migrate` before starting the
stack, and records the versions so a plain restart does not repeat it.
