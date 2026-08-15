# shellcheck shell=bash

# ── Remnawave CLI ─────────────────────────────────────────────────
panel_cli() {
    header "Remnawave CLI"
    info "Запуск интерактивного CLI панели..."
    docker exec -it remnawave remnawave || warn "Не удалось запустить CLI. Панель запущена?"
    read -rp "Enter..." < /dev/tty
}

panel_menu() {
    local ver panel_domain
    ver=$(get_remnawave_version 2>/dev/null || true)
    panel_domain=""
    [ -f /opt/remnawave/.env ] && panel_domain=$(awk -F= '/^FRONT_END_DOMAIN=/{gsub(/"/, "", $2); print $2; exit}' /opt/remnawave/.env 2>/dev/null || true)
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  🛡️  Remnawave Panel${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        if [ -n "$ver" ] || [ -n "$panel_domain" ]; then
            [ -n "$ver" ]          && echo -e "  ${GRAY}Версия  ${NC}${ver}"
            [ -n "$panel_domain" ] && echo -e "  ${GRAY}Домен   ${NC}${panel_domain}"
            echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  🔧  Установка"
        echo -e "  ${BOLD}2)${RESET}  ⚙️  Управление"
        echo -e "  ${BOLD}3)${RESET}  🌐  WARP Native"
        echo -e "  ${BOLD}4)${RESET}  🎨  Страница подписки"
        echo -e "  ${BOLD}5)${RESET}  🖼️  Selfsteal шаблон"
        echo -e "  ${BOLD}6)${RESET}  📦  Миграция на другой сервер"
        echo -e "  ${BOLD}7)${RESET}  🗑️  Удалить панель"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_submenu_install || true ;;
            2) panel_submenu_manage || true ;;
            3) panel_warp_menu || true ;;
            4) panel_subpage_menu || true ;;
            5) panel_template_menu || true ;;
            6) { [ -x "$PANEL_MGMT_SCRIPT" ] && "$PANEL_MGMT_SCRIPT" migrate || warn "Панель не установлена."; } || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            7) panel_remove || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
        ver=$(get_remnawave_version 2>/dev/null || true)
    done
}

panel_submenu_install() {
    clear
    header "Remnawave Panel — Установка"
    echo -e "  ${BOLD}1)${RESET} 🆕  Установить"
    echo -e "  ${BOLD}2)${RESET} 💣  Переустановить (сброс всех данных!)"
    echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1) panel_install ;;
        2) panel_reinstall ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

panel_submenu_manage() {
    while true; do
        clear
        header "Remnawave Panel — Управление"
        echo -e "  ${BOLD}1)${RESET} 📋  Логи"
        echo -e "  ${BOLD}2)${RESET} 📊  Статус"
        echo -e "  ${BOLD}3)${RESET} 🔄  Перезапустить"
        echo -e "  ${BOLD}4)${RESET}  ▶️  Старт"
        echo -e "  ${BOLD}5)${RESET} 📦  Обновить"
        echo -e "  ${BOLD}6)${RESET} 🔒  SSL"
        echo -e "  ${BOLD}7)${RESET} 💾  Бэкап"
        echo -e "  ${BOLD}8)${RESET} 🏥  Диагноз"
        echo -e "  ${BOLD}9)${RESET} 🔓  Открыть порт 8443"
        echo -e " ${BOLD}10)${RESET} 🔐  Закрыть порт 8443"
        echo -e " ${BOLD}11)${RESET} 💻  Remnawave CLI"
        echo -e " ${BOLD}12)${RESET} 🔧  Переустановить скрипт (rp)"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        [ -x "$PANEL_MGMT_SCRIPT" ] || { warn "Панель не установлена."; return; }
        case "$ch" in
        1)  "$PANEL_MGMT_SCRIPT" logs ;;
        2)  "$PANEL_MGMT_SCRIPT" status; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        3)  "$PANEL_MGMT_SCRIPT" restart; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        4)  "$PANEL_MGMT_SCRIPT" start; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        5)  panel_update_installed || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        6)  "$PANEL_MGMT_SCRIPT" ssl; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        7)  "$PANEL_MGMT_SCRIPT" backup; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        8)  "$PANEL_MGMT_SCRIPT" health; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        9)  "$PANEL_MGMT_SCRIPT" open_port; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        10) "$PANEL_MGMT_SCRIPT" close_port; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        11) panel_cli ;;
        12) panel_reinstall_mgmt || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
        0)  return ;;
        *)  warn "Неверный выбор" ;;
        esac
        done
}
