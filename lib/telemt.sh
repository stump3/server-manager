# ████████████████████  TELEMT SECTION  ████████████████████████████
# ═══════════════════════════════════════════════════════════════════

# Переменные Telemt объявлены глобально в начале скрипта

# ── Глобальные переменные upstream-настроек ──────────────────────
TELEMT_USE_ME="true"
TELEMT_SOCKS5_ADDR=""
TELEMT_SOCKS5_USER=""
TELEMT_SOCKS5_PASS=""

# ── Опрос: middle_proxy + SOCKS5 upstream ────────────────────────
telemt_ask_upstream() {
    echo ""
    echo -e "  ${BOLD}Режим подключения к Telegram:${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Middle Proxy ${GRAY}(рекомендуется, через инфраструктуру Telegram)${NC}"
    echo -e "  ${BOLD}2)${NC} Direct       ${GRAY}(прямое подключение к DC, без ME)${NC}"
    echo ""
    local me_ch; read -rp "  Режим [1]: " me_ch </dev/tty; me_ch="${me_ch:-1}"
    [ "$me_ch" = "2" ] && TELEMT_USE_ME="false" || TELEMT_USE_ME="true"

    echo ""
    echo -e "  ${BOLD}SOCKS5-прокси:${NC} ${GRAY}нужен если Telegram заблокирован на этом сервере${NC}"
    if confirm "Маршрутизировать через SOCKS5?" n; then
        local addr
        while true; do
            read -rp "  Адрес SOCKS5 (host:port): " addr </dev/tty
            [[ "$addr" =~ ^[^:]+:[0-9]+$ ]] && break
            warn "Формат: host:port (например 1.2.3.4:1080)"
        done
        TELEMT_SOCKS5_ADDR="$addr"
        read -rp "  Логин (Enter — без аутентификации): " TELEMT_SOCKS5_USER </dev/tty
        if [ -n "$TELEMT_SOCKS5_USER" ]; then
            read -rsp "  Пароль: " TELEMT_SOCKS5_PASS </dev/tty; echo
        fi
        ok "SOCKS5: ${TELEMT_SOCKS5_ADDR}"
    else
        TELEMT_SOCKS5_ADDR=""; TELEMT_SOCKS5_USER=""; TELEMT_SOCKS5_PASS=""
    fi
}

telemt_choose_mode() {
    header "telemt MTProxy — метод установки"
    echo -e "  ${BOLD}1)${RESET} ${BOLD}systemd${RESET} — бинарник с GitHub"
    echo -e "     ${CYAN}Рекомендуется:${RESET} hot reload, меньше RAM, миграция"
    echo ""
    echo -e "  ${BOLD}2)${RESET} ${BOLD}Docker${RESET} — образ с GitHub Container Registry"
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

# Ждёт готовности API, возвращает 0 при успехе
telemt_wait_api() {
    local attempts="${1:-15}"
    local i=0
    while [ $i -lt "$attempts" ]; do
        local resp; resp=$(curl -s --max-time 3 "http://127.0.0.1:9091/v1/health" 2>/dev/null || true)
        echo "$resp" | grep -q '"ok":true' && return 0
        i=$((i+1)); sleep 2; echo -n "."
    done
    echo ""
    return 1
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
    local ch; read -rp "Версия [1]: " ch </dev/tty; ch="${ch:-1}"
    if echo "$ch" | grep -qE '^[0-9]+$' && [ "$ch" -ge 1 ] && [ "$ch" -le "${#va[@]}" ]; then
        TELEMT_CHOSEN_VERSION="${va[$((ch-1))]}"
    else
        warn "Неверный выбор, используется latest."; TELEMT_CHOSEN_VERSION="latest"
    fi
}

# ── Получить текущий tls_domain из telemt.toml ───────────────────
telemt_get_tls_domain() {
    local cfg="$1"
    [ -f "$cfg" ] || { echo "petrovich.ru"; return 0; }
    awk -F'"' '/^[[:space:]]*tls_domain[[:space:]]*=/{print $2; exit}' "$cfg" 2>/dev/null \
        | sed '/^[[:space:]]*$/d' \
        | head -1 \
        || true
}

telemt_download_binary() {
    local ver="${1:-latest}" arch libc url
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            # Проверяем поддержку AVX2+BMI2 для оптимизированной сборки
            if [ -r /proc/cpuinfo ] && grep -q "avx2" /proc/cpuinfo 2>/dev/null && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
                arch="x86_64-v3"
            else
                arch="x86_64"
            fi ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "Архитектура не поддерживается: $arch" ;;
    esac
    ldd --version 2>&1 | grep -iq musl && libc="musl" || libc="gnu"
    [ "$ver" = "latest" ] \
        && url="https://github.com/${TELEMT_GITHUB_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
        || url="https://github.com/${TELEMT_GITHUB_REPO}/releases/download/${ver}/telemt-${arch}-linux-${libc}.tar.gz"
    info "Скачиваю telemt $ver (${arch}-linux-${libc})..."
    local tmp; tmp=$(mktemp -d)
    if ! curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null; then
        # Откат к стандартному x86_64 если v3 не найден
        if [ "$arch" = "x86_64-v3" ]; then
            warn "Сборка x86_64-v3 не найдена, откат к стандартной x86_64..."
            arch="x86_64"
            [ "$ver" = "latest" ] \
                && url="https://github.com/${TELEMT_GITHUB_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" \
                || url="https://github.com/${TELEMT_GITHUB_REPO}/releases/download/${ver}/telemt-${arch}-linux-${libc}.tar.gz"
            curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; die "Не удалось скачать бинарник."; }
        else
            rm -rf "$tmp"; die "Не удалось скачать бинарник."
        fi
    fi
    local extracted; extracted=$(find "$tmp" -type f -name "telemt" | head -1)
    [ -n "$extracted" ] || { rm -rf "$tmp"; die "Бинарник не найден в архиве."; }
    install -m 0755 "$extracted" "$TELEMT_BIN" && rm -rf "$tmp" \
        && ok "Установлен: $TELEMT_BIN" || { rm -rf "$tmp"; die "Не удалось установить бинарник."; }
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
use_middle_proxy = ${TELEMT_USE_ME:-true}
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
      # upstream-секция — только если задан SOCKS5
      if [ -n "${TELEMT_SOCKS5_ADDR:-}" ]; then
          echo ""
          echo "[[upstreams]]"
          echo "type    = \"socks5\""
          echo "address = \"${TELEMT_SOCKS5_ADDR}\""
          [ -n "${TELEMT_SOCKS5_USER:-}" ] && echo "username = \"${TELEMT_SOCKS5_USER}\""
          [ -n "${TELEMT_SOCKS5_PASS:-}" ] && echo "password = \"${TELEMT_SOCKS5_PASS}\""
      fi
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
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
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
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    working_dir: /run/telemt
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=1m
    ports:
      - "${port}:${port}/tcp"
      - "127.0.0.1:9091:9091/tcp"
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
    ulimits: {nofile: {soft: 65536, hard: 65536}}
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
EOF
}

