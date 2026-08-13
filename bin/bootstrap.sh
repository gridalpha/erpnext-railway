#!/bin/bash
# Runs as `frappe`. Renders configuration, creates the site on first boot,
# migrates it after an image upgrade, then hands over to supervisord (ROLE=app)
# or to the realtime server (ROLE=websocket).
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITES="${BENCH}/sites"
cd "${BENCH}"

ROLE="${ROLE:-app}"
SITE_NAME="${SITE_NAME:-erpnext.local}"
SITE_DB_NAME="${SITE_DB_NAME:-erpnext}"
DB_HOST="${DB_HOST:-mariadb.railway.internal}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
SOCKETIO_HOST="${SOCKETIO_HOST:-websocket.railway.internal}"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"
REDIS_CACHE_URL="${REDIS_CACHE_URL:-redis://redis-cache.railway.internal:6379}"
REDIS_QUEUE_URL="${REDIS_QUEUE_URL:-redis://redis-queue.railway.internal:6379}"

log() { echo "[railway] $*"; }

# --- derived credentials -----------------------------------------------------
# Neither of these can be expressed as a Railway variable: the encryption key
# must be a Fernet key (url-safe base64 of exactly 32 bytes) and both have to
# stay byte-identical across every container and every redeploy. They are
# therefore derived from one operator secret, deterministically, at boot.
derive() {
  FRAPPE_SECRET="${FRAPPE_SECRET}" DERIVE_LABEL="$1" DERIVE_KIND="$2" python3 - <<'PY'
import base64, hashlib, hmac, os, sys
secret = os.environ["FRAPPE_SECRET"].encode()
digest = hmac.new(secret, os.environ["DERIVE_LABEL"].encode(), hashlib.sha256).digest()
if os.environ["DERIVE_KIND"] == "fernet":
    sys.stdout.write(base64.urlsafe_b64encode(digest).decode())
else:
    sys.stdout.write(digest.hex()[:32])
PY
}

if [ "${ROLE}" = "app" ]; then
  : "${FRAPPE_SECRET:?FRAPPE_SECRET is required}"
  ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(derive frappe-encryption-key fernet)}"
  SITE_DB_PASSWORD="${SITE_DB_PASSWORD:-$(derive site-db-password hex)}"
fi

# --- realtime role -----------------------------------------------------------
# socketio.js reads redis and its port straight from the environment and
# authenticates by calling back to the public origin over HTTPS, so this role
# needs neither the sites volume nor a config file.
if [ "${ROLE}" = "websocket" ]; then
  export FRAPPE_REDIS_CACHE="${REDIS_CACHE_URL}"
  export FRAPPE_REDIS_QUEUE="${REDIS_QUEUE_URL}"
  export FRAPPE_SOCKETIO_PORT="${SOCKETIO_PORT}"
  log "starting realtime server on :${SOCKETIO_PORT}"
  exec node "${BENCH}/apps/frappe/socketio.js"
fi

# --- wait for the data stores ------------------------------------------------
# Railway has no service ordering, so the first boot of a fresh project races
# MariaDB's own initialisation.
log "waiting for mariadb at ${DB_HOST}:${DB_PORT}"
for _ in $(seq 1 120); do
  if MYSQL_PWD="${DB_ROOT_PASSWORD:-}" mariadb -h "${DB_HOST}" -P "${DB_PORT}" \
      -u "${DB_ROOT_USER}" -e 'SELECT 1' >/dev/null 2>&1; then
    log "mariadb is up"
    break
  fi
  sleep 5
done

wait_redis() {
  REDIS_TARGET="$1" python3 - <<'PY'
import os, socket, sys, time
from urllib.parse import urlparse
u = urlparse(os.environ["REDIS_TARGET"])
host, port = u.hostname, u.port or 6379
for _ in range(60):
    try:
        socket.create_connection((host, port), timeout=5).close()
        print(f"[railway] redis {host}:{port} is up")
        sys.exit(0)
    except OSError:
        time.sleep(5)
print(f"[railway] redis {host}:{port} did not answer; continuing", file=sys.stderr)
PY
}
wait_redis "${REDIS_CACHE_URL}"
wait_redis "${REDIS_QUEUE_URL}"

# --- bench configuration -----------------------------------------------------
# The volume hides the apps.txt and common_site_config.json baked into the
# image, so both are rewritten on every boot. Writing the JSON directly rather
# than through `bench set-config` keeps first boot several seconds shorter and
# makes the whole file self-healing.
ls -1 apps > "${SITES}/apps.txt"

