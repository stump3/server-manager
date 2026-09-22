# shellcheck shell=bash
# lib/panel/compose/remote.sh — docker-compose.yml for the remote
# topology: Panel only (MODE=2). The Node runs on a separate host,
# provisioned by lib/panel/node/compose.sh, not this file — there is no
# remnanode service anywhere below, which is the one structural
# difference from colocated.sh's output. Extracted 2026-08-31 from
# lib/panel/compose.sh — see common.sh's header comment for how the
# shared service blocks were verified byte-identical before being
# hoisted out.

# panel_compose_nginx_frontend_remote — MODE=2's nginx variant. No
# /dev/shm or /var/www/html mounts and no `command:` override (unlike
# colocated.sh's nginx variant) — confirmed against the original
# heredoc: a remote Panel-only host has no local selfsteal socket for
# any of that to serve, so nginx just runs its stock entrypoint against
# conf.d/default.conf.
panel_compose_nginx_frontend_remote() {
    local CERT_VOLUMES="$1"

    cat << EOFYML
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
${CERT_VOLUMES}    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
EOFYML
}

# panel_compose_caddy_frontend_remote — MODE=2's Caddy variant (the
# original file's final, unconditional `else` branch). No /dev/shm mount
# and no healthcheck (unlike colocated.sh's Caddy variant) — same
# reasoning as the nginx variant above: nothing writes to a selfsteal
# socket on a Panel-only host, so there is nothing for Caddy to mount or
# wait on.
panel_compose_caddy_frontend_remote() {
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
      - caddy_data:/data
    command: caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
    environment:
      - PANEL_DOMAIN=${PANEL_DOMAIN}
      - SUB_DOMAIN=${SUB_DOMAIN}
      - SELF_STEAL_DOMAIN=${SELFSTEAL_DOMAIN}
      - BACKEND_URL=127.0.0.1:3000
      - SUB_BACKEND_URL=127.0.0.1:3010
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
EOFYML
}

# panel_generate_compose_remote — MODE=2 only. WEB_SERVER branches
# nginx-vs-caddy exactly as the original file's own internal structure
# did for this MODE (elif WEB_SERVER=1 → nginx; else → caddy) — that
# "else means caddy" fallthrough is preserved here deliberately, unlike
# the MODE-level dispatch in compose.sh, because it reproduces a real,
# intended, already-working two-way choice (nginx or caddy), not an
# unhandled third case. WEB_SERVER values other than "1"/"2" were never
# validated by the original code either; that is unchanged here, not a
# newly introduced gap.
panel_generate_compose_remote() {
    local WEB_SERVER="$1"
    local CERT_VOLUMES="$2"
    local PANEL_DOMAIN="$3"
    local SUB_DOMAIN="$4"
    local SELFSTEAL_DOMAIN="$5"

    {
        echo "services:"
        panel_compose_db_block
        echo ""
        panel_compose_app_block
        echo ""
        panel_compose_redis_block
        echo ""
        if [ "$WEB_SERVER" = "1" ]; then
            panel_compose_nginx_frontend_remote "$CERT_VOLUMES"
        else
            panel_compose_caddy_frontend_remote "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"
        fi
        echo ""
        panel_compose_subpage_block
        echo ""
        panel_compose_footer "0" "$([ "$WEB_SERVER" = "2" ] && echo 1 || echo 0)"
    } > /opt/remnawave/docker-compose.yml
}
