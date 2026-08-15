# shellcheck shell=bash
# telemt/core.sh — глобальные переменные, определение режима, зависимости, версии, telemt_section

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
