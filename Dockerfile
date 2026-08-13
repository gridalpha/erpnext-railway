# ERPNext on Railway.
#
# Thin layer over the official frappe/erpnext production image. Everything this
# adds exists because Railway differs from the upstream docker-compose stack in
# three ways:
#
#   1. Volumes are 1:1 — the `sites` directory that upstream shares between the
#      gunicorn, worker and scheduler containers cannot be shared here, so those
#      roles run side by side under supervisord in this image.
#   2. A mounted volume hides whatever the image baked at that path, and Railway
#      replaces the image ENTRYPOINT with the start command, so the asset symlink
#      and the sites bootstrap have to be redone by our own entrypoint.
#   3. The edge routes by domain and port only, so nginx (in this image) is what
#      splits /socket.io off to the realtime service.
ARG ERPNEXT_VERSION=v16
FROM frappe/erpnext:${ERPNEXT_VERSION}

USER root

RUN apt-get update \
    && apt-get install --no-install-recommends -y supervisor \
    && rm -rf /var/lib/apt/lists/*

# Replaces the stock template: fixed site name, leftmost X-Forwarded-For, a
# resolver-backed socket.io upstream and a local health endpoint.
COPY --chown=frappe:frappe nginx/frappe.conf.template /templates/nginx/frappe.conf.template

COPY bin/entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY bin/bootstrap.sh /usr/local/bin/railway-bootstrap.sh
COPY bin/fatal-exit.py /usr/local/bin/railway-fatal-exit.py
COPY supervisord.conf /etc/supervisor/erpnext.conf
RUN chmod 755 /usr/local/bin/railway-entrypoint.sh \
    /usr/local/bin/railway-bootstrap.sh \
    /usr/local/bin/railway-fatal-exit.py

WORKDIR /home/frappe/frappe-bench

# Intentionally root: the entrypoint chowns the freshly mounted volume and then
# drops back to `frappe` with setpriv. Keeping the privilege handling here means
# no invisible RAILWAY_RUN_UID on the service.
USER root

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
