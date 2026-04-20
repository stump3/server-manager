# ╔══════════════════════════════════════════════════════════════════╗
# ║  🛠️  SERVER-MANAGER — VPN Server Management Script                ║
# ║                                                                  ║
# ║  Компоненты:                                                     ║
# ║  • Remnawave Panel  — VPN-панель (eGames архитектура)            ║
# ║  • MTProxy (telemt) — Telegram MTProto прокси (Rust)             ║
# ║  • Hysteria2        — высокоскоростной VPN (QUIC/UDP)            ║
# ║                                                                  ║
# ║  Версия: определяется автоматически из даты изменения файла     ║
# ║  Использование: bash setup.sh                                    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Версия обновляется автоматически через GitHub Actions (update-version.yml)
# при каждом push в main. Не редактировать вручную.
SCRIPT_VERSION_STATIC="v2604.202037"
SCRIPT_VERSION="$SCRIPT_VERSION_STATIC"

# ═══════════════════════════════════════════════════════════════════
# ЦВЕТА И ОБЩИЕ УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
PURPLE='\033[0;35m'; GRAY='\033[0;90m'; BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'; RESET="$NC"

# ── Глобальные пути и переменные ────────────────────────────────
PANEL_MGMT_SCRIPT="/usr/local/bin/remnawave_panel"

# Hysteria2
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_SVC="hysteria-server"

# Telemt (полные объявления — используются в get_telemt_version и migrate)
TELEMT_BIN="/usr/local/bin/telemt"
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG_SYSTEMD="/etc/telemt/telemt.toml"
TELEMT_WORK_DIR_SYSTEMD="/opt/telemt"
TELEMT_TLSFRONT_DIR="/opt/telemt/tlsfront"
TELEMT_SERVICE_FILE="/etc/systemd/system/telemt.service"
TELEMT_WORK_DIR_DOCKER="${HOME}/mtproxy"
TELEMT_CONFIG_DOCKER="${HOME}/mtproxy/telemt.toml"
TELEMT_COMPOSE_FILE="${HOME}/mtproxy/docker-compose.yml"
TELEMT_GITHUB_REPO="telemt/telemt"
TELEMT_API_URL="http://127.0.0.1:9091/v1/users"
TELEMT_MODE=""
TELEMT_CONFIG_FILE=""
TELEMT_WORK_DIR=""
TELEMT_CHOSEN_VERSION="latest"

ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
info()    { echo -e "${BLUE}  · $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()     { echo -e "\n${RED}  ✗  $*${NC}\n"; exit 1; }
die()     { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
detail()  { echo -e "${GRAY}    $*${NC}"; }

# Шаг установки с прогресс-баром
# Использует STEP_NUM и TOTAL_STEPS если заданы
step() {
    echo ""
    if [ -n "${TOTAL_STEPS:-}" ] && [ "${TOTAL_STEPS:-0}" -gt 0 ]; then
        local _done=$(( STEP_NUM ))
        local _left=$(( TOTAL_STEPS - STEP_NUM ))
        local _bar=""
        local i
        for (( i=0; i<_done; i++ )); do _bar+="●"; done
        for (( i=0; i<_left; i++ )); do _bar+="○"; done
        echo -e "${GRAY}  ${_bar}  ${BOLD}${CYAN}$*${NC}"
    else
        echo -e "${BOLD}${CYAN}  ── $* ──${NC}"
    fi
    echo ""
}

# Заголовок раздела (подменю)
header() {
    clear
    echo ""
    echo -e "${BOLD}${WHITE}  $*${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────${NC}"
    echo ""
}

# Секция внутри экрана (без clear)
section() {
    echo ""
    echo -e "${BOLD}${WHITE}  $*${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
}

confirm() {
    # confirm "Вопрос"        — без default, требует y/n
    # confirm "Вопрос" y      — default Y (Enter = да)
    # confirm "Вопрос" n      — default N (Enter = нет)
    local prompt="$1" default="${2:-}"
    local hint
    case "$default" in
        y|Y) hint="[Y/n]" ;;
        n|N) hint="[y/N]" ;;
        *)   hint="[y/n]" ;;
    esac
    while true; do
        read -rp "  $prompt $hint: " r < /dev/tty
        r="${r:-$default}"
        case "$r" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *)   [ -z "$r" ] || warn "Введите y или n" ;;
        esac
    done
}

