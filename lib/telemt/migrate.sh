# shellcheck shell=bash
# telemt/migrate.sh — перенос конфигурации (systemd/docker)


telemt_menu_migrate() {
    header "Миграция MTProxy на новый сервер"
    need_root
    [ "$TELEMT_MODE" != "systemd" ] && die "Миграция доступна только в systemd-режиме."
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."
    ensure_sshpass

    echo -e "${BOLD}Данные нового сервера:${RESET}"; echo ""
    ask_ssh_target
    init_ssh_helpers telemt
    # Алиасы для совместимости с остальным кодом функции
    RRUN() { RUN "$@"; }
    RSCP() { PUT "$@" "${_SSH_USER}@${_SSH_IP}:/tmp/"; }
    check_ssh_connection || return 1
    local nh="$_SSH_IP" np="$_SSH_PORT" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(telemt_get_tls_domain "$TELEMT_CONFIG_FILE")
    cur_domain="${cur_domain:-petrovich.ru}"
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"
    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}" < /dev/tty
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}" < /dev/tty

    local users_block
    users_block=$(awk '/^\[access\.users\]/{found=1;next} found&&/^\[/{exit} found&&/=/{print}' "$TELEMT_CONFIG_FILE")
    [ -z "$users_block" ] && die "Не найдено пользователей в конфиге"
    ok "Пользователей: $(echo "$users_block" | grep -c "=")"

    local remote_config
    remote_config="$(cat <<RCONF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = $new_pp

[server.api]
enabled   = true
listen    = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain    = "$new_dom"
mask          = true
tls_emulation = true
tls_front_dir = "$TELEMT_TLSFRONT_DIR"

[access.users]
$users_block
RCONF
)"
    local limits_block
    limits_block=$(telemt_extract_limits_block "$TELEMT_CONFIG_FILE")

    info "Копирую скрипт на новый сервер..."
    RSCP "$(realpath "$0")" &>/dev/null \
        && ok "Скрипт скопирован в /tmp/" \
        || warn "Не удалось скопировать server-manager на новый сервер (не критично для миграции)"
    info "Копирую конфиг..."
    echo "$remote_config" | RRUN "mkdir -p /etc/telemt && cat > /etc/telemt/telemt.toml" \
        || die "Не удалось скопировать конфиг на новый сервер — миграция прервана, старый сервер не тронут"
    [ -n "$limits_block" ] && { echo "$limits_block" | RRUN "echo '' >> /etc/telemt/telemt.toml && cat >> /etc/telemt/telemt.toml" \
        && ok "Лимиты перенесены" || warn "Не удалось перенести лимиты пользователей"; }

    header "Установка на $nh"
    if RRUN bash << REMOTE_INSTALL
set -e
ARCH=\$(uname -m); case "\$ARCH" in x86_64) ;; aarch64) ARCH="aarch64" ;; *) echo "Архитектура не поддерживается"; exit 1 ;; esac
LIBC=\$(ldd --version 2>&1|grep -iq musl&&echo musl||echo gnu)
URL="https://github.com/telemt/telemt/releases/latest/download/telemt-\${ARCH}-linux-\${LIBC}.tar.gz"
TMP=\$(mktemp -d); curl -fsSL "\$URL"|tar -xz -C "\$TMP"; install -m 0755 "\$TMP/telemt" /usr/local/bin/telemt; rm -rf "\$TMP"
echo "[OK] Telemt установлен"
id telemt &>/dev/null||useradd -d /opt/telemt -m -r -U telemt
mkdir -p /opt/telemt/tlsfront; chown -R telemt:telemt /etc/telemt /opt/telemt
cat > /etc/systemd/system/telemt.service << 'SERVICE'
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
SERVICE
systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
echo "[OK] Сервис запущен"
command -v ufw &>/dev/null && ufw allow ${new_pp}/tcp &>/dev/null && echo "[OK] Порт $new_pp открыт"
REMOTE_INSTALL
    then
        ok "Установка завершена!"
    else
        die "Установка на новом сервере не завершилась (см. вывод выше). Старый сервер НЕ тронут, telemt на новом сервере не гарантированно работает — не отключай старый сервер"
    fi
    header "Новые ссылки"; echo -e "${BOLD}Новый IP:${RESET} $nh"; info "Жду запуска..."; sleep 5
    local nl; nl=$(RRUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null"||true)
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

# ── Извлечение блоков ограничений пользователей из telemt.toml ───
# Поддерживает как актуальный формат:
#   [access.user_max_tcp_conns], [access.user_expirations],
#   [access.user_data_quota], [access.user_max_unique_ips]
# так и legacy-формат [access.user_limits.*].
telemt_extract_limits_block() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    awk '
        /^\[(access\.user_max_tcp_conns|access\.user_expirations|access\.user_data_quota|access\.user_max_unique_ips)\]$/ {
            in_section=1; print; next
        }
        /^\[access\.user_limits\./ {
            in_section=1; print; next
        }
        /^\[/ {
            in_section=0
        }
        in_section { print }
    ' "$cfg"
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
    RRUN() { RUN "$@"; }
    # Contract 7: same fix as RUN/PUT in lib/common/ssh.sh — this
    # docker-migration path had its own independent RSCP() that still
    # passed the password via `sshpass -p`, exposed in argv/ps for the
    # process lifetime. Route through PUT (already fixed) instead of
    # re-implementing the scp call here.
    RSCP() { PUT "$1" "${_SSH_USER}@${_SSH_IP}:$2"; }
    check_ssh_connection || return 1
    local nh="$_SSH_IP" np="$_SSH_PORT" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(telemt_get_tls_domain "$TELEMT_CONFIG_FILE")
    cur_domain="${cur_domain:-petrovich.ru}"
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"

    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}" < /dev/tty
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}" < /dev/tty

    local config_to_send
    config_to_send=$(sed "s/^port = .*/port = $new_pp/; s/tls_domain.*=.*/tls_domain    = \"$new_dom\"/" "$TELEMT_CONFIG_FILE")

    info "Проверяю Docker на новом сервере..."
    # intentional: official Docker installer
    RRUN "command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 && systemctl enable docker; }" \
        && ok "Docker готов" || die "Не удалось установить Docker"

    info "Копирую конфиг и compose файл..."
    RRUN "mkdir -p $(dirname "$TELEMT_CONFIG_FILE") $(dirname "$TELEMT_COMPOSE_FILE")"
    echo "$config_to_send" | RRUN "cat > $TELEMT_CONFIG_FILE"
    RSCP "$TELEMT_COMPOSE_FILE" "$TELEMT_COMPOSE_FILE"
    ok "Файлы скопированы"

    info "Запускаю контейнер на новом сервере..."
    RRUN "cd $(dirname "$TELEMT_COMPOSE_FILE") && docker compose pull -q && docker compose up -d" \
        && ok "Контейнер запущен" || die "Ошибка запуска контейнера"

    RRUN "command -v ufw &>/dev/null && ufw allow ${new_pp}/tcp &>/dev/null || true"

    ok "Миграция завершена!"
    header "Новые ссылки"
    echo -e "${BOLD}Новый IP:${RESET} $nh"
    info "Жду запуска..."
    sleep 5
    local nl; nl=$(RRUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null" || true)
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
