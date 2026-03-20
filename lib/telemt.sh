# ████████████████████  TELEMT SECTION  ████████████████████████████
# ═══════════════════════════════════════════════════════════════════

# Переменные Telemt объявлены глобально в начале скрипта

telemt_choose_mode() {
    header "telemt MTProxy — метод установки"
    echo -e "  ${BOLD}1)${RESET} ${BOLD}systemd${RESET} — бинарник с GitHub"
    echo -e "     ${CYAN}Рекомендуется:${RESET} hot reload, меньше RAM, миграция"
    echo ""
    echo -e "  ${BOLD}2)${RESET} ${BOLD}Docker${RESET} — образ с Docker Hub"
    echo ""
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    read -rp "Выбор [1/2]: " ch < /dev/tty
    case "$ch" in
        1) TELEMT_MODE="systemd"; TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD" ;;
        2) TELEMT_MODE="docker";  TELEMT_CONFIG_FILE="$TELEMT_CONFIG_DOCKER";  TELEMT_WORK_DIR="$TELEMT_WORK_DIR_DOCKER" ;;
        0) return 1 ;;
        *) warn "Неверный выбор"; telemt_choose_mode ;;
    esac
    ok "Режим: $TELEMT_MODE"
}

telemt_check_deps() {
    for cmd in curl openssl python3; do
        command -v "$cmd" &>/dev/null || die "Не найдена команда: $cmd"
    done
    if [ "$TELEMT_MODE" = "docker" ]; then
        command -v docker &>/dev/null || die "Docker не установлен."
        docker compose version &>/dev/null || die "Нужен Docker Compose v2."
    else
        command -v systemctl &>/dev/null || die "systemctl не найден. Используй Docker-режим."
    fi
}

telemt_is_running() {
    if [ "$TELEMT_MODE" = "systemd" ]; then
        systemctl is-active --quiet telemt 2>/dev/null
    else
        docker compose -f "$TELEMT_COMPOSE_FILE" ps --status running 2>/dev/null | grep -q "telemt"
    fi
}

TELEMT_CHOSEN_VERSION="latest"

telemt_pick_version() {
    info "Получаю список версий..."
    local versions
    versions=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/${TELEMT_GITHUB_REPO}/releases?per_page=10" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[^"]+' | head -10 || true)
    [ -z "$versions" ] && { warn "Не удалось получить список. Используется latest."; TELEMT_CHOSEN_VERSION="latest"; return; }
    echo ""
    echo -e "${BOLD}Доступные версии:${RESET}"
    local i=1; local -a va=()
    while IFS= read -r v; do
        [ $i -eq 1 ] && echo -e "  ${GREEN}${BOLD}$i)${RESET} $v  ${CYAN}← последняя${RESET}" \
                      || echo -e "  ${BOLD}$i)${RESET} $v"
        va+=("$v"); i=$((i+1))
    done <<< "$versions"
    echo ""
    local ch; read -rp "Версия [1]: " ch; ch="${ch:-1}" < /dev/tty
    if echo "$ch" | grep -qE '^[0-9]+$' && [ "$ch" -ge 1 ] && [ "$ch" -le "${#va[@]}" ]; then
        TELEMT_CHOSEN_VERSION="${va[$((ch-1))]}"
    else
        warn "Неверный выбор, используется latest."; TELEMT_CHOSEN_VERSION="latest"
    fi
}

telemt_download_binary() {
    local ver="${1:-latest}" arch libc url
    arch=$(uname -m); case "$arch" in x86_64) ;; aarch64|arm64) arch="aarch64" ;; *) die "Архитектура не поддерживается: $arch" ;; esac
    ldd --version 2>&1 | grep -iq musl && libc="musl" || libc="gnu"
    [ "$ver" = "latest" ] \
        && url="https://github.com/${TELEMT_GITHUB_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
        || url="https://github.com/${TELEMT_GITHUB_REPO}/releases/download/${ver}/telemt-${arch}-linux-${libc}.tar.gz"
    info "Скачиваю telemt $ver..."
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "$url" | tar -xz -C "$tmp" && install -m 0755 "$tmp/telemt" "$TELEMT_BIN" && rm -rf "$tmp" \
        && ok "Установлен: $TELEMT_BIN" || { rm -rf "$tmp"; die "Не удалось скачать бинарник."; }
}

