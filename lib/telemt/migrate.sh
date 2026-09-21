# shellcheck shell=bash
# telemt/migrate.sh — перенос конфигурации (systemd/docker)
#
# Canonical ownership (migration-ownership audit, this pass): this file
# owns TeleMT's migration semantics -- both non-interactive payloads
# (telemt_migrate_systemd_payload/telemt_migrate_docker_payload, called
# by lib/migrate.sh:migrate_transfer_mtproxy() during migrate_all(), and
# usable standalone) and their interactive wrappers
# (telemt_menu_migrate/telemt_menu_migrate_docker, called from
# migrate_menu() item 2). lib/migrate.sh does orchestration/ordering
# only (Panel -> MTProxy -> Hysteria2) and dispatch by installed mode
# (telemt_detect_installed_mode(), lib/telemt/core.sh) -- it must not
# carry its own independent copy of either payload's actual config/
# install logic. Previously it did: migrate_transfer_mtproxy()'s
# systemd branch reimplemented the whole transfer inline, and its
# docker branch called a payload function of this same name that this
# file never actually defined -- confirmed by repo-wide grep and by a
# hard crash (`command not found`, exit 127) the first time
# migrate_transfer_mtproxy() reached a docker-mode source in
# test_telemt_migrate_colocate.sh. Both payloads below are the sole
# production definition; lib/migrate.sh only calls them.
#
# Preserve-source-config semantics (payload contract, both modes): the
# source telemt.toml is the source of truth. Only the two
# migration-specific fields (port, tls_domain) are substituted via sed;
# everything else -- ip/proxy_protocol, users, limits/expirations,
# censorship, general, and any future field neither payload has ever
# heard of -- travels through byte-for-byte, because it is never
# reconstructed from a template. telemt_menu_migrate() previously
# rebuilt telemt.toml from a hardcoded heredoc template instead, which
# silently dropped ip=127.0.0.1 + proxy_protocol=true for F/J
# co-located sources (breaking the PROXY-protocol contract with the
# shared nginx :443 stream -- see docs/edge_contracts.md) and any field
# it didn't explicitly re-extract (its only concession to preservation
# was manually re-splicing out [access.users] and the limits sections
# via telemt_extract_limits_block(), below, which is why that helper
# has no remaining caller once this function stopped rebuilding the
# config).
#
# Both payloads take (port, domain) and read the config to migrate from
# $TELEMT_CONFIG_FILE (the same global every other TeleMT
# mode-dependent call site already keys off -- lib/telemt/core.sh's own
# telemt_choose_mode()/telemt_section()); the caller (automatic
# dispatch or interactive wrapper) is responsible for setting it to the
# right per-mode path before calling, exactly as
# migrate_transfer_mtproxy()'s docker branch already did for
# TELEMT_CONFIG_FILE="$TELEMT_CONFIG_DOCKER" before this pass. Neither
# payload calls ask_ssh_target()/init_ssh_helpers() or touches
# /dev/tty: both assume RUN/PUT and the _SSH_* globals they close over
# are already initialized by whichever caller got them there
# (interactive wrappers via ask_ssh_target+init_ssh_helpers below;
# migrate_all() via migrate_prepare_target() before
# migrate_transfer_mtproxy() ever runs) -- same "already-initialized
# session" convention lib/migrate.sh's own migrate_transfer_panel()/
# migrate_transfer_hysteria() already rely on. Failures are reported by
# return status (never `die`, which would exit(1) the whole process --
# fine for a directly-invoked interactive wrapper, wrong for a payload
# meant to be one step inside migrate_all()'s Panel->MTProxy->Hysteria2
# pipeline): each interactive wrapper below translates a non-zero
# return into `die` itself, same as before; migrate_transfer_mtproxy()
# translates it into `warn` and continues to Hysteria2, same as its
# existing docker-branch convention.
telemt_migrate_systemd_payload() {
    local port="$1" domain="$2"
    # Malformed-config guard: telemt_detect_listener_ip() (canonical,
    # already used by telemt_detect_state()) returns empty if the
    # source config has no [[server.listeners]] section at all. Bail
    # out explicitly instead of forwarding an incomplete config -- the
    # "old hardcoded fallback must not reappear" case: do NOT fall
    # through to writing any default listener config.
    if [ -z "$(telemt_detect_listener_ip "$TELEMT_CONFIG_FILE")" ]; then
        warn "MTProxy (systemd): конфиг не содержит [[server.listeners]] — похоже на повреждённый файл, пропускаю перенос"
        return 1
    fi

    info "Копирую конфиг..."
    local config_to_send
    config_to_send=$(sed "s/^port = .*/port = $port/; s/^tls_domain.*=.*/tls_domain    = \"$domain\"/" "$TELEMT_CONFIG_FILE")
    echo "$config_to_send" | RUN "mkdir -p /etc/telemt && cat > /etc/telemt/telemt.toml" \
        || { warn "Не удалось скопировать конфиг на новый сервер"; return 1; }

    RUN bash << RTELEMT
set -e
ARCH=\$(uname -m); case "\$ARCH" in x86_64) ;; aarch64) ARCH="aarch64" ;; *) echo "Архитектура не поддерживается"; exit 1 ;; esac
LIBC=\$(ldd --version 2>&1|grep -iq musl&&echo musl||echo gnu)
URL="https://github.com/telemt/telemt/releases/latest/download/telemt-\${ARCH}-linux-\${LIBC}.tar.gz"
TMP=\$(mktemp -d); curl -fsSL "\$URL"|tar -xz -C "\$TMP"; install -m 0755 "\$TMP/telemt" /usr/local/bin/telemt; rm -rf "\$TMP"
echo "[OK] Telemt установлен"
id telemt &>/dev/null || useradd -d /opt/telemt -m -r -U telemt
mkdir -p /opt/telemt/tlsfront; chown -R telemt:telemt /etc/telemt /opt/telemt
cat > /etc/systemd/system/telemt.service << 'SVC'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
echo "[OK] Сервис запущен"
command -v ufw &>/dev/null && ufw allow $port/tcp >/dev/null 2>&1 || true
RTELEMT
}

