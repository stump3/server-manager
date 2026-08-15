# shellcheck shell=bash
# common/menu.sh — main application menu


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