SITE_NAME="${SITE_NAME}" DB_HOST="${DB_HOST}" DB_PORT="${DB_PORT}" \
REDIS_CACHE_URL="${REDIS_CACHE_URL}" REDIS_QUEUE_URL="${REDIS_QUEUE_URL}" \
SOCKETIO_PORT="${SOCKETIO_PORT}" ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
SITES="${SITES}" PUBLIC_DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}" \
python3 - <<'PY'
import json, os, pathlib

path = pathlib.Path(os.environ["SITES"]) / "common_site_config.json"
conf = {}
if path.exists():
    try:
        conf = json.loads(path.read_text())
    except ValueError:
        conf = {}

conf.update({
    "db_host": os.environ["DB_HOST"],
    "db_port": int(os.environ["DB_PORT"]),
    "redis_cache": os.environ["REDIS_CACHE_URL"],
    "redis_queue": os.environ["REDIS_QUEUE_URL"],
    "redis_socketio": os.environ["REDIS_QUEUE_URL"],
    "socketio_port": int(os.environ["SOCKETIO_PORT"]),
    "encryption_key": os.environ["ENCRYPTION_KEY"],
    "chromium_path": "/usr/bin/chromium-headless-shell",
    "developer_mode": 0,
    "maintenance_mode": 0,
    "serve_default_site": 1,
})

# host_name is what frappe puts in emails, password-reset links and print
# formats. Re-resolved every boot so the deployment self-heals if the domain
# is regenerated or a custom one is attached.
domain = os.environ.get("PUBLIC_DOMAIN") or ""
if domain:
    conf["host_name"] = f"https://{domain}"

path.write_text(json.dumps(conf, indent=1, sort_keys=True))
print("[railway] wrote", path)
PY

APP_VERSIONS="$(grep -h '^__version__' apps/*/*/__init__.py 2>/dev/null | tr -d ' ' || true)"
VERSION_MARKER="${SITES}/.railway-app-versions"

# --- first boot: create the site --------------------------------------------
# The database, not the volume, decides whether a site exists. A file on the
# volume cannot be trusted for this: `bench new-site` writes site_config.json
# before it touches the database, so an interrupted first boot leaves a site
# directory pointing at a half-built schema that every later boot then tries to
# migrate. The patch log is the honest signal — a finished install has well over
# a thousand rows, an abandoned one has no such table at all.
SITE_READY="${SITES}/${SITE_NAME}/.railway-site-ready"

db_query() {
  MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb -h "${DB_HOST}" -P "${DB_PORT}" \
    -u "${DB_ROOT_USER}" -N -B -e "$1"
}

: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
# Prove the connection separately, so that a database that is merely unreachable
# can never be mistaken for a database with no site in it.
if ! db_query 'SELECT 1' >/dev/null 2>&1; then
  echo "[railway] cannot reach ${DB_HOST}:${DB_PORT} as ${DB_ROOT_USER}; refusing to continue" >&2
  exit 1