ask() {
    local var="$1" prompt="$2" default="${3:-}" val=""
    while true; do
        [ -n "$default" ] \
            && read -p "  ${prompt} [${default}]: " val < /dev/tty \
            || read -p "  ${prompt}: " val < /dev/tty
        val="${val:-$default}"
        [ -n "$val" ] && break
        warn "Поле обязательно"
    done
    printf -v "$var" "%s" "$val"
    # export убран — загрязнял окружение всех дочерних процессов.
    # Переменная доступна в вызывающем контексте через printf -v.
}

check_root()    { [ "$EUID" -ne 0 ] && err "Запустите от root: sudo bash $0" || true; }
need_root()     { [ "$(id -u)" -eq 0 ] || die "Эта операция требует прав root."; }
gen_secret()    { openssl rand -hex 16; }
gen_hex64()     { openssl rand -base64 96 | tr -dc 'a-zA-Z0-9' | head -c 64; }
gen_password()  {
    local p=""
    p+=$(tr -dc 'A-Z'    </dev/urandom | head -c 1)
    p+=$(tr -dc 'a-z'    </dev/urandom | head -c 1)
    p+=$(tr -dc '0-9'    </dev/urandom | head -c 1)
    p+=$(tr -dc '!@#%^&*' </dev/urandom | head -c 3)
    p+=$(tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 18)
    echo "$p" | fold -w1 | shuf | tr -d '\n'
}
gen_user()      { tr -dc 'a-zA-Z' </dev/urandom | head -c 8; }

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

check_dns() {
    local domain="$1" server_ip domain_ip
    server_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    domain_ip=$(dig +short -t A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -z "$server_ip" ] && { warn "Не удалось определить IP сервера"; return 1; }
    [ -z "$domain_ip" ] && { warn "A-запись для $domain не найдена"; return 1; }
    [ "$server_ip" != "$domain_ip" ] && { warn "$domain → $domain_ip, сервер → $server_ip"; return 1; }
    ok "DNS $domain → $domain_ip ✓"
    return 0
}

spinner() {
    local pid=$1 text="${2:-Подождите...}" spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' delay=0.1
    printf "${YELLOW}%s${NC}" "$text" > /dev/tty
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r${YELLOW}[%s] %s${NC}" "${spinstr:$i:1}" "$text" > /dev/tty
            sleep $delay
        done
    done
    printf "\r\033[K" > /dev/tty
}

# Установка sshpass (нужна для migrate в обоих разделах)
ensure_sshpass() {
    command -v sshpass &>/dev/null && return 0
    info "Установка sshpass..."
    apt-get install -y -q sshpass 2>/dev/null || \
        yum install -y sshpass 2>/dev/null || \
        die "Не удалось установить sshpass. Установи вручную: apt install sshpass"
    ok "sshpass установлен"
}


