#!/bin/bash
# Runs as root. Prepares the mounted volume, then hands the container to the
# `frappe` user for everything else.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITES="${BENCH}/sites"
LOGS="${BENCH}/logs"

mkdir -p "${SITES}" "${LOGS}"

# A freshly mounted Railway volume is an empty root-owned directory. Chown it
# once and leave a marker, so later boots do not walk a large sites tree.
if [ ! -e "${SITES}/.railway-owned" ]; then
  echo "boot: taking ownership of ${SITES}"
  chown -R frappe:frappe "${SITES}" "${LOGS}"
  su -s /bin/sh -c "touch '${SITES}/.railway-owned'" frappe
else
  chown frappe:frappe "${SITES}" "${LOGS}"
fi

# The stock image entrypoint links the baked assets into the sites directory.
# We replace that entrypoint, so redo it here — the volume hides the image's
# own copy every boot.
rm -rf "${SITES}/assets"
ln -s "${BENCH}/assets" "${SITES}/assets"
chown -h frappe:frappe "${SITES}/assets"

# Positive proof of the privilege drop, in its own invocation: expanding $(id -u)
# inside a nested shell string would still print root's uid.
setpriv --reuid=frappe --regid=frappe --init-groups id

exec setpriv --reuid=frappe --regid=frappe --init-groups \
  env HOME=/home/frappe PATH="${PATH}" \
  /usr/local/bin/railway-bootstrap.sh "$@"
