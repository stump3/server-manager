# shellcheck shell=bash
# common/core.sh — global settings/version state, UI prompts, root checks

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
SCRIPT_VERSION_STATIC="v2608.120218"
SCRIPT_VERSION="$SCRIPT_VERSION_STATIC"

# UI primitives are loaded from lib/ui/output.sh before this module.

# ── Runtime-selected Telemt state ───────────────────────────────
# Shared immutable paths/API are loaded from lib/core/config.sh before this module.
TELEMT_MODE=""
TELEMT_CONFIG_FILE=""
TELEMT_WORK_DIR=""
TELEMT_CHOSEN_VERSION="latest"

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