# ── SSH-миграция: ввод данных ─────────────────────────────────────
# Результат записывается в переменные: _SSH_IP _SSH_PORT _SSH_USER _SSH_PASS
ask_ssh_target() {
    # Восстанавливаем эхо терминала при выходе (на случай прерывания после read -rsp)
    trap 'stty echo 2>/dev/null || true' RETURN
    while true; do
        read -rp "  IP нового сервера: " _SSH_IP < /dev/tty
        [[ "$_SSH_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        warn "Неверный формат IP"
    done
    read -rp "  SSH-порт [22]: "         _SSH_PORT < /dev/tty; _SSH_PORT="${_SSH_PORT:-22}"
    read -rp "  Пользователь [root]: "   _SSH_USER < /dev/tty; _SSH_USER="${_SSH_USER:-root}"
    while true; do
        stty -echo 2>/dev/null || true
        read -rp "  Пароль SSH: " _SSH_PASS < /dev/tty
        stty echo 2>/dev/null || true
        echo ""
        [ -n "$_SSH_PASS" ] && break
        warn "Пароль не может быть пустым"
    done
    export _SSH_IP _SSH_PORT _SSH_USER _SSH_PASS
}

# ── SSH-миграция: инициализация хелперов RUN/PUT ──────────────────
# init_ssh_helpers [panel|telemt|hysteria|full]
#   panel/full  — StrictHostKeyChecking=no, BatchMode=no  (RUN + PUT)
#   telemt      — StrictHostKeyChecking=accept-new        (RUN + PUT, те же RUN/PUT)
#   hysteria    — StrictHostKeyChecking=no, порт явно     (RUN + PUT)
# После вызова доступны: RUN "cmd", PUT src dst
init_ssh_helpers() {
    local mode="${1:-panel}"
    local strict_opt
    case "$mode" in
        telemt) strict_opt="StrictHostKeyChecking=accept-new" ;;
        *)      strict_opt="StrictHostKeyChecking=no" ;;
    esac
    _SSH_OPTS="-p $_SSH_PORT -o $strict_opt -o ConnectTimeout=10"
    [ "$mode" != "telemt" ] && _SSH_OPTS="$_SSH_OPTS -o BatchMode=no"

    # shellcheck disable=SC2139
    RUN() { sshpass -p "$_SSH_PASS" ssh  $_SSH_OPTS "${_SSH_USER}@${_SSH_IP}" "$@"; }
    PUT() { sshpass -p "$_SSH_PASS" scp -rp $_SSH_OPTS "$@"; }
    export -f RUN PUT 2>/dev/null || true
}

# ── SSH-миграция: проверка подключения ────────────────────────────
check_ssh_connection() {
    RUN "echo ok" >/dev/null 2>&1         || { warn "Не удалось подключиться к ${_SSH_IP}:${_SSH_PORT}"; return 1; }
    ok "SSH соединение установлено"
}

# ── Remote: установка зависимостей ───────────────────────────────
# remote_install_deps [panel|full]
#   panel — base (без qrencode/unzip/cron, без /etc/hysteria)
#   full  — base + unzip cron qrencode + /etc/hysteria
remote_install_deps() {
    local variant="${1:-panel}"
    local extra_pkgs="" extra_dirs=""
    if [ "$variant" = "full" ]; then
        extra_pkgs=" unzip cron qrencode"
        extra_dirs=" /etc/hysteria"
    fi

    # ── Показываем что будет выполнено и просим подтверждение ─────
    echo ""
    warn "На сервере ${_SSH_IP} будут выполнены следующие действия:"
    echo ""
    echo "  · apt-get update && apt-get install (curl, docker-deps, certbot...)"
    echo "  · Установка Docker (если не установлен)"
    echo "  · Создание swap-файла 2 GB (если нет)"
    echo "  · Включение BBR (sysctl)"
    echo "  · Открытие портов 22/tcp и 443/tcp в UFW"
    [ "$variant" = "full" ] && echo "  · Установка qrencode, unzip, cron"
    echo ""
    if ! confirm "Продолжить установку зависимостей на ${_SSH_IP}?" y; then
        warn "Отменено пользователем"
        return 1
    fi

    info "Устанавливаем зависимости на новом сервере..."
    RUN bash -s << RDEPS
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q 2>/dev/null
apt-get install -y -q curl wget git jq openssl ca-certificates gnupg dnsutils \
    certbot python3-certbot-dns-cloudflare sshpass${extra_pkgs} 2>/dev/null
command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; systemctl enable docker >/dev/null 2>&1; } # intentional: official Docker installer
[ ! -f /swapfile ] && { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }
grep -q "bbr" /etc/sysctl.conf 2>/dev/null || {
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}
ufw allow 22/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
mkdir -p /opt/remnawave /var/www/html /etc/letsencrypt /etc/ssl/certs/hysteria${extra_dirs}
RDEPS
    ok "Зависимости установлены"
}

