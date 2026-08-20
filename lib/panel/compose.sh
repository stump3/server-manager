# shellcheck shell=bash
# panel/compose.sh — генерация /opt/remnawave/docker-compose.yml
# (4 heredoc-варианта по матрице WEB_SERVER×MODE)

panel_generate_compose() {
    local WEB_SERVER="$1"
    local MODE="$2"
    local CERT_VOLUMES="$3"
    local PANEL_DOMAIN="$4"
    local SUB_DOMAIN="$5"
    local SELFSTEAL_DOMAIN="$6"

    # docker-compose
    if [ "$WEB_SERVER" = "1" ] && [ "$MODE" = "1" ]; then
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

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

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
${CERT_VOLUMES}    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
    depends_on: [remnawave, remnawave-subscription-page]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

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

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config: [{subnet: 172.30.0.0/16}]
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
EOFYML
    elif [ "$WEB_SERVER" = "1" ] && [ "$MODE" = "2" ]; then
        # ── Nginx, только панель ──────────────────────────────────
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

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

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
EOFYML
    elif [ "$WEB_SERVER" = "2" ] && [ "$MODE" = "1" ]; then
        # ── Caddy, панель + нода (selfsteal) ─────────────────────
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

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

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config: [{subnet: 172.30.0.0/16}]
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
  caddy_data:
    name: caddy_data
EOFYML
    else
        # ── Caddy, только панель ──────────────────────────────────
        cat > /opt/remnawave/docker-compose.yml << EOFYML
services:
  remnawave-db:
    image: postgres:18.3
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports: ['127.0.0.1:6767:5432']
    volumes: [remnawave-db-data:/var/lib/postgresql]
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    restart: always
    ulimits: {nofile: {soft: 1048576, hard: 1048576}}
    env_file: .env
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: {condition: service_healthy}
      remnawave-redis: {condition: service_healthy}
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

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

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
  caddy_data:
    name: caddy_data
EOFYML
    fi
}
