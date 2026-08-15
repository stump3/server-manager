# shellcheck shell=bash
# telemt/menu.sh — меню статуса/логов/настроек, главное меню, submenus, uninstall


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
        telemt_pick_version
        systemctl stop telemt
        telemt_download_binary "$TELEMT_CHOSEN_VERSION"
        systemctl restart telemt
        sleep 3
    else
        cd "$TELEMT_WORK_DIR_DOCKER" || die "Директория не найдена"
        docker compose pull
        docker compose up -d
        sleep 3
    fi
    ok "Обновлено"
}

telemt_menu_stop() {
    header "Остановка"
    if [ "$TELEMT_MODE" = "systemd" ]; then need_root; systemctl stop telemt
    else cd "$TELEMT_WORK_DIR_DOCKER" || die ""; docker compose down; fi
    ok "Остановлено"
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