# API-запросы к Remnawave
panel_api() {
    local method="$1" url="$2" token="${3:-}" data="${4:-}"
    local headers=(
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: 127.0.0.1"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )
    [ -n "$token" ] && headers+=(-H "Authorization: Bearer $token")
    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s -X "$method" "$url" "${headers[@]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════

# ГЛАВНОЕ МЕНЮ
# ═══════════════════════════════════════════════════════════════════

_main_menu_refresh_status() {
    # Собираем все данные за один вызов docker ps (7ms с точным фильтром)
    # Синхронно — версии видны сразу при входе и после возврата из подменю
    local rw_ver hy_ver ps_out

    # docker ps один раз для всех контейнеров (~10ms)
    ps_out=$(docker ps --format "{{.Names}}" 2>/dev/null || true)

    # Версии параллельно через temp-файлы (~15ms вместо 30ms последовательно)
    # ЗАВИСИМОСТЬ: get_remnawave_version и get_hysteria_version объявлены в lib/panel.sh
    # panel.sh должен быть загружен до вызова main_menu
    local _f_rw _f_hy
    _f_rw=$(mktemp /tmp/.sm_rw_XXXX); _f_hy=$(mktemp /tmp/.sm_hy_XXXX)
    { get_remnawave_version 2>/dev/null > "$_f_rw"; } &
    { get_hysteria_version  2>/dev/null > "$_f_hy"; } &
    wait
    rw_ver=$(cat "$_f_rw" 2>/dev/null || true)
    hy_ver=$(cat "$_f_hy" 2>/dev/null || true)
    rm -f "$_f_rw" "$_f_hy"

    # ── Remnawave Panel ──────────────────────────────────────────
    if echo "$ps_out" | grep -q "^remnawave$"; then
        _PANEL_STATUS="${GREEN}●${NC} запущена${rw_ver:+  ${GRAY}${rw_ver#v}${NC}}"
    elif [ -d /opt/remnawave ]; then
        _PANEL_STATUS="${YELLOW}◐${NC} остановлена"
    else
        _PANEL_STATUS="${GRAY}○ не установлена${NC}"
    fi

    # ── MTProxy ──────────────────────────────────────────────────
    if systemctl is-active --quiet telemt 2>/dev/null; then
        _TELEMT_STATUS="${GREEN}●${NC} запущен (systemd)"
    elif echo "$ps_out" | grep -q "^telemt$"; then
        _TELEMT_STATUS="${GREEN}●${NC} запущен (Docker)"
    elif [ -f "$TELEMT_CONFIG_SYSTEMD" ] || [ -f "$TELEMT_CONFIG_DOCKER" ]; then
        _TELEMT_STATUS="${YELLOW}◐${NC} остановлен"
    else
        _TELEMT_STATUS="${GRAY}○ не установлен${NC}"
    fi

    # ── Hysteria2 ────────────────────────────────────────────────
    if hy_is_running 2>/dev/null; then
        _HYSTERIA_STATUS="${GREEN}●${NC} запущена${hy_ver:+  ${GRAY}${hy_ver#v}${NC}}"
    elif hy_is_installed 2>/dev/null; then
        _HYSTERIA_STATUS="${YELLOW}◐${NC} остановлена"
    else
        _HYSTERIA_STATUS="${GRAY}○ не установлена${NC}"
    fi
}

main_menu() {
    # Загружаем статусы и версии синхронно при входе
    _main_menu_refresh_status
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${PURPLE}  SERVER-MANAGER${NC}${GRAY}  ${SCRIPT_VERSION}${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        echo ""
        printf "  %-9s %b\n" "Remnawave" "$(echo -e "$_PANEL_STATUS")"
        printf "  %-9s %b\n" "MTProxy"   "$(echo -e "$_TELEMT_STATUS")"
        printf "  %-9s %b\n" "Hysteria2" "$(echo -e "$_HYSTERIA_STATUS")"
        echo ""
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET}  🛡️  Remnawave"
        echo -e "  ${BOLD}2)${RESET}  📡  MTProxy (telemt)"
        echo -e "  ${BOLD}3)${RESET}  🚀  Hysteria2"
        echo ""
        echo -e "  ${BOLD}4)${RESET}  📦  Перенос"
        echo ""
        echo -e "  ${BOLD}5)${RESET}  🔄  Обновить скрипт"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  Выход"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_menu || true ;;
            2) telemt_section || true ;;
            3) hysteria_menu || true ;;
            4) migrate_menu || true ;;
            5) panel_update_script || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) exit 0 ;;
            *) warn "Неверный выбор" ;;
        esac
        # Запускаем фоновое обновление статуса
        _main_menu_refresh_status
    done
}