fi
PATCH_ROWS="$(db_query "SELECT COUNT(*) FROM \`${SITE_DB_NAME}\`.\`tabPatch Log\`" 2>/dev/null || echo 0)"
PATCH_ROWS="${PATCH_ROWS:-0}"

if [ "${PATCH_ROWS}" -eq 0 ]; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required to create the site}"
  log "no installed site in ${SITE_DB_NAME}; creating ${SITE_NAME} (several minutes)"
  # --force drops whatever an interrupted boot left behind. Reached only when
  # the database holds no finished install, so there is nothing to lose.
  rm -rf "${SITES:?}/${SITE_NAME:?}"
  bench new-site "${SITE_NAME}" \
    --force \
    --db-name "${SITE_DB_NAME}" \
    --db-password "${SITE_DB_PASSWORD}" \
    --db-root-username "${DB_ROOT_USER}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-user-host-login-scope='%' \
    --install-app erpnext \
    --set-default \
    --verbose
  # new-site derives the scheduler state from a site that did not exist yet and
  # lands on "disabled"; without this, nothing scheduled ever runs.
  bench --site "${SITE_NAME}" enable-scheduler
  printf '%s' "${APP_VERSIONS}" > "${VERSION_MARKER}"
  touch "${SITE_READY}"
  log "site ${SITE_NAME} created"
elif [ ! -f "${SITE_READY}" ]; then
  # The database holds a site but this volume does not know about it — a
  # replaced volume, or a restore. Everything site_config.json needs is derived
  # from FRAPPE_SECRET, so rebuild it rather than dropping a live schema.
  log "database ${SITE_DB_NAME} holds a completed install (${PATCH_ROWS} patches); reattaching"
  mkdir -p "${SITES}/${SITE_NAME}/public/files" \
    "${SITES}/${SITE_NAME}/private/files" \
    "${SITES}/${SITE_NAME}/private/backups" \
    "${SITES}/${SITE_NAME}/locks" \
    "${SITES}/${SITE_NAME}/logs"
  if [ ! -f "${SITES}/${SITE_NAME}/site_config.json" ]; then
    SITE_CONFIG_PATH="${SITES}/${SITE_NAME}/site_config.json" \
    SITE_DB_NAME="${SITE_DB_NAME}" SITE_DB_PASSWORD="${SITE_DB_PASSWORD}" \
    python3 - <<'PY'
import json, os
json.dump(
    {
        "db_name": os.environ["SITE_DB_NAME"],
        "db_password": os.environ["SITE_DB_PASSWORD"],
        "db_type": "mariadb",
        "db_user": os.environ["SITE_DB_NAME"],
    },
    open(os.environ["SITE_CONFIG_PATH"], "w"),
    indent=1,
    sort_keys=True,
)
PY
  fi
  # Force the migrate below: the reattached schema may predate this image. The
  # ready marker is written only once that migrate has succeeded.
  rm -f "${VERSION_MARKER}"
else
  log "site ${SITE_NAME} already exists (${PATCH_ROWS} patches applied)"
fi

echo "${SITE_NAME}" > "${SITES}/currentsite.txt"

# --- migrate after an image upgrade -----------------------------------------
# The service tracks the v16 line, so a redeploy can land a newer frappe/erpnext
# than the schema on disk. Guarded by the app versions so a plain restart does
# not pay for a migration it does not need.
if [ "${APP_VERSIONS}" != "$(cat "${VERSION_MARKER}" 2>/dev/null || true)" ]; then
  log "app versions changed, migrating"
  bench --site "${SITE_NAME}" migrate
  printf '%s' "${APP_VERSIONS}" > "${VERSION_MARKER}"
  touch "${SITE_READY}"
  log "migration complete"
fi

# --- one-time hardening ------------------------------------------------------
if [ "${DISABLE_SIGNUP:-1}" = "1" ] && [ ! -f "${SITES}/.railway-signup-closed" ]; then
  log "disabling public sign-up"
  bench --site "${SITE_NAME}" execute frappe.db.set_single_value \
    --kwargs "{'doctype': 'Website Settings', 'fieldname': 'disable_signup', 'value': 1}"
  touch "${SITES}/.railway-signup-closed"
fi

if [ "${RESET_ADMIN_PASSWORD:-0}" = "1" ]; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required to reset the administrator password}"
  log "resetting the Administrator password from ADMIN_PASSWORD"
  bench --site "${SITE_NAME}" set-admin-password "${ADMIN_PASSWORD}"
fi

# --- nginx -------------------------------------------------------------------
# Railway's private DNS is IPv6 and nginx needs it bracketed; without a resolver
# the variable upstream below cannot be resolved at request time, and without a
# variable upstream nginx would pin the realtime service's address at startup
# and 502 after every redeploy of it.
NGINX_RESOLVER="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
case "${NGINX_RESOLVER}" in
  "") NGINX_RESOLVER="[fd12::10]" ;;
  *:*) NGINX_RESOLVER="[${NGINX_RESOLVER}]" ;;
esac

export NGINX_PORT="${PORT:-8080}"
export SITE_NAME NGINX_RESOLVER
export SOCKETIO_UPSTREAM="${SOCKETIO_HOST}:${SOCKETIO_PORT}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-120}"
export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"

envsubst '${NGINX_PORT} ${SITE_NAME} ${NGINX_RESOLVER} ${SOCKETIO_UPSTREAM} ${PROXY_READ_TIMEOUT} ${CLIENT_MAX_BODY_SIZE}' \
  < /templates/nginx/frappe.conf.template > /etc/nginx/conf.d/frappe.conf
nginx -t

log "starting supervisord (nginx, gunicorn, queue-short, queue-long, scheduler)"
exec /usr/bin/supervisord -c /etc/supervisor/erpnext.conf -n
