# shellcheck shell=bash
# lib/panel/compose/colocated.sh — docker-compose.yml for co-located
# topologies: Panel and Node run on the same host (MODE=1, MODE=F).
# Extracted 2026-08-31 from lib/panel/compose.sh — see common.sh's header
# comment for how the shared service blocks were verified byte-identical
# before being hoisted out.

# panel_compose_remnanode_block — the Node/Xray container. Only
# co-located topologies run this in the same compose file (MODE=2's
# Node lives on a separate remote host, provisioned by
# lib/panel/node/compose.sh, not this file) — confirmed identical
# (0-diff) across all three original co-located heredocs (MODE=1,
# MODE=F, WEB_SERVER=2/MODE=1), so this lives here rather than in
# common.sh, which is reserved for blocks shared by ALL five original
# variants including the two remote/MODE=2 ones that never had this
# block at all.
panel_compose_remnanode_block() {
    cat << 'BLOCK_EOF'
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    cap_add:
      - NET_ADMIN
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="PUBLIC KEY FROM REMNAWAVE-PANEL"
    volumes: [/dev/shm:/dev/shm:rw]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
BLOCK_EOF
}

# panel_compose_nginx_frontend_colocated — MODE=1 differs from MODE=F/J in
# ONE line here: which file nginx.conf gets mounted as (conf.d's
# default.conf, an nginx:1.28-image-provided top-level config already
# `include`s conf.d/*.conf — vs the top-level nginx.conf itself, which
# Variant F's and Variant J's own generators (lib/panel/nginx/variant_f.sh,
# lib/panel/nginx/variant_j.sh) must own completely, because both need a
# top-level `stream {}` block that conf.d/*.conf inclusion cannot provide).
# All three otherwise mount /dev/shm and /var/www/html (MODE=1's
# REALITY-fallback selfsteal socket, MODE=F's and MODE=J's own
# nginx-stream selfsteal sockets all live at /dev/shm/nginx.sock) and
# override `command:` to clear a stale socket file before nginx starts.
# MODE=1 vs MODE=F confirmed identical apart from that one mount-target
# line by diffing the original MODE=1/MODE=F heredoc ranges directly;
# MODE=J never had an original heredoc of its own to diff against (it
# fell through to the wrong branch entirely — see
# panel_generate_compose_colocated()'s comment), so it is added here on
# the same "needs its own full nginx.conf" reasoning as MODE=F, not by
# copying a byte-identical baseline.
panel_compose_nginx_frontend_colocated() {
    local MODE="$1"
    local CERT_VOLUMES="$2"
    local MOUNT_TARGET="conf.d/default.conf"
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        MOUNT_TARGET="nginx.conf"
    fi

    cat << EOFYML
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/${MOUNT_TARGET}:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
${CERT_VOLUMES}    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
EOFYML
}

# panel_compose_caddy_frontend_colocated — WEB_SERVER=2/MODE=1's Caddy
# variant. Mounts /dev/shm (selfsteal socket) and adds the
# unix-socket-existence healthcheck that the remote/panel-only Caddy
# variant (remote.sh) does not have, because only a co-located topology
# actually has a Node writing to that socket for Caddy to wait on.
panel_compose_caddy_frontend_colocated() {
    local PANEL_DOMAIN="$1"
    local SUB_DOMAIN="$2"
    local SELFSTEAL_DOMAIN="$3"

    cat << EOFYML
  remnawave-caddy:
    image: caddy:2.11.2
    container_name: remnawave-caddy
    hostname: remnawave-caddy
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - /var/www/html:/var/www/html:ro
      - /dev/shm:/dev/shm:rw
      - caddy_data:/data
    command: sh -c 'rm -f /dev/shm/nginx.sock && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    environment:
      - PANEL_DOMAIN=${PANEL_DOMAIN}
      - SUB_DOMAIN=${SUB_DOMAIN}
      - SELF_STEAL_DOMAIN=${SELFSTEAL_DOMAIN}
      - BACKEND_URL=127.0.0.1:3000
      - SUB_BACKEND_URL=127.0.0.1:3010
    healthcheck:
      test: ["CMD", "test", "-S", "/dev/shm/nginx.sock"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
EOFYML
}

# panel_generate_compose_colocated — MODE=1 (nginx or caddy), MODE=F
# (nginx only), and MODE=J (nginx only). WEB_SERVER=2/MODE=F and
# WEB_SERVER=2/MODE=J were never combinations the original file supported
# (MODE=F didn't exist there at all yet for J's case, and fell through
# incorrectly for F's — see the guard below), so this preserves that same
# restriction explicitly rather than silently inventing a Caddy+Variant-F
# or Caddy+Variant-J combination that has never been decided. Orchestrates
# the shared blocks (common.sh) plus this file's co-located-specific ones,
# in the same order and with the same blank-line separation as the
# original single heredocs (confirmed by the regression test comparing
# full generated output, not just individual blocks).
panel_generate_compose_colocated() {
    local WEB_SERVER="$1"
    local MODE="$2"
    local CERT_VOLUMES="$3"
    local PANEL_DOMAIN="$4"
    local SUB_DOMAIN="$5"
    local SELFSTEAL_DOMAIN="$6"

    # GUARD (2026-08-31, found during the compose split, not previously
    # documented anywhere): WEB_SERVER=2 (Caddy) + MODE=F had no branch of
    # its own in the original file — like MODE=J, it silently fell
    # through the elif chain into the final `else`, which is
    # WEB_SERVER=2/MODE=2's plain Caddy, PANEL-ONLY heredoc. That combo is
    # wrong on two independent axes at once: (1) topology — it drops
    # remnanode entirely, even though MODE=F/J are co-located and need a
    # Node; (2) protocol — Variant F's and Variant J's actual routing
    # (nginx `stream{}` SNI-passthrough to REALITY/XHTTP,
    # lib/panel/nginx/variant_f.sh / variant_j.sh) has no Caddy equivalent
    # anywhere in this codebase; a Caddy config cannot provide it. There
    # is no confirmed, intended behavior for either combination to fall
    # back to, so both fail loudly instead of reproducing the old silent
    # mis-route or inventing a new unverified one. (MODE=J's own guard is
    # new alongside MODE=J's own support in this function — MODE=J did
    # not exist in the original file in any form, correct or not.)
    if [ "$WEB_SERVER" = "2" ] && { [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; }; then
        err "Variant $MODE требует nginx (WEB_SERVER=1) — Caddy не поддерживает nginx stream{}-маршрутизацию, необходимую для Variant $MODE"
    fi

    {
        echo "services:"
        panel_compose_db_block
        echo ""
        panel_compose_app_block
        echo ""
        panel_compose_redis_block
        echo ""
        if [ "$WEB_SERVER" = "1" ]; then
            panel_compose_nginx_frontend_colocated "$MODE" "$CERT_VOLUMES"
        else
            panel_compose_caddy_frontend_colocated "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"
        fi
        echo ""
        panel_compose_subpage_block
        echo ""
        panel_compose_remnanode_block
        echo ""
        panel_compose_footer "1" "$([ "$WEB_SERVER" = "2" ] && echo 1 || echo 0)"
    } > /opt/remnawave/docker-compose.yml
}
