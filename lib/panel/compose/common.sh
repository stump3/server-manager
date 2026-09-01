# shellcheck shell=bash
# lib/panel/compose/common.sh — service-block building blocks shared by
# EVERY docker-compose.yml variant this project generates (colocated
# Panel+Node, remote Panel-only, nginx or caddy front-end).
#
# Extracted 2026-08-31 from lib/panel/compose.sh's single 667-line
# panel_generate_compose(), which built five nearly-identical
# docker-compose.yml documents as five separate inline heredocs
# (WEB_SERVER×MODE combinations: 1×1, 1×F, 1×2, 2×1, 2×2/else). Before
# extracting, every block below was diffed byte-for-byte across all five
# of the original heredocs it came from (`diff` on the isolated line
# ranges, not a visual read) — each is 0-diff identical everywhere it
# appears, which is exactly what makes it safe to hoist into one shared
# function instead of leaving it duplicated five times. Nothing here is
# a redesign: these are the same lines, moved.
#
# All four service-block functions below take NO arguments and use a
# QUOTED heredoc delimiter (<< 'BLOCK_EOF') — every line in them is
# already backslash-escaped docker-compose-native variable syntax
# (\${POSTGRES_USER}, \${APP_PORT:-3000}, etc.), never real bash
# interpolation, in the original file. A quoted heredoc suppresses ALL
# expansion, so the backslashes that were needed under the original
# unquoted heredocs are no longer needed here — dropping them is a
# whitespace/escaping-only change with an identical byte-for-byte
# rendered result (confirmed by the regression test, not assumed).

# panel_compose_db_block — remnawave-db (Postgres). Identical across all
# 5 original variants.
panel_compose_db_block() {
    cat << 'BLOCK_EOF'
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
BLOCK_EOF
}

# panel_compose_app_block — remnawave (backend). Identical across all 5
# original variants.
panel_compose_app_block() {
    cat << 'BLOCK_EOF'
  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:${APP_PORT:-3000}'
      - '127.0.0.1:3001:${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
BLOCK_EOF
}

# panel_compose_redis_block — remnawave-redis (Valkey). Identical across
# all 5 original variants.
panel_compose_redis_block() {
    cat << 'BLOCK_EOF'
  remnawave-redis:
    image: valkey/valkey:9.0.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    command: >
      valkey-server --save "" --appendonly no
      --maxmemory-policy noeviction --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
BLOCK_EOF
}

# panel_compose_subpage_block — remnawave-subscription-page. Identical
# across all 5 original variants (including the REMNAWAVE_API_TOKEN
# placeholder — lib/panel/api.sh's token-creation fix patches this file
# in place after compose generation, not this function).
panel_compose_subpage_block() {
    cat << 'BLOCK_EOF'
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    depends_on:
      remnawave: {condition: service_healthy}
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=PLACEHOLDER
    ports: ['127.0.0.1:3010:3010']
    networks: [remnawave-network]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
BLOCK_EOF
}

# panel_compose_footer — trailing `networks:`/`volumes:` section. This is
# the one piece of shared YAML that is NOT identical everywhere: it
# varies along two independent, orthogonal axes that were previously
# encoded implicitly by which of the five inline heredocs a given
# WEB_SERVER×MODE combination happened to fall into —
#   - HAS_IPAM ("1"/"0"): colocated topologies (MODE=1, MODE=F, and
#     WEB_SERVER=2's colocated branch) add
#     `ipam: {config: [{subnet: 172.30.0.0/16}]}` to remnawave-network —
#     confirmed present in every colocated variant's original heredoc
#     and absent from every remote (MODE=2) one, so this tracks topology
#     (colocated.sh vs remote.sh), not WEB_SERVER.
#   - HAS_CADDY_VOLUME ("1"/"0"): the `caddy_data` named volume is
#     present only when WEB_SERVER=2 (caddy), confirmed present in both
#     of the original caddy heredocs and absent from all three nginx
#     ones — tracks WEB_SERVER, not topology.
# All 4 combinations of these two independent booleans are real,
# confirmed-existing variants in the original file (colocated+nginx,
# colocated+caddy, remote+nginx, remote+caddy) — this is not a
# speculative parameterization covering hypothetical cases; every branch
# below reproduces one specific original heredoc's exact footer text.
panel_compose_footer() {
    local HAS_IPAM="$1"
    local HAS_CADDY_VOLUME="$2"

    echo "networks:"
    echo "  remnawave-network:"
    echo "    name: remnawave-network"
    echo "    driver: bridge"
    if [ "$HAS_IPAM" = "1" ]; then
        echo "    ipam:"
        echo "      config: [{subnet: 172.30.0.0/16}]"
    fi
    echo "    external: false"
    echo ""
    echo "volumes:"
    echo "  remnawave-db-data:"
    echo "    driver: local"
    echo "    name: remnawave-db-data"
    echo "  valkey-socket:"
    echo "    name: valkey-socket"
    if [ "$HAS_CADDY_VOLUME" = "1" ]; then
        echo "  caddy_data:"
        echo "    name: caddy_data"
    fi
}
