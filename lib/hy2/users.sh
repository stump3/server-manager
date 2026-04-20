# shellcheck shell=bash
# Hysteria2: управление пользователями и ссылки

hysteria_add_user() {
    header "Hysteria2 — Добавить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local new_user=""
    while [ -z "$new_user" ]; do
        read -rp "  Логин: " new_user < /dev/tty
        new_user="${new_user// /}"
        [ -z "$new_user" ] && warn "Логин не может быть пустым"
    done

    local new_pass=""
    read -rp "  Пароль (пусто = авто): " new_pass < /dev/tty
    if [ -z "$new_pass" ]; then
        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $new_pass"
    fi

    local _users_db="/var/lib/hy-webhook/users.json"
    local _is_http_auth=false
    grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && _is_http_auth=true

    if $_is_http_auth; then
        # Пароль = SHA-256(username:WEBHOOK_SECRET)[:32] — совпадает с gen_password() в hy-webhook.py
        local _secret; _secret=$(grep "^WEBHOOK_SECRET=" /etc/hy-webhook.env 2>/dev/null | cut -d= -f2)
        local _hash=""
        if [ -n "$_secret" ]; then
            _hash=$(python3 -c "import hashlib; print(hashlib.sha256('${new_user}:$_secret'.encode()).hexdigest()[:32])" 2>/dev/null)
        fi
        [ -z "$_hash" ] && _hash="$new_pass"
        mkdir -p "$(dirname "$_users_db")"
        local _tmp; _tmp=$(mktemp)
        python3 << PYEOF
import json
db = "$_users_db"
try:
    with open(db) as f: u = json.load(f)
except Exception: u = {}
u["${new_user}"] = "$_hash"
with open("$_tmp", "w") as f: json.dump(u, f, indent=2)
PYEOF
        mv "$_tmp" "$_users_db" && chmod 644 "$_users_db" || rm -f "$_tmp"
        systemctl restart hy-webhook 2>/dev/null || true
        ok "Пользователь '${new_user}' добавлен (HTTP auth)"
        new_pass="$_hash"
    else
        if awk '/^  userpass:/,/^[^ ]/{print}' "$HYSTERIA_CONFIG" | grep -qE "^[[:space:]]{4}${new_user}:"; then
            warn "Пользователь '${new_user}' уже существует"; return 1
        fi
        local _tmp; _tmp=$(mktemp)
        awk "/^  userpass:/{print; print \"    ${new_user}: \\\"${new_pass}\\\"\" ; next}1" \
            "$HYSTERIA_CONFIG" > "$_tmp" \
            && mv "$_tmp" "$HYSTERIA_CONFIG" && chmod 644 "$HYSTERIA_CONFIG" \
            || rm -f "$_tmp"
        systemctl restart "$HYSTERIA_SVC"
        ok "Пользователь '${new_user}' добавлен"
    fi

    local dom port
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    # Название подключения
    local conn_name
    read -rp "  Название подключения [${new_user}]: " conn_name < /dev/tty
    conn_name="${conn_name:-$new_user}"

    local uri="hy2://${new_user}:${new_pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    echo "$uri" >> "/root/hysteria-${dom}-users.txt"
    ok "URI сохранён: /root/hysteria-${dom}-users.txt"
}