telemt_write_config() {
    local port="$1" domain="$2"; shift 2
    local tls_front_dir api_listen api_wl
    if [ "$TELEMT_MODE" = "systemd" ]; then
        mkdir -p "$TELEMT_CONFIG_DIR" "$TELEMT_TLSFRONT_DIR"
        tls_front_dir="$TELEMT_TLSFRONT_DIR"; api_listen="127.0.0.1:9091"; api_wl='["127.0.0.1/32"]'
    else
        mkdir -p "$TELEMT_WORK_DIR_DOCKER"; tls_front_dir="tlsfront"; api_listen="0.0.0.0:9091"; api_wl='["127.0.0.0/8"]'
    fi
    { cat <<EOF
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
port = $port

[server.api]
enabled   = true
listen    = "$api_listen"
whitelist = $api_wl

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain    = "$domain"
mask          = true
tls_emulation = true
tls_front_dir = "$tls_front_dir"

[access.users]
EOF
      for pair in "$@"; do echo "${pair%% *} = \"${pair#* }\""; done
    } > "$TELEMT_CONFIG_FILE"
    [ "$TELEMT_MODE" = "systemd" ] && chmod 640 "$TELEMT_CONFIG_FILE"
}

telemt_write_service() {
    cat > "$TELEMT_SERVICE_FILE" <<'EOF'
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
}

telemt_write_compose() {
    local port="$1"
    cat > "$TELEMT_COMPOSE_FILE" <<EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    ports:
      - "${port}:${port}/tcp"
      - "127.0.0.1:9091:9091/tcp"
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
    tmpfs: [/tmp:rw,nosuid,nodev,noexec,size=16m]
    ulimits: {nofile: {soft: 65536, hard: 65536}}
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
EOF
}

telemt_fetch_links() {
    local attempt=0
    info "Запрашиваю данные через API..."
    while [ $attempt -lt 15 ]; do
        local resp; resp=$(curl -s --max-time 5 "$TELEMT_API_URL" 2>/dev/null || true)
        if echo "$resp" | grep -q "tg://proxy"; then
            echo ""
            echo "$resp" | python3 -c "
import sys, json
BOLD='\\033[1m'; CYAN='\\033[0;36m'; GREEN='\\033[0;32m'; GRAY='\\033[0;37m'; RESET='\\033[0m'
def fmt_bytes(b):
    if not b: return '0 B'
    for u in ('B','KB','MB','GB','TB'):
        if b < 1024: return f'{b:.1f} {u}' if u != 'B' else f'{int(b)} B'
        b /= 1024
    return f'{b:.2f} PB'
data = json.load(sys.stdin)
users = data if isinstance(data, list) else data.get('users', data.get('data', []))
if isinstance(users, dict): users = list(users.values())
for u in users:
    name = u.get('username') or u.get('name') or 'user'
    tls  = u.get('links', {}).get('tls', [])
    conns = u.get('current_connections', 0)
    aips  = u.get('active_unique_ips', 0)
    al    = u.get('active_unique_ips_list', [])
    rips  = u.get('recent_unique_ips', 0)
    rl    = u.get('recent_unique_ips_list', [])
    oct   = u.get('total_octets', 0)
    mc    = u.get('max_tcp_conns')
    mi    = u.get('max_unique_ips')
    q     = u.get('data_quota_bytes')
    exp   = u.get('expiration_rfc3339')
    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}      {tls[0]}')
    print(f'{BOLD}│  Подключений:{RESET} {conns}' + (f' / {mc}' if mc else ''))
    print(f'{BOLD}│  Активных IP:{RESET} {aips}' + (f' / {mi}' if mi else ''))
    for ip in al: print(f'{BOLD}│{RESET}    {GREEN}▸ {ip}{RESET}')
    print(f'{BOLD}│  Недавних IP:{RESET} {rips}')
    print(f'{BOLD}│  Трафик:{RESET}      {fmt_bytes(oct)}' + (f' / {fmt_bytes(q)}' if q else ''))
    if exp: print(f'{BOLD}│  Истекает:{RESET}    {exp}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()
" 2>/dev/null || echo "$resp"
            return 0
        fi
        attempt=$((attempt+1)); sleep 2; echo -n "."
    done
    echo ""; warn "API не ответил. Попробуй: curl -s $TELEMT_API_URL"
    return 1
}