telemt_migrate_docker_payload() {
    local port="$1" domain="$2"
    if [ -z "$(telemt_detect_listener_ip "$TELEMT_CONFIG_FILE")" ]; then
        warn "MTProxy (docker): конфиг не содержит [[server.listeners]] — похоже на повреждённый файл, пропускаю перенос"
        return 1
    fi

    local config_to_send
    config_to_send=$(sed "s/^port = .*/port = $port/; s/tls_domain.*=.*/tls_domain    = \"$domain\"/" "$TELEMT_CONFIG_FILE")

    info "Проверяю Docker на новом сервере..."
    # intentional: official Docker installer
    RUN "command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 && systemctl enable docker; }" \
        && ok "Docker готов" || { warn "Не удалось установить Docker на новом сервере"; return 1; }

    info "Копирую конфиг и compose файл..."
    RUN "mkdir -p $(dirname "$TELEMT_CONFIG_FILE") $(dirname "$TELEMT_COMPOSE_FILE")"
    echo "$config_to_send" | RUN "cat > $TELEMT_CONFIG_FILE" \
        || { warn "Не удалось скопировать конфиг на новый сервер"; return 1; }
    # Contract 7: same fix as RUN/PUT in lib/common/ssh.sh — this
    # docker-migration path had its own independent RSCP() that still
    # passed the password via `sshpass -p`, exposed in argv/ps for the
    # process lifetime. PUT (already fixed) is called directly instead
    # of re-implementing the scp call here.
    PUT "$TELEMT_COMPOSE_FILE" "${_SSH_USER}@${_SSH_IP}:$TELEMT_COMPOSE_FILE" \
        || { warn "Не удалось скопировать docker-compose.yml"; return 1; }
    ok "Файлы скопированы"

    info "Запускаю контейнер на новом сервере..."
    RUN "cd $(dirname "$TELEMT_COMPOSE_FILE") && docker compose pull -q && docker compose up -d" \
        && ok "Контейнер запущен" || { warn "Ошибка запуска контейнера"; return 1; }

    RUN "command -v ufw &>/dev/null && ufw allow ${port}/tcp &>/dev/null || true"
    return 0
}

