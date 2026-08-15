# shellcheck shell=bash

# ── WARP Native ───────────────────────────────────────────────────
panel_warp_menu() {
    while true; do
        clear
        header "WARP Native"
        echo -e "  ${BOLD}1)${RESET} ⬇️   Установить WARP"
        echo -e "  ${BOLD}2)${RESET} ➕  Добавить в профиль Xray"
        echo -e "  ${BOLD}3)${RESET} ➖  Удалить из профиля Xray"
        echo -e "  ${BOLD}4)${RESET} 🗑️   Удалить WARP с системы"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh) || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) panel_warp_add_config || true ;;
            3) panel_warp_remove_config || true ;;
            4) bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh) || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_warp_select_profile() {
    local resp="$1"
    echo "$resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
ps = d.get('response', {}).get('configProfiles', [])
for i, p in enumerate(ps, 1):
    print(str(i) + ') ' + p['name'] + ' [' + p['uuid'] + ']')
PY
}

panel_warp_get_uuid() {
    local resp="$1"
    local num="$2"
    echo "$resp" | python3 - "$num" << 'PY'
import sys, json
d = json.load(sys.stdin)
num = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ps = d.get('response', {}).get('configProfiles', [])
try:
    print(ps[num - 1]['uuid'])
except Exception:
    pass
PY
}

panel_warp_add_config() {
    header "WARP — Добавить в профиль"
    [ -d /opt/remnawave ] || { warn "Панель не установлена"; return 1; }
    local token; token=$(panel_get_token) || return 1
    local resp; resp=$(panel_api_request "GET" "/api/config-profiles" "$token")
    echo ""
    panel_warp_select_profile "$resp"
    echo ""
    read -rp "  Номер профиля: " num < /dev/tty
    local uuid; uuid=$(panel_warp_get_uuid "$resp" "$num")
    [ -z "$uuid" ] && { warn "Неверный выбор"; return 1; }
    local cfg_resp; cfg_resp=$(panel_api_request "GET" "/api/config-profiles/$uuid" "$token")
    local cfg_json
    cfg_json=$(echo "$cfg_resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
cfg = d.get('response', {}).get('config', {})
ob = cfg.get('outbounds', [])
if not any(o.get('tag') == 'warp-out' for o in ob):
    ob.append({'tag': 'warp-out', 'protocol': 'freedom',
        'settings': {'domainStrategy': 'UseIP'},
        'streamSettings': {'sockopt': {'interface': 'warp', 'tcpFastOpen': True}}})
    cfg['outbounds'] = ob
rules = cfg.get('routing', {}).get('rules', [])
if not any(r.get('outboundTag') == 'warp-out' for r in rules):
    rules.append({'type': 'field',
        'domain': ['whoer.net', 'browserleaks.com', '2ip.io', '2ip.ru'],
        'outboundTag': 'warp-out'})
    cfg['routing']['rules'] = rules
print(json.dumps(cfg))
PY
)
    [ -z "$cfg_json" ] && { err "Ошибка обработки конфига"; return 1; }
    local upd; upd=$(panel_api_request "PATCH" "/api/config-profiles" "$token" "{\"uuid\":\"$uuid\",\"config\":$cfg_json}")
    echo "$upd" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get("response") else 1)' 2>/dev/null \
        && ok "WARP добавлен в профиль!" || warn "Ошибка обновления: $upd"
    read -rp "Enter..." < /dev/tty
}

panel_warp_remove_config() {
    header "WARP — Удалить из профиля"
    [ -d /opt/remnawave ] || { warn "Панель не установлена"; return 1; }
    local token; token=$(panel_get_token) || return 1
    local resp; resp=$(panel_api_request "GET" "/api/config-profiles" "$token")
    echo ""
    panel_warp_select_profile "$resp"
    echo ""
    read -rp "  Номер профиля: " num < /dev/tty
    local uuid; uuid=$(panel_warp_get_uuid "$resp" "$num")
    [ -z "$uuid" ] && { warn "Неверный выбор"; return 1; }
    local cfg_resp; cfg_resp=$(panel_api_request "GET" "/api/config-profiles/$uuid" "$token")
    local cfg_json
    cfg_json=$(echo "$cfg_resp" | python3 - << 'PY'
import sys, json
d = json.load(sys.stdin)
cfg = d.get('response', {}).get('config', {})
ob = cfg.get('outbounds', [])
cfg['outbounds'] = [o for o in ob if o.get('tag') != 'warp-out']
rules = cfg.get('routing', {}).get('rules', [])
cfg['routing']['rules'] = [r for r in rules if r.get('outboundTag') != 'warp-out']
print(json.dumps(cfg))
PY
)
    [ -z "$cfg_json" ] && { err "Ошибка обработки конфига"; return 1; }
    local upd; upd=$(panel_api_request "PATCH" "/api/config-profiles" "$token" "{\"uuid\":\"$uuid\",\"config\":$cfg_json}")
    echo "$upd" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if d.get("response") else 1)' 2>/dev/null \
        && ok "WARP удалён из профиля!" || warn "Ошибка обновления: $upd"
    read -rp "Enter..." < /dev/tty
}