telemt_ask_users() {
    TELEMT_USER_PAIRS=()
    info "Добавление пользователей"
    while true; do
        local uname; read -rp "  Имя [Enter чтобы завершить]: " uname < /dev/tty
        [ -z "$uname" ] && [ ${#TELEMT_USER_PAIRS[@]} -gt 0 ] && break
        [ -z "$uname" ] && { warn "Нужен хотя бы один пользователь!"; continue; }
        local secret; read -rp "  Секрет (32 hex) [Enter = сгенерировать]: " secret < /dev/tty
        if [ -z "$secret" ]; then
            secret=$(gen_secret); ok "Секрет: $secret"
        elif ! echo "$secret" | grep -qE '^[0-9a-fA-F]{32}$'; then
            warn "Секрет должен быть 32 hex-символа"; continue
        fi
        TELEMT_USER_PAIRS+=("$uname $secret"); ok "Пользователь '$uname' добавлен"
        echo ""
    done
}

telemt_menu_install() {
    header "Установка MTProxy (${TELEMT_MODE})"
    [ "$TELEMT_MODE" = "systemd" ] && need_root
    local port; read -rp "Порт прокси [8443]: " port; port="${port:-8443}" < /dev/tty
    ss -tlnp 2>/dev/null | grep -q ":${port} " && { warn "Порт $port занят!"; read -rp "Другой порт: " port; } < /dev/tty
    local domain; read -rp "Домен-маскировка [petrovich.ru]: " domain; domain="${domain:-petrovich.ru}" < /dev/tty
    echo ""; telemt_ask_users

    if [ "$TELEMT_MODE" = "systemd" ]; then
        telemt_pick_version
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"
        id telemt &>/dev/null || useradd -d "$TELEMT_WORK_DIR" -m -r -U telemt
        telemt_write_config "$port" "$domain" "${TELEMT_USER_PAIRS[@]}"
        mkdir -p "$TELEMT_TLSFRONT_DIR"
        chown -R telemt:telemt "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
        telemt_write_service
        systemctl daemon-reload; systemctl enable telemt; systemctl start telemt
        ok "Сервис запущен"
    else
        telemt_write_config "$port" "$domain" "${TELEMT_USER_PAIRS[@]}"
        telemt_write_compose "$port"
        cd "$TELEMT_WORK_DIR_DOCKER"
        docker compose pull -q; docker compose up -d
        ok "Контейнер запущен"
    fi
    command -v ufw &>/dev/null && ufw allow "${port}/tcp" &>/dev/null && ok "ufw: порт $port открыт"
    sleep 3; header "Ссылки"
    echo -e "${BOLD}IP:${RESET} $(get_public_ip)"
    telemt_fetch_links
}

telemt_menu_add_user() {
    header "Добавить пользователя"
    [ "$TELEMT_MODE" = "systemd" ] && need_root
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден. Сначала выполни установку."
    local uname; read -rp "  Имя: " uname; [ -z "$uname" ] && die "Имя не может быть пустым" < /dev/tty
    grep -q "^${uname} = " "$TELEMT_CONFIG_FILE" && die "Пользователь '$uname' уже существует"
    local secret; read -rp "  Секрет [Enter = сгенерировать]: " secret < /dev/tty
    [ -z "$secret" ] && { secret=$(gen_secret); ok "Секрет: $secret"; } \
        || echo "$secret" | grep -qE '^[0-9a-fA-F]{32}$' || die "Секрет должен быть 32 hex"
    echo ""; echo -e "${BOLD}Ограничения (Enter = пропустить):${RESET}"
    local mc mi qg ed
    read -rp "  Макс. подключений:    " mc < /dev/tty
    read -rp "  Макс. уникальных IP:  " mi < /dev/tty
    read -rp "  Квота трафика (ГБ):   " qg < /dev/tty
    read -rp "  Срок действия (дней): " ed < /dev/tty
    echo "$uname = \"$secret\"" >> "$TELEMT_CONFIG_FILE"
    local has=0 block=""
    [ -n "$mc" ] && { block+="\nmax_tcp_conns = $mc"; has=1; }
    [ -n "$mi" ] && { block+="\nmax_unique_ips = $mi"; has=1; }
    [ -n "$qg" ] && { local qb; qb=$(python3 -c "print(int($qg*1024**3))"); block+="\ndata_quota_bytes = $qb"; has=1; }
    [ -n "$ed" ] && { local exp; exp=$(python3 -c "from datetime import datetime,timezone,timedelta; dt=datetime.now(timezone.utc)+timedelta(days=int($ed)); print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))"); block+="\nexpiration_rfc3339 = \"$exp\""; has=1; }
    [ "$has" -eq 1 ] && { printf "\n[access.user_limits.$uname]$block\n" >> "$TELEMT_CONFIG_FILE"; ok "Ограничения применены"; }
    ok "Пользователь '$uname' добавлен"
    telemt_is_running && {
        if [ "$TELEMT_MODE" = "systemd" ]; then
            info "Hot reload..."
            systemctl reload telemt 2>/dev/null || systemctl restart telemt
        else
            cd "$TELEMT_WORK_DIR_DOCKER" && docker compose restart telemt
        fi; sleep 2
    }
    header "Ссылки"; telemt_fetch_links
}

telemt_menu_delete_user() {
    header "Удалить пользователя"
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."

    # Собираем список пользователей из [access.users]
    local -a users=()
    while IFS= read -r line; do
        local u; u=$(echo "$line" | sed 's/ =.*//' | tr -d ' ')
        [ -n "$u" ] && users+=("$u")
    done < <(awk '/^\[access\.users\]/{f=1;next} f&&/^\[/{exit} f&&/=/{print}' "$TELEMT_CONFIG_FILE")

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены в конфиге"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя для удаления:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    [[ "$ch" == "0" ]] && return
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi

    local selected="${users[$((ch-1))]}"
    read -rp "  Удалить '${selected}'? (y/N): " _yn < /dev/tty
    [[ "${_yn:-N}" =~ ^[yY]$ ]] || { warn "Отменено"; return; }

    # Удаляем строку пользователя из [access.users]
    sed -i "/^${selected} = /d" "$TELEMT_CONFIG_FILE"
    # Удаляем секцию [access.user_limits.USERNAME] если есть
    sed -i "/^\[access\.user_limits\.${selected}\]/,/^\[/{/^\[access\.user_limits\.${selected}\]/d; /^\[/!{/^$/d; d}}" "$TELEMT_CONFIG_FILE"

    ok "Пользователь '${selected}' удалён"

    # Hot reload
    if telemt_is_running; then
        if [ "$TELEMT_MODE" = "systemd" ]; then
            info "Hot reload..."
            systemctl reload telemt 2>/dev/null || systemctl restart telemt
        else
            cd "$TELEMT_WORK_DIR_DOCKER" && docker compose restart telemt >/dev/null 2>&1
        fi
        sleep 1
        ok "Конфиг применён"
    fi
}

telemt_menu_links()  { header "Пользователи и ссылки"; telemt_is_running || die "Сервис не запущен."; telemt_fetch_links; }

telemt_menu_status() {
    header "Статус"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        systemctl status telemt --no-pager||true; echo ""; info "Последние логи:"; journalctl -u telemt --no-pager -n 30
    else
        cd "$TELEMT_WORK_DIR_DOCKER" 2>/dev/null || die "Директория не найдена"
        docker compose ps; echo ""; info "Последние логи:"; docker compose logs --tail=20
    fi
}

telemt_menu_update() {
    header "Обновление"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        need_root
        info "Текущая версия: $($TELEMT_BIN --version 2>/dev/null||echo неизвестна)"
        telemt_pick_version; systemctl stop telemt
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"; systemctl start telemt
    else
        cd "$TELEMT_WORK_DIR_DOCKER" || die "Директория не найдена"
        docker compose pull; docker compose up -d
    fi
    ok "Обновлено"
}

telemt_menu_stop() {
    header "Остановка"
    if [ "$TELEMT_MODE" = "systemd" ]; then need_root; systemctl stop telemt
    else cd "$TELEMT_WORK_DIR_DOCKER" || die ""; docker compose down; fi
    ok "Остановлено"
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
    # Алиасы для совместимости с остальным кодом функции
    RRUN() { RUN "$@"; }
    RSCP() { PUT "$@" "${_SSH_USER}@${_SSH_IP}:/tmp/"; }
    check_ssh_connection || return 1
    local nh="$_SSH_IP" np="$_SSH_PORT" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oP '"K[^"]+' || echo "petrovich.ru")
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
    limits_block=$(awk '/^\[access\.user_limits\./{found=1} found{print}' "$TELEMT_CONFIG_FILE" || true)

    info "Копирую скрипт на новый сервер..."
    RSCP "$(realpath "$0")" &>/dev/null; ok "Скрипт скопирован в /tmp/"
    info "Копирую конфиг..."
    echo "$remote_config" | RRUN "mkdir -p /etc/telemt && cat > /etc/telemt/telemt.toml"
    [ -n "$limits_block" ] && { echo "$limits_block" | RRUN "echo '' >> /etc/telemt/telemt.toml && cat >> /etc/telemt/telemt.toml"; ok "Лимиты перенесены"; }

    header "Установка на $nh"
    RRUN bash << REMOTE_INSTALL
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
echo "[OK] Сервис запущен"
command -v ufw &>/dev/null && ufw allow ${new_pp}/tcp &>/dev/null && echo "[OK] Порт $new_pp открыт"
REMOTE_INSTALL

    ok "Установка завершена!"
    header "Новые ссылки"; echo -e "${BOLD}Новый IP:${RESET} $nh"; info "Жду запуска..."; sleep 5
    local nl; nl=$(RRUN "curl -s --max-time 10 http://127.0.0.1:9091/v1/users 2>/dev/null"||true)
    if echo "$nl" | grep -q "tg://proxy"; then
        echo "$nl" | python3 -c "
import sys,json
BOLD='\\033[1m'; CYAN='\\033[0;36m'; RESET='\\033[0m'
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
    RRUN() { RUN "$@"; }
    RSCP() { sshpass -p "$_SSH_PASS" scp -P "$_SSH_PORT"         -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$1" "${_SSH_USER}@${_SSH_IP}:$2"; }
    check_ssh_connection || return 1
    local nh="$_SSH_IP" np="$_SSH_PORT" nu="$_SSH_USER"

    local cur_port cur_domain
    cur_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oE "[0-9]+" || echo "8443")
    cur_domain=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_FILE" | head -1 | grep -oP '"K[^"]+' || echo "petrovich.ru")
    echo ""; echo -e "${BOLD}Текущие настройки:${RESET} порт=$cur_port домен=$cur_domain"

    local new_pp new_dom
    read -rp "  Порт на новом сервере [Enter=$cur_port]: " new_pp; new_pp="${new_pp:-$cur_port}" < /dev/tty
    read -rp "  Домен-маскировка [Enter=$cur_domain]: " new_dom; new_dom="${new_dom:-$cur_domain}" < /dev/tty

    # Обновляем порт и домен в конфиге если изменились
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
    RRUN "cd $(dirname "$TELEMT_COMPOSE_FILE") && docker compose pull -q && docker compose up -d"         && ok "Контейнер запущен" || die "Ошибка запуска контейнера"

    # Открываем порт
    RRUN "command -v ufw &>/dev/null && ufw allow ${new_pp}/tcp &>/dev/null || true"

    # Проверяем ссылки
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

telemt_main_menu() {
    # Загружаем версию и порт один раз при входе
    local mode_label ver telemt_port
    mode_label=""; [ "$TELEMT_MODE" = "systemd" ] && mode_label="systemd" || mode_label="Docker"
    ver=$(get_telemt_version 2>/dev/null || true)
    telemt_port=""
    [ -f "$TELEMT_CONFIG_FILE" ] && telemt_port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" 2>/dev/null | grep -oE "[0-9]+" | head -1 || true)
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  📡  MTProxy (telemt)${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        if [ -n "$ver" ] || [ -n "$telemt_port" ]; then
            [ -n "$ver" ]         && echo -e "  ${GRAY}Версия  ${NC}${ver}  ${GRAY}(${mode_label})${NC}"
            [ -n "$telemt_port" ] && echo -e "  ${GRAY}Порт    ${NC}${telemt_port}"
            echo ""
        fi
        echo -e "  ${BOLD}1)${RESET} 🔧  Установка"
        echo -e "  ${BOLD}2)${RESET} ⚙️  Управление"
        echo -e "  ${BOLD}3)${RESET} 👥  Пользователи"
        echo -e "  ${BOLD}4)${RESET} 📦  Миграция на другой сервер"
        echo -e "  ${BOLD}5)${RESET} 🔀  Сменить режим (systemd ↔ Docker)"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) telemt_menu_install || true ;;
            2) telemt_submenu_manage || true ;;
            3) telemt_submenu_users || true ;;
            4) if [ "$TELEMT_MODE" = "systemd" ]; then
                   telemt_menu_migrate
               else
                   telemt_menu_migrate_docker
               fi ;;
            5) telemt_choose_mode; telemt_check_deps || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