telemt_menu_migrate() {
    header "Миграция MTProxy на новый сервер"
    need_root
    [ "$TELEMT_MODE" != "systemd" ] && die "Миграция доступна только в systemd-режиме."
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."
    ensure_sshpass

    echo -e "${BOLD}Данные нового сервера:${RESET}"; echo ""
    ask_ssh_target
    init_ssh_helpers telemt
    check_ssh_connection || return 1
    local nh="$_SSH_IP"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(telemt_get_tls_domain "$TELEMT_CONFIG_FILE")
    cur_domain="${cur_domain:-petrovich.ru}"
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"
    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}" < /dev/tty
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}" < /dev/tty

    info "Копирую скрипт на новый сервер..."
    PUT "$(realpath "$0")" "${_SSH_USER}@${_SSH_IP}:/tmp/" &>/dev/null \
        && ok "Скрипт скопирован в /tmp/" \
        || warn "Не удалось скопировать server-manager на новый сервер (не критично для миграции)"

    header "Установка на $nh"
    if telemt_migrate_systemd_payload "$new_pp" "$new_dom"; then
        ok "Установка завершена!"
    else
        die "Установка на новом сервере не завершилась (см. вывод выше). Старый сервер НЕ тронут, telemt на новом сервере не гарантированно работает — не отключай старый сервер"
    fi
    header "Новые ссылки"; echo -e "${BOLD}Новый IP:${RESET} $nh"; info "Жду запуска..."; sleep 5
    local nl; nl=$(RUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null"||true)
    if echo "$nl" | grep -q "tg://proxy"; then
        echo "$nl" | python3 -c "
import sys,json
BOLD='\033[1m'; CYAN='\033[0;36m'; RESET='\033[0m'
data=json.load(sys.stdin); users=data if isinstance(data,list) else data.get('users',data.get('data',[]))
if isinstance(users,dict): users=list(users.values())
for u in users:
    name=u.get('username') or u.get('name') or 'user'
    tls=u.get('links',{}).get('tls',[])
    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}  {tls[0]}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()
" 2>/dev/null
        ok "Миграция завершена! Разошли новые ссылки."
        warn "Старый сервер ещё работает. Когда будешь готов: systemctl stop telemt"
    else
        warn "Сервис запущен, но API пока не ответил. Проверь: curl -s http://127.0.0.1:9091/v1/users"
    fi
}

telemt_menu_migrate_docker() {
    header "Миграция MTProxy (Docker) на новый сервер"
    need_root
    [ "$TELEMT_MODE" != "docker" ] && die "Эта функция только для Docker-режима."
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден: $TELEMT_CONFIG_FILE"
    [ ! -f "$TELEMT_COMPOSE_FILE" ] && die "docker-compose.yml не найден: $TELEMT_COMPOSE_FILE"
    ensure_sshpass

    echo -e "${BOLD}Данные нового сервера:${RESET}"; echo ""
    ask_ssh_target
    init_ssh_helpers telemt
    check_ssh_connection || return 1
    local nh="$_SSH_IP" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(telemt_get_tls_domain "$TELEMT_CONFIG_FILE")
    cur_domain="${cur_domain:-petrovich.ru}"
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"

    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}" < /dev/tty
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}" < /dev/tty

    if telemt_migrate_docker_payload "$new_pp" "$new_dom"; then
        ok "Миграция завершена!"
    else
        die "Перенос MTProxy (Docker) не завершился (см. вывод выше). Старый сервер НЕ тронут."
    fi

    header "Новые ссылки"
    echo -e "${BOLD}Новый IP:${RESET} $nh"
    info "Жду запуска..."
    sleep 5
    local nl; nl=$(RUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null" || true)
    if echo "$nl" | grep -q "tg://proxy"; then
        echo "$nl" | python3 -c "
import sys,json
BOLD='\033[1m'; CYAN='\033[0;36m'; RESET='\033[0m'
data=json.load(sys.stdin); users=data if isinstance(data,list) else data.get('users',data.get('data',[]))
if isinstance(users,dict): users=list(users.values())
for u in users:
    name=u.get('username') or u.get('name') or 'user'
    tls=u.get('links',{}).get('tls',[])
    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}  {tls[0]}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()
" 2>/dev/null
        warn "Старый контейнер ещё работает. Когда будешь готов:"
        echo -e "     ${CYAN}cd $(dirname "$TELEMT_COMPOSE_FILE") && docker compose down${NC}"
    else
        warn "Сервис запущен, но API пока не ответил. Проверь:"
        echo -e "     ${CYAN}ssh ${nu}@${nh} curl -s http://127.0.0.1:9091/v1/users${NC}"
    fi
}