# ── API: запрос с обработкой ошибок ──────────────────────────────
telemt_api() {
    local method="$1" path="$2" body="${3:-}"
    local url="http://127.0.0.1:9091${path}"
    if [ -n "$body" ]; then
        curl -s --max-time 10 -X "$method" -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null
    else
        curl -s --max-time 10 -X "$method" "$url" 2>/dev/null
    fi
}

telemt_api_ok() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null
}

telemt_api_error() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); e=d.get('error',{}); print(e.get('message','неизвестная ошибка'))" 2>/dev/null
}

# ── Путь к файлу накопленной статистики трафика ──────────────────
telemt_traffic_db_path() {
    if [ "${TELEMT_MODE:-}" = "docker" ]; then
        echo "${TELEMT_WORK_DIR_DOCKER}/traffic-usage.json"
    else
        echo "/var/lib/telemt/traffic-usage.json"
    fi
}

# ── Настройки сбора статистики (retention для IP истории) ─────────
telemt_menu_stats_settings() {
    local db
    db=$(telemt_traffic_db_path)
    local cur_ip_days cur_traffic_days
    read -r cur_ip_days cur_traffic_days < <(TELEMT_TRAFFIC_DB="$db" python3 -c "
import os, json
db=os.environ.get('TELEMT_TRAFFIC_DB','')
ip_days=30
traffic_days=90
if db and os.path.exists(db):
    try:
        with open(db,'r',encoding='utf-8') as f:
            d=json.load(f)
        s=d.get('settings',{}) if isinstance(d,dict) else {}
        ip_days=int(s.get('ip_retention_days',30) or 30)
        traffic_days=int(s.get('traffic_retention_days',90) or 90)
    except Exception:
        pass
if traffic_days not in (60, 90):
    traffic_days = 90
print(ip_days, traffic_days)
" 2>/dev/null || echo "30 90")
    [ -z "${cur_ip_days:-}" ] && cur_ip_days=30
    [ -z "${cur_traffic_days:-}" ] && cur_traffic_days=90

    header "Настройки сбора статистики"
    echo -e "  ${GRAY}Файл статистики:${NC} $db"
    echo -e "  ${GRAY}Хранить историю IP:${NC} ${cur_ip_days} дней"
    echo -e "  ${GRAY}Хранить трафик JSON:${NC} ${cur_traffic_days} дней (60/90)"
    echo ""
    local new_ip_days new_traffic_days
    read -rp "  Новый лимит IP дней [${cur_ip_days}]: " new_ip_days < /dev/tty
    new_ip_days="${new_ip_days:-$cur_ip_days}"
    if ! echo "$new_ip_days" | grep -qE '^[0-9]+$' || [ "$new_ip_days" -lt 1 ] || [ "$new_ip_days" -gt 3650 ]; then
        warn "Введите число от 1 до 3650"
        return 1
    fi
    read -rp "  Хранить трафик (только 60 или 90) [${cur_traffic_days}]: " new_traffic_days < /dev/tty
    new_traffic_days="${new_traffic_days:-$cur_traffic_days}"
    if [ "$new_traffic_days" != "60" ] && [ "$new_traffic_days" != "90" ]; then
        warn "Допустимо только 60 или 90"
        return 1
    fi

    TELEMT_TRAFFIC_DB="$db" TELEMT_IP_RETENTION_DAYS="$new_ip_days" TELEMT_TRAFFIC_RETENTION_DAYS="$new_traffic_days" python3 -c "
import os, json
from datetime import datetime, timezone, timedelta
db=os.environ.get('TELEMT_TRAFFIC_DB','')
ip_days=int(os.environ.get('TELEMT_IP_RETENTION_DAYS','30'))
traffic_days=int(os.environ.get('TELEMT_TRAFFIC_RETENTION_DAYS','90'))
if traffic_days not in (60, 90):
    traffic_days = 90
state={'users':{},'settings':{'ip_retention_days':ip_days, 'traffic_retention_days': traffic_days}}
if db and os.path.exists(db):
    try:
        with open(db,'r',encoding='utf-8') as f:
            loaded=json.load(f)
        if isinstance(loaded,dict):
            state.update(loaded)
    except Exception:
        pass
if 'users' not in state or not isinstance(state['users'],dict):
    state['users']={}
if 'settings' not in state or not isinstance(state['settings'],dict):
    state['settings']={}
state['settings']['ip_retention_days']=ip_days
state['settings']['traffic_retention_days']=traffic_days

ip_cutoff=datetime.now(timezone.utc)-timedelta(days=ip_days)
traffic_cutoff=datetime.now(timezone.utc)-timedelta(days=traffic_days)
for _,rec in list(state['users'].items()):
    hist=rec.get('ip_history',{})
    if not isinstance(hist,dict):
        rec['ip_history']={}
        continue
    new_hist={}
    for ip,val in hist.items():
        last=(val or {}).get('last_seen')
        keep=False
        if isinstance(last,str):
            try:
                dt=datetime.fromisoformat(last.replace('Z','+00:00'))
                keep=dt>=ip_cutoff
            except Exception:
                keep=False
        if keep:
            new_hist[ip]=val
    rec['ip_history']=new_hist

    daily=rec.get('daily',{})
    if isinstance(daily,dict):
        new_daily={}
        for dkey,dval in daily.items():
            try:
                ddt=datetime.fromisoformat(dkey+'T00:00:00+00:00')
                if ddt>=traffic_cutoff:
                    new_daily[dkey]=int(dval or 0)
            except Exception:
                continue
        rec['daily']=new_daily
state['updated_at']=datetime.now(timezone.utc).isoformat()
if db:
    os.makedirs(os.path.dirname(db), exist_ok=True)
    with open(db,'w',encoding='utf-8') as f:
        json.dump(state,f,ensure_ascii=False,indent=2)
" 2>/dev/null || { warn "Не удалось сохранить настройки"; return 1; }
    ok "Сохранено: IP $new_ip_days дн, трафик $new_traffic_days дн."
}

# ── Просмотр IP-истории пользователя ──────────────────────────────
telemt_menu_user_ips() {
    local db
    db=$(telemt_traffic_db_path)

    # Автообновление в лёгком режиме (1 попытка), чтобы IP подтягивались сами.
    telemt_fetch_links 1 >/dev/null 2>&1 || true

    [ -f "$db" ] || { warn "Статистика ещё не собрана: $db"; return 1; }

    local -a users=()
    while IFS= read -r u; do
        [ -n "$u" ] && users+=("$u")
    done < <(TELEMT_TRAFFIC_DB="$db" python3 -c "
import os, json
db=os.environ.get('TELEMT_TRAFFIC_DB','')
try:
    with open(db,'r',encoding='utf-8') as f:
        d=json.load(f)
    us=d.get('users',{})
    if isinstance(us,dict):
        for k,v in us.items():
            if isinstance(v,dict) and isinstance(v.get('ip_history',{}),dict) and v.get('ip_history'):
                print(k)
except Exception:
    pass
" 2>/dev/null || true)
    if [ ${#users[@]} -eq 0 ]; then
        warn "Нет сохранённой IP-истории."
        info "IP-история появляется, когда telemt API отдаёт active/recent IP списки."
        info "Если пользователь давно офлайн, IP может не вернуться в runtime API."
        return 1
    fi

    header "IP история — выбор пользователя"
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo ""
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    local ch
    read -rp "  Выбор: " ch < /dev/tty
    [[ "$ch" == "0" ]] && return 0
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"
        return 1
    fi
    local selected="${users[$((ch-1))]}"

    header "IP история: $selected"
    TELEMT_TRAFFIC_DB="$db" TELEMT_SELECTED_USER="$selected" python3 -c "
import os, json
db=os.environ.get('TELEMT_TRAFFIC_DB','')
user=os.environ.get('TELEMT_SELECTED_USER','')
try:
    with open(db,'r',encoding='utf-8') as f:
        d=json.load(f)
    rec=(d.get('users',{}) or {}).get(user,{})
    hist=rec.get('ip_history',{})
    rows=[]
    if isinstance(hist,dict):
        for ip,val in hist.items():
            if not isinstance(val,dict): val={}
            rows.append((ip,val.get('first_seen','—'),val.get('last_seen','—'),int(val.get('hits',0) or 0)))
    rows.sort(key=lambda x:(x[2],x[0]), reverse=True)
    if not rows:
        print('  IP-история пуста')
    else:
        print('  IP                      First seen                 Last seen                  Hits')
        print('  --------------------------------------------------------------------------------------')
        for ip,fs,ls,h in rows:
            print(f'  {ip:<22} {str(fs):<26} {str(ls):<26} {h}')
except Exception as e:
    print(f'  Ошибка чтения истории: {e}')
" 2>/dev/null
}

# ── Показ пользователей ───────────────────────────────────────────
telemt_fetch_links() {
    local attempts_max="${1:-15}"
    local attempt=0
    info "Запрашиваю данные через API..."
    while [ $attempt -lt "$attempts_max" ]; do
        local resp; resp=$(telemt_api GET "/v1/users" || true)
        if echo "$resp" | grep -q "tg://proxy"; then
            echo ""
            local traffic_db
            traffic_db=$(telemt_traffic_db_path)
            TELEMT_TRAFFIC_DB="$traffic_db" echo "$resp" | python3 -c "
import sys, json
import os
from datetime import datetime, timezone, timedelta
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; GRAY='\033[0;37m'; RESET='\033[0m'
def fmt_bytes(b):
    if not b: return '0 B'
    for u in ('B','KB','MB','GB','TB'):
        if b < 1024: return f'{b:.1f} {u}' if u != 'B' else f'{int(b)} B'
        b /= 1024
    return f'{b:.2f} PB'

db_path = os.environ.get('TELEMT_TRAFFIC_DB', '').strip()
state = {'users': {}, 'settings': {'ip_retention_days': 30, 'traffic_retention_days': 90}}
if db_path:
    try:
        with open(db_path, 'r', encoding='utf-8') as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                state = loaded
                if not isinstance(state.get('users'), dict):
                    state['users'] = {}
                if not isinstance(state.get('settings'), dict):
                    state['settings'] = {'ip_retention_days': 30, 'traffic_retention_days': 90}
    except Exception:
        state = {'users': {}, 'settings': {'ip_retention_days': 30, 'traffic_retention_days': 90}}

retention_days = int(state.get('settings', {}).get('ip_retention_days', 30) or 30)
if retention_days < 1:
    retention_days = 30
traffic_retention_days = int(state.get('settings', {}).get('traffic_retention_days', 90) or 90)
if traffic_retention_days not in (60, 90):
    traffic_retention_days = 90
now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=retention_days)

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
    oct   = int(u.get('total_octets') or 0)
    mc    = u.get('max_tcp_conns')
    mi    = u.get('max_unique_ips')
    q     = u.get('data_quota_bytes')
    exp   = u.get('expiration_rfc3339')

    rec = state['users'].get(name, {})
    last_raw = rec.get('last_raw')
    total_acc = int(rec.get('total_accumulated', 0) or 0)
    delta = 0
    if last_raw is None:
        total_acc = oct
        delta = oct
    else:
        try:
            last_raw = int(last_raw)
        except Exception:
            last_raw = 0
        delta = (oct - last_raw) if oct >= last_raw else oct
        total_acc += delta

    monthly = rec.get('monthly', {})
    if not isinstance(monthly, dict):
        monthly = {}
    mon_key = now.strftime('%Y-%m')
    monthly[mon_key] = int(monthly.get(mon_key, 0) or 0) + max(delta, 0)
    month_total = int(monthly.get(mon_key, 0) or 0)

    daily = rec.get('daily', {})
    if not isinstance(daily, dict):
        daily = {}
    day_key = now.strftime('%Y-%m-%d')
    daily[day_key] = int(daily.get(day_key, 0) or 0) + max(delta, 0)
    day_total = int(daily.get(day_key, 0) or 0)

    # Храним трафик в JSON только в пределах окна настроек (60/90 дней).
    daily_cutoff = now - timedelta(days=traffic_retention_days)
    daily_pruned = {}
    for dkey, dval in daily.items():
        try:
            ddt = datetime.fromisoformat(dkey + 'T00:00:00+00:00')
            if ddt >= daily_cutoff:
                daily_pruned[dkey] = int(dval or 0)
        except Exception:
            continue
    hist = rec.get('ip_history', {})
    if not isinstance(hist, dict):
        hist = {}

    seen_ips = set([ip for ip in (al or []) + (rl or []) if ip])
    for ip in seen_ips:
        ip_rec = hist.get(ip, {})
        first_seen = ip_rec.get('first_seen') or now.isoformat()
        hits = int(ip_rec.get('hits', 0) or 0) + 1
        hist[ip] = {
            'first_seen': first_seen,
            'last_seen': now.isoformat(),
            'hits': hits,
        }

    pruned = {}
    for ip, ip_rec in hist.items():
        last = (ip_rec or {}).get('last_seen')
        keep = False
        if isinstance(last, str):
            try:
                keep = datetime.fromisoformat(last.replace('Z', '+00:00')) >= cutoff
            except Exception:
                keep = False
        if keep:
            pruned[ip] = ip_rec

    state['users'][name] = {
        'last_raw': oct,
        'total_accumulated': total_acc,
        'ip_history': pruned,
        'monthly': monthly,
        'daily': daily_pruned
    }

    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}      {tls[0]}')
    print(f'{BOLD}│  Подключений:{RESET} {conns}' + (f' / {mc}' if mc else ''))
    print(f'{BOLD}│  Активных IP:{RESET} {aips}' + (f' / {mi}' if mi else ''))
    for ip in al: print(f'{BOLD}│{RESET}    {GREEN}▸ {ip}{RESET}')
    print(f'{BOLD}│  Недавних IP:{RESET} {rips}')
    print(f'{BOLD}│  Трафик:{RESET}')
    print(f'{BOLD}│    За сегодня:{RESET}    {fmt_bytes(day_total)}')
    print(f'{BOLD}│    В этом месяце:{RESET} {fmt_bytes(month_total)}')
    print(f'{BOLD}│    Всего:{RESET}        {fmt_bytes(total_acc)}')
    print(f'{BOLD}│    Сейчас (runtime):{RESET} {fmt_bytes(oct)}' + (f' / {fmt_bytes(q)}' if q else ''))
    if exp: print(f'{BOLD}│  Истекает:{RESET}    {exp}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()

state['settings']['ip_retention_days'] = retention_days
state['settings']['traffic_retention_days'] = traffic_retention_days
state['updated_at'] = now.isoformat()
if db_path:
    try:
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        with open(db_path, 'w', encoding='utf-8') as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except Exception:
        pass
" 2>/dev/null || echo "$resp"
            [ -n "$traffic_db" ] && info "Накопленная статистика: $traffic_db"
            return 0
        fi
        attempt=$((attempt+1)); sleep 2; echo -n "."
    done
    echo ""; warn "API не ответил. Попробуй: curl -s http://127.0.0.1:9091/v1/users"
    return 1
}

# ── Получить количество пользователей ────────────────────────────
telemt_user_count() {
    local resp; resp=$(telemt_api GET "/v1/users" 2>/dev/null || true)
    echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    users=d if isinstance(d,list) else d.get('data',d.get('users',[]))
    if isinstance(users,dict): users=list(users.values())
    print(len(users))
except: print('')
" 2>/dev/null || true
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
    local port; read -rp "Порт прокси [8443]: " port </dev/tty; port="${port:-8443}"
    ss -tlnp 2>/dev/null | grep -q ":${port} " && { warn "Порт $port занят!"; read -rp "Другой порт: " port </dev/tty; }
    local domain; read -rp "Домен-маскировка [petrovich.ru]: " domain </dev/tty; domain="${domain:-petrovich.ru}"
    echo ""; telemt_ask_users
    telemt_ask_upstream

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
    echo ""
    read -rp "  Нажмите Enter для продолжения..." < /dev/tty
}

# ── Добавить пользователя через API ──────────────────────────────
telemt_menu_add_user() {
    header "Добавить пользователя"
    [ "$TELEMT_MODE" = "systemd" ] && need_root
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден. Сначала выполни установку."
    telemt_is_running || die "Сервис не запущен. Запусти telemt и попробуй снова."

    local uname; read -rp "  Имя: " uname < /dev/tty
    [ -z "$uname" ] && die "Имя не может быть пустым"
    local secret; read -rp "  Секрет [Enter = сгенерировать]: " secret < /dev/tty
    [ -z "$secret" ] && { secret=$(gen_secret); ok "Секрет: $secret"; } \
        || echo "$secret" | grep -qE '^[0-9a-fA-F]{32}$' || die "Секрет должен быть 32 hex"

    echo ""; echo -e "${BOLD}Ограничения (Enter = пропустить):${RESET}"
    local mc mi qg ed
    read -rp "  Макс. подключений:    " mc < /dev/tty
    read -rp "  Макс. уникальных IP:  " mi < /dev/tty
    read -rp "  Квота трафика (ГБ):   " qg < /dev/tty
    read -rp "  Срок действия (дней): " ed < /dev/tty

    # Формируем JSON для API
    local body; body=$(python3 -c "
import json, sys
d = {'username': '$uname', 'secret': '$secret'}
mc='$mc'; mi='$mi'; qg='$qg'; ed='$ed'
if mc: d['max_tcp_conns'] = int(mc)
if mi: d['max_unique_ips'] = int(mi)
if qg: d['data_quota_bytes'] = int(float(qg) * 1024**3)
if ed:
    from datetime import datetime, timezone, timedelta
    dt = datetime.now(timezone.utc) + timedelta(days=int(ed))
    d['expiration_rfc3339'] = dt.strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(d))
" 2>/dev/null)

    info "Создаю пользователя через API..."
    local resp; resp=$(telemt_api POST "/v1/users" "$body")
    if telemt_api_ok "$resp"; then
        ok "Пользователь '$uname' добавлен"
        # Ждём появления ссылки в API (до 10 попыток)
        local tls_link="" attempt=0
        while [ $attempt -lt 10 ] && [ -z "$tls_link" ]; do
            sleep 1
            local user_resp; user_resp=$(telemt_api GET "/v1/users" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    users = data if isinstance(data, list) else data.get('users', data.get('data', []))
    if isinstance(users, dict): users = list(users.values())
    match = [u for u in users if u.get('username') == '${uname}']
    print(json.dumps(match[0]) if match else '{}')
except: print('{}')
" 2>/dev/null || true)
            tls_link=$(echo "$user_resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    tls = d.get('links', {}).get('tls', [])
    print(tls[0] if tls else '')
except: pass
" 2>/dev/null || true)
            attempt=$((attempt + 1))
        done
        echo ""
        if [ -n "$tls_link" ]; then
            echo -e "  ${BOLD}${WHITE}Ссылка:${NC}"
            echo -e "  ${CYAN}${tls_link}${NC}"
            echo ""
            if command -v qrencode &>/dev/null; then
                qrencode -t ANSIUTF8 "$tls_link" 2>/dev/null || true
            fi
        else
            warn "Ссылка не получена. Смотри: Пользователи → Пользователи и ссылки"
        fi
    else
        local errmsg; errmsg=$(telemt_api_error "$resp")
        die "Ошибка API: $errmsg"
    fi
}

# ── Удалить пользователя через API ───────────────────────────────
telemt_menu_delete_user() {
    header "Удалить пользователя"
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."
    telemt_is_running || die "Сервис не запущен."

    # Получаем список из API
    local resp; resp=$(telemt_api GET "/v1/users" || true)
    local -a users=()
    while IFS= read -r u; do
        [ -n "$u" ] && users+=("$u")
    done < <(echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    us=d if isinstance(d,list) else d.get('data',d.get('users',[]))
    if isinstance(us,dict): us=list(us.values())
    for u in us: print(u.get('username',''))
except: pass
" 2>/dev/null || true)

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя для удаления:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo ""
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

    info "Удаляю через API..."
    local dresp; dresp=$(telemt_api DELETE "/v1/users/${selected}")
    if telemt_api_ok "$dresp"; then
        ok "Пользователь '${selected}' удалён"
    else
        local errmsg; errmsg=$(telemt_api_error "$dresp")
        die "Ошибка API: $errmsg"
    fi
}

telemt_menu_links() {
    header "Пользователи и ссылки"
    telemt_is_running || die "Сервис не запущен."
    telemt_fetch_links
}

# ── Статус: systemctl + данные из API ────────────────────────────
telemt_menu_status() {
    header "Статус"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        systemctl status telemt --no-pager || true
        echo ""

        # Блок из API если запущен
        if telemt_is_running; then
            local summary; summary=$(telemt_api GET "/v1/stats/summary" 2>/dev/null || true)
            local gates;   gates=$(telemt_api GET "/v1/runtime/gates" 2>/dev/null || true)
            local sysinfo; sysinfo=$(telemt_api GET "/v1/system/info" 2>/dev/null || true)

            echo "$summary $gates $sysinfo" | python3 -c "
import sys, json, os

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
GRAY='\033[0;90m'; YELLOW='\033[1;33m'; RESET='\033[0m'

raw = sys.stdin.read().strip()
# три отдельных JSON через пробел — разбираем каждый
parts = []
depth = 0; buf = ''
for ch in raw:
    if ch == '{': depth += 1
    if depth > 0: buf += ch
    if ch == '}':
        depth -= 1
        if depth == 0:
            try: parts.append(json.loads(buf))
            except: pass
            buf = ''

def get(d, *keys):
    for k in keys:
        if isinstance(d, dict): d = d.get(k, {})
        else: return None
    return d if d != {} else None

sm = parts[0].get('data', {}) if len(parts) > 0 else {}
gt = parts[1].get('data', {}) if len(parts) > 1 else {}
si = parts[2].get('data', {}) if len(parts) > 2 else {}

def fmt_uptime(s):
    if not s: return '—'
    s = int(s)
    d, s = divmod(s, 86400); h, s = divmod(s, 3600); m, s = divmod(s, 60)
    parts = []
    if d: parts.append(f'{d}д')
    if h: parts.append(f'{h}ч')
    if m: parts.append(f'{m}м')
    if not parts: parts.append(f'{s}с')
    return ' '.join(parts)

version    = si.get('version', '')
uptime     = fmt_uptime(sm.get('uptime_seconds'))
conns      = sm.get('connections_total', '—')
bad_conns  = sm.get('connections_bad_total', 0)
users      = sm.get('configured_users', '—')
me_ready   = gt.get('me_runtime_ready')
startup    = gt.get('startup_status', '')
use_me     = gt.get('use_middle_proxy')

print(f'  {GRAY}────────────────────────────────────────{RESET}')
if version:    print(f'  {GRAY}Версия         {RESET}{version}')
print(         f'  {GRAY}Uptime         {RESET}{uptime}')
print(         f'  {GRAY}Подключений    {RESET}{conns}' + (f'  {GRAY}(плохих: {bad_conns}){RESET}' if bad_conns else ''))
print(         f'  {GRAY}Пользователей  {RESET}{users}')
if use_me is not None:
    mode_str = 'middle-proxy' if use_me else 'direct'
    print(     f'  {GRAY}Режим          {RESET}{mode_str}')
if me_ready is not None:
    status_str = f'{GREEN}готов{RESET}' if me_ready else f'{YELLOW}инициализация{RESET}'
    if startup: status_str += f'  {GRAY}({startup}){RESET}'
    print(     f'  {GRAY}ME Pool        {RESET}{status_str}')
print(f'  {GRAY}────────────────────────────────────────{RESET}')
" 2>/dev/null || true
            echo ""
        fi

        info "Последние логи (важное):"
        telemt_show_logs important
    else
        cd "$TELEMT_WORK_DIR_DOCKER" 2>/dev/null || die "Директория не найдена"
        docker compose ps; echo ""; info "Последние логи:"; docker compose logs --tail=20
    fi
}

# ── Вывод логов: important | full ────────────────────────────────
_telemt_color_logs() {
    sed \
        -e 's/\(WARN\)/\o033[1;33m\1\o033[0m/g' \
        -e 's/\(ERROR\)/\o033[0;31m\1\o033[0m/g' \
        -e 's/\(INFO\)/\o033[0;36m\1\o033[0m/g' \
        -e 's/\(tg:\/\/proxy[^ ]*\)/\o033[0;32m\1\o033[0m/g'
}

_TELEMT_NOISE="middle_proxy::health\|middle_proxy::handshake\|ME key derivation\|RPC handshake OK\|Idle writer"

telemt_show_logs() {
    local mode="${1:-important}"
    if [ "$mode" = "full" ]; then
        journalctl -u telemt --no-pager -n 60 --output=cat 2>/dev/null \
            | _telemt_color_logs \
            || journalctl -u telemt --no-pager -n 60 | _telemt_color_logs
    else
        journalctl -u telemt --no-pager -n 300 --output=cat 2>/dev/null \
            | grep -v "$_TELEMT_NOISE" | tail -40 | _telemt_color_logs \
            || journalctl -u telemt --no-pager -n 300 \
            | grep -v "$_TELEMT_NOISE" | tail -40 | _telemt_color_logs
    fi
}

telemt_menu_logs() {
    while true; do
        clear
        header "Логи telemt"
        echo -e "  ${BOLD}1)${RESET} 🔍  Важное  ${GRAY}(фильтр ME-шума, последние 40 событий)${RESET}"
        echo -e "  ${BOLD}2)${RESET} 📜  Полные  ${GRAY}(все строки, последние 60)${RESET}"
        echo -e "  ${BOLD}3)${RESET} 🔄  Follow  ${GRAY}(live, Ctrl+C для выхода)${RESET}"
        echo ""
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) echo ""; telemt_show_logs important; echo ""
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) echo ""; telemt_show_logs full; echo ""
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            3) echo ""; journalctl -u telemt -f --output=cat 2>/dev/null \
                   | _telemt_color_logs \
                   || journalctl -u telemt -f | _telemt_color_logs || true
               echo ""; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

telemt_menu_toggle_me() {
    header "Режим подключения к Telegram"
    [ ! -f "$TELEMT_CONFIG_FILE" ] && die "Конфиг не найден."

    local current; current=$(grep -E "^use_middle_proxy" "$TELEMT_CONFIG_FILE" | grep -o 'true\|false' || echo "true")
    if [ "$current" = "true" ]; then
        echo -e "  Текущий режим: ${GREEN}Middle-Proxy (ME)${NC}"
        echo -e "  ${GRAY}Трафик идёт через серверы Telegram. Стабильнее, но чуть медленнее.${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Переключить на Direct  ${GRAY}(прямое подключение к DC)${NC}"
    else
        echo -e "  Текущий режим: ${CYAN}Direct${NC}"
        echo -e "  ${GRAY}Прямое подключение к DC Telegram. Быстрее, но зависит от доступности DC.${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Переключить на ME  ${GRAY}(через Middle-Proxy серверы Telegram)${NC}"
    fi
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1)
            local new_val; [ "$current" = "true" ] && new_val="false" || new_val="true"
            sed -i "s/^use_middle_proxy.*/use_middle_proxy = $new_val/" "$TELEMT_CONFIG_FILE"
            if [ "$TELEMT_MODE" = "systemd" ]; then
                systemctl restart telemt && ok "Сервис перезапущен с новым режимом" || warn "Ошибка перезапуска"
            else
                cd "$TELEMT_WORK_DIR_DOCKER" && docker compose restart && ok "Контейнер перезапущен" || warn "Ошибка"
            fi
            local new_mode; [ "$new_val" = "true" ] && new_mode="Middle-Proxy (ME)" || new_mode="Direct"
            ok "Режим переключён на: $new_mode"
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

telemt_menu_update() {
    header "Обновление"
    if [ "$TELEMT_MODE" = "systemd" ]; then
        need_root
        info "Текущая версия: $($TELEMT_BIN --version 2>/dev/null || echo неизвестна)"
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

    ok "Установка завершена!"
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
    RSCP() { sshpass -p "$_SSH_PASS" scp -P "$_SSH_PORT" \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$1" "${_SSH_USER}@${_SSH_IP}:$2"; }
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

# ── Главное меню ──────────────────────────────────────────────────
telemt_main_menu() {
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

        # Пункт Пользователи с количеством если сервис запущен
        local user_count=""
        if telemt_is_running 2>/dev/null; then
            user_count=$(telemt_user_count 2>/dev/null || true)
        fi
        if [ -n "$user_count" ]; then
            echo -e "  ${BOLD}3)${RESET} 👥  Пользователи  ${GRAY}${user_count}${NC}"
        else
            echo -e "  ${BOLD}3)${RESET} 👥  Пользователи"
        fi

        echo -e "  ${BOLD}4)${RESET} 📦  Миграция на другой сервер"
        echo -e "  ${BOLD}5)${RESET} 🔀  Сменить режим (systemd ↔ Docker)"
        echo -e "  ${BOLD}6)${RESET} 🗑️   Удалить / Переустановить"
        echo ""
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
            6) telemt_menu_uninstall || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

telemt_submenu_manage() {
    while true; do
        clear
        header "MTProxy — Управление"
        echo -e "  ${BOLD}1)${RESET} 📊  Статус"
        echo -e "  ${BOLD}2)${RESET} 📋  Логи"
        echo -e "  ${BOLD}3)${RESET} 🔄  Обновить"
        echo -e "  ${BOLD}4)${RESET} ⏹️  Остановить"
        echo -e "  ${BOLD}5)${RESET} ▶️   Запустить / Перезапустить"
        echo -e "  ${BOLD}6)${RESET} 🔀  Режим ME / Direct"
        echo ""
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) telemt_menu_status || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) telemt_menu_logs || true ;;
            3) telemt_menu_update || true ;;
            4) telemt_menu_stop || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            5) if [ "$TELEMT_MODE" = "systemd" ]; then
                   systemctl restart telemt && ok "Сервис перезапущен" || warn "Ошибка перезапуска"
               else
                   cd "$TELEMT_WORK_DIR_DOCKER" && docker compose restart && ok "Контейнер перезапущен" || warn "Ошибка"
               fi
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            6) telemt_menu_toggle_me || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ── Удаление / Переустановка ──────────────────────────────────────
telemt_menu_uninstall() {
    header "Удаление / Переустановка MTProxy"
    echo ""
    echo -e "  ${BOLD}1)${RESET} 🔁  Переустановить (сохранить конфиг и пользователей)"
    echo -e "  ${BOLD}2)${RESET} 🗑️   Удалить полностью"
    echo ""
    echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1)
            info "Переустановка с сохранением данных..."
            local bak="/tmp/telemt_config_backup_$(date +%Y%m%d_%H%M%S).toml"
            [ -f "$TELEMT_CONFIG_FILE" ] && cp "$TELEMT_CONFIG_FILE" "$bak" && info "Конфиг сохранён: $bak"
            if [ "$TELEMT_MODE" = "systemd" ]; then
                systemctl stop telemt 2>/dev/null || true
                telemt_pick_version
                telemt_download_binary "$TELEMT_CHOSEN_VERSION"
                [ -f "$bak" ] && cp "$bak" "$TELEMT_CONFIG_FILE"
                systemctl start telemt && ok "telemt перезапущен"
            else
                cd "$TELEMT_WORK_DIR_DOCKER"
                docker compose pull -q && docker compose up -d
                ok "Контейнер обновлён"
            fi
            ;;
        2)
            warn "Это удалит telemt, конфиг и всех пользователей!"
            local yn; read -rp "  Продолжить? Введите 'YES': " yn < /dev/tty
            [ "$yn" != "YES" ] && { info "Отменено"; return; }
            if [ "$TELEMT_MODE" = "systemd" ]; then
                systemctl stop telemt 2>/dev/null || true
                systemctl disable telemt 2>/dev/null || true
                rm -f "$TELEMT_SERVICE_FILE"
                systemctl daemon-reload 2>/dev/null || true
                rm -f "$TELEMT_BIN"
                rm -rf "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
                userdel telemt 2>/dev/null || true
            else
                cd "$TELEMT_WORK_DIR_DOCKER" && docker compose down -v --rmi all 2>/dev/null || true
                rm -rf "$TELEMT_WORK_DIR_DOCKER"
            fi
            command -v ufw &>/dev/null && {
                local port; port=$(grep -E "^port\s*=" "$TELEMT_CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")
                [ -n "$port" ] && ufw delete allow "${port}/tcp" &>/dev/null || true
            }
            ok "telemt удалён"
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    read -rp "  Нажмите Enter для продолжения..." < /dev/tty
}

# ── Подменю пользователей с количеством ──────────────────────────
telemt_submenu_users() {
    while true; do
        # Получаем количество пользователей для заголовка
        local user_count=""
        if telemt_is_running 2>/dev/null; then
            user_count=$(telemt_user_count 2>/dev/null || true)
        fi

        clear
        echo ""
        echo -e "${BOLD}${WHITE}  MTProxy — Пользователи${NC}" \
            $([ -n "$user_count" ] && echo -e "${GRAY}  ${user_count}${NC}" || true)
        echo -e "${GRAY}  ────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} ➕  Добавить пользователя"
        echo -e "  ${BOLD}2)${RESET} ➖  Удалить пользователя"
        echo -e "  ${BOLD}3)${RESET} 👥  Пользователи и ссылки"
        echo -e "  ${BOLD}4)${RESET} 🌐  IP история пользователя"
        echo -e "  ${BOLD}5)${RESET} ⚙️  Настройки сбора (трафик/IP)"
        echo ""
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) telemt_menu_add_user || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) telemt_menu_delete_user || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            3) telemt_menu_links || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            4) telemt_menu_user_ips || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            5) telemt_menu_stats_settings || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
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