hysteria_delete_user() {
    header "Hysteria2 — Удалить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local -a users=()
    local _users_db="/var/lib/hy-webhook/users.json"
    if [ -f "$_users_db" ] && python3 -c "import json; json.load(open('$_users_db'))" 2>/dev/null; then
        while IFS= read -r u; do
            [ -n "$u" ] && users+=("$u")
        done < <(python3 -c "import json; [print(u) for u in json.load(open('$_users_db'))]" 2>/dev/null)
    fi
    if [ ${#users[@]} -eq 0 ]; then
        while IFS= read -r line; do
            local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
            [ -n "$u" ] && users+=("$u")
        done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")
    fi
    [ ${#users[@]} -eq 0 ] && { warn "Пользователи не найдены"; return 1; }

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
    [[ "$ch" == "0" ]] && return 0
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi
    local victim="${users[$((ch-1))]}"

    read -rp "  Удалить '${victim}'? (y/N): " _yn < /dev/tty
    [[ "${_yn:-N}" =~ ^[yY]$ ]] || { warn "Отмена"; return 1; }

    local _is_http_auth=false
    grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && _is_http_auth=true
    if $_is_http_auth && [ -f "$_users_db" ]; then
        local _tmp; _tmp=$(mktemp)
        python3 << PYEOF
import json
db = "$_users_db"
with open(db) as f: u = json.load(f)
u.pop("${victim}", None)
with open("$_tmp", "w") as f: json.dump(u, f, indent=2)
PYEOF
        mv "$_tmp" "$_users_db" && chmod 644 "$_users_db" || rm -f "$_tmp"
        systemctl restart hy-webhook 2>/dev/null || true
    else
        local _tmp; _tmp=$(mktemp)
        awk -v user="$victim" '
            $0 ~ "^    "user":" {next}
            {print}
        ' "$HYSTERIA_CONFIG" > "$_tmp" \
            && mv "$_tmp" "$HYSTERIA_CONFIG" && chmod 644 "$HYSTERIA_CONFIG" \
            || rm -f "$_tmp"
        systemctl restart "$HYSTERIA_SVC" 2>/dev/null || true
    fi

    local dom; dom=$(hy_get_domain)
    for f in "/root/hysteria-${dom}-users.txt" "/root/hysteria-${dom}.txt"; do
        [ -f "$f" ] || continue
        local _tmp; _tmp=$(mktemp)
        grep -av "hy2://${victim}:" "$f" > "$_tmp" && mv "$_tmp" "$f" || rm -f "$_tmp"
    done
    ok "Пользователь '${victim}' удалён"
}

hysteria_show_links() {
    header "Hysteria2 — Пользователи и ссылки"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local dom port
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    # Читаем пользователей из users.json (HTTP auth) или из config.yaml (userpass)
    local -a users=()
    local _users_db="/var/lib/hy-webhook/users.json"
    if [ -f "$_users_db" ] && python3 -c "import json; json.load(open('$_users_db'))" 2>/dev/null; then
        while IFS= read -r u; do
            [ -n "$u" ] && users+=("$u")
        done < <(python3 -c "import json; [print(u) for u in json.load(open('$_users_db'))]" 2>/dev/null)
    fi
    # Fallback: читаем из userpass блока в конфиге
    if [ ${#users[@]} -eq 0 ]; then
        while IFS= read -r line; do
            local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
            [ -n "$u" ] && users+=("$u")
        done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")
    fi

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя:${NC}"
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
    local pass=""
    # Сначала пробуем users.json (HTTP auth режим)
    local _users_db="/var/lib/hy-webhook/users.json"
    if [ -f "$_users_db" ]; then
        pass=$(python3 -c "
import json, sys
d = json.load(open('$_users_db'))
safe = '${selected}'.replace(' ', '_')
print(d.get('${selected}') or d.get(safe) or '')
" 2>/dev/null)
    fi
    # Fallback: парсим userpass блок в config.yaml
    if [ -z "$pass" ] && command -v python3 &>/dev/null; then
        pass=$(python3 -c "
import sys, re
cfg = open('$HYSTERIA_CONFIG').read()
m = re.search(r'^ {4}' + re.escape('${selected}') + r':\s*[\"\x27]?([^\"\x27\n]+)[\"\x27]?', cfg, re.M)
print(m.group(1).strip() if m else '')
" 2>/dev/null)
    fi

    # Ищем сохранённое название из URI-файлов
    local conn_name=""
    for f in "/root/hysteria-${dom}-users.txt" "/root/hysteria-${dom}.txt"; do
        [ -f "$f" ] || continue
        local found_name
        found_name=$(grep -a "hy2://${selected}:" "$f" 2>/dev/null | sed 's/.*#//' | tail -1 || true)
        if [ -n "$found_name" ]; then
            conn_name="$found_name"
            break
        fi
    done
    # Если не нашли — используем имя пользователя
    conn_name="${conn_name:-$selected}"

    local uri="hy2://${selected}:${pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"

    echo ""
    echo -e "  ${CYAN}Пользователь:${NC} ${selected}"
    echo -e "  ${CYAN}Сервер:${NC}       ${dom}:${port}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}${WHITE}  QR-код${NC}"
        echo -e "${GRAY}  ──────────────────────────────${NC}"
        qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    else
        echo -e "  ${GRAY}QR: установите qrencode — apt install qrencode${NC}"
    fi
    echo ""
    read -rp "  Enter для возврата..." < /dev/tty
}
