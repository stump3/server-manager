# shellcheck shell=bash
# telemt/users.sh — управление пользователями (add/delete/links/ips)


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
