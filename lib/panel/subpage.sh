# shellcheck shell=bash

# ── Страница подписки ─────────────────────────────────────────────
panel_subpage_menu() {
    while true; do
        clear
        header "Страница подписки"
        echo -e "  ${BOLD}1)${RESET} 🎨  Установить Orion шаблон"
        echo -e "  ${BOLD}2)${RESET} 🏷️   Настроить брендинг"
        echo -e "  ${BOLD}3)${RESET} ♻️   Восстановить оригинал"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_subpage_install_orion || true ;;
            2) panel_subpage_branding || true ;;
            3) panel_subpage_restore || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_subpage_install_orion() {
    header "Установка Orion шаблона"
    [ -f /opt/remnawave/docker-compose.yml ] || { warn "Панель не установлена"; return 1; }
    local index="/opt/remnawave/index.html"
    local compose="/opt/remnawave/docker-compose.yml"
    local primary="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
    local fallback="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
    info "Скачиваем Orion..."
    rm -f "$index"
    if ! curl -fsSL "$primary" -o "$index" 2>/dev/null; then
        curl -fsSL "$fallback" -o "$index" || { err "Ошибка загрузки"; return 1; }
    fi
    # Монтируем в docker-compose
    if command -v yq &>/dev/null; then
        yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$compose"
        yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$compose"
    else
        # Простая замена если нет yq
        warn "yq не установлен — монтирование не добавлено автоматически"
        warn "Добавьте вручную в docker-compose.yml:"
        echo "  volumes:"
        echo "    - ./index.html:/opt/app/frontend/index.html"
    fi
    cd /opt/remnawave
    docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Orion установлен!"
    read -rp "Enter..." < /dev/tty
}

panel_subpage_branding() {
    header "Брендинг подписки"
    local config="/opt/remnawave/app-config.json"
    if [ -f "$config" ]; then
        local name logo support
        name=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('name','—'))" 2>/dev/null)
        logo=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('logoUrl','—'))" 2>/dev/null)
        support=$(python3 -c "import json; d=json.load(open('$config')); print(d.get('config',{}).get('branding',{}).get('supportUrl','—'))" 2>/dev/null)
        echo ""
        echo -e "  ${GRAY}Текущие значения:${NC}"
        echo -e "  Название:  ${CYAN}${name}${NC}"
        echo -e "  Логотип:   ${CYAN}${logo}${NC}"
        echo -e "  Поддержка: ${CYAN}${support}${NC}"
        echo ""
    fi
    local new_name new_logo new_support
    read -rp "  Название (Enter — пропустить): " new_name < /dev/tty
    read -rp "  URL логотипа (Enter — пропустить): " new_logo < /dev/tty
    read -rp "  URL поддержки (Enter — пропустить): " new_support < /dev/tty
    # Обновляем конфиг
    NEW_NAME="$new_name" NEW_LOGO="$new_logo" NEW_SUPPORT="$new_support"     CONFIG_FILE="$config" python3 << 'PYEOF'
import json, os
config_file = os.environ["CONFIG_FILE"]
try:
    with open(config_file) as f:
        d = json.load(f)
except Exception:
    d = {"config": {}}
d.setdefault("config", {}).setdefault("branding", {})
n = os.environ.get("NEW_NAME")
l = os.environ.get("NEW_LOGO")
s = os.environ.get("NEW_SUPPORT")
if n: d["config"]["branding"]["name"]       = n
if l: d["config"]["branding"]["logoUrl"]    = l
if s: d["config"]["branding"]["supportUrl"] = s
with open(config_file, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print("OK")
PYEOF
    cd /opt/remnawave && docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Брендинг обновлён!"
    read -rp "Enter..." < /dev/tty
}

panel_subpage_restore() {
    header "Восстановить оригинал"
    read -rp "  Восстановить оригинальную страницу подписки? (y/n): " c < /dev/tty
    [[ "$c" =~ ^[yY]$ ]] || return
    rm -f /opt/remnawave/index.html /opt/remnawave/app-config.json
    if command -v yq &>/dev/null; then
        yq eval 'del(.services."remnawave-subscription-page".volumes)' -i /opt/remnawave/docker-compose.yml
    fi
    cd /opt/remnawave && docker compose restart remnawave-subscription-page >/dev/null 2>&1
    ok "Оригинал восстановлен!"
    read -rp "Enter..." < /dev/tty
}
