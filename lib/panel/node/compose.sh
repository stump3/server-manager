# shellcheck shell=bash
#
# lib/panel/node/compose.sh — генератор standalone-деплоя Remote Node.
#
# STEP 1 (Stage 7): только генерация файлов. НЕ подключено к MODE=2
# orchestration, НЕ вызывается из panel_install(). Вызывается вручную/из
# будущего STEP.
#
# Отличие от lib/panel/caddy/config.sh (Panel-side Caddy):
#   - никакого PANEL_DOMAIN/SUB_DOMAIN/BACKEND_URL/COOKIE_KEY/oauth2
#   - единственный домен — SELFSTEAL_DOMAIN (decoy + REALITY SNI identity)
#   - :443 принадлежит Xray/REALITY (remnanode), Caddy НИКОГДА не слушает
#     публичный :443 — только /dev/shm/nginx.sock (HTTPS fallback) и :80
#     (ACME HTTP-01 + редирект)

panel_generate_node_compose() {
    local SECRET_KEY="$1"
    local SELFSTEAL_DOMAIN="$2"

    mkdir -p /opt/remnanode

    # ── docker-compose.yml ────────────────────────────────────────────
    # remnanode-блок — source of truth: lib/panel/install.sh, MODE=1 ветка
    # panel_generate_compose() (совпадает byte-for-byte по существу, кроме
    # SECRET_KEY, который здесь параметризован явным аргументом функции).
    cat > /opt/remnanode/docker-compose.yml << EOFYML
services:
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
      - SECRET_KEY=${SECRET_KEY}
    volumes: [/dev/shm:/dev/shm:rw]
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}

  remnanode-caddy:
    image: caddy:2.11
    container_name: remnanode-caddy
    hostname: remnanode-caddy
    restart: always
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    logging: {driver: json-file, options: {max-size: 100m, max-file: '5'}}
EOFYML

    # ── Caddyfile (минимальный standalone decoy) ───────────────────────
    # Синтаксис (listener_wrappers/unix-socket/ACME) — source of truth:
    # lib/panel/caddy/config.sh, selfsteal-блок MODE=1 ветки. Panel-
    # специфичные блоки (PANEL_DOMAIN/SUB_DOMAIN/BACKEND_URL/oauth2/cookie)
    # сюда намеренно не переносятся.
    #
    # Отличие от оригинала: там ${SELF_STEAL_DOMAIN} экранирован (\$) и
    # резолвится самим Caddy из ENV контейнера (Panel docker-compose
    # передаёт эту переменную явно). Здесь домен интерполируется bash'ем
    # прямо на этапе генерации файла — без доп. env var в compose, т.к.
    # для standalone Node это единственный домен и заранее известен
    # generator'у как параметр. Осознанное упрощение, не ошибка.
    cat > /opt/remnanode/Caddyfile << CADDYEOF
{
    admin off
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
    auto_https disable_redirects
}

http://${SELFSTEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://${SELFSTEAL_DOMAIN}{uri} permanent
}

https://${SELFSTEAL_DOMAIN} {
    bind unix//dev/shm/nginx.sock
    root * /var/www/html
    try_files {path} /index.html
    file_server
}
CADDYEOF

    ok "Node compose и Caddyfile сгенерированы в /opt/remnanode"
}