telemt_submenu_manage() {
    while true; do
        clear
        header "MTProxy — Управление"
        echo -e "  ${BOLD}1)${RESET} 📊  Статус и логи"
        echo -e "  ${BOLD}2)${RESET} 🔄  Обновить"
        echo -e "  ${BOLD}3)${RESET} ⏹️  Остановить"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) telemt_menu_status || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) telemt_menu_update || true ;;
            3) telemt_menu_stop || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

telemt_submenu_users() {
    while true; do
        clear
        header "MTProxy — Пользователи"
        echo -e "  ${BOLD}1)${RESET} ➕  Добавить пользователя"
        echo -e "  ${BOLD}2)${RESET} ➖  Удалить пользователя"
        echo -e "  ${BOLD}3)${RESET} 👥  Пользователи и ссылки"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) telemt_menu_add_user || true ;;
            2) telemt_menu_delete_user || true ;;
            3) telemt_menu_links || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

telemt_section() {
    if [ -z "$TELEMT_MODE" ]; then
        # Автоопределение если уже установлен
        if systemctl is-active --quiet telemt 2>/dev/null || systemctl is-enabled --quiet telemt 2>/dev/null; then
            TELEMT_MODE="systemd"; TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD"
        elif { docker ps --format "{{.Names}}" 2>/dev/null || true; } | grep -q "^telemt$"; then
            TELEMT_MODE="docker"; TELEMT_CONFIG_FILE="$TELEMT_CONFIG_DOCKER"; TELEMT_WORK_DIR="$TELEMT_WORK_DIR_DOCKER"
        else
            telemt_choose_mode || return
        fi
    fi
    telemt_check_deps
    telemt_main_menu
}
