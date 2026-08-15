# shellcheck shell=bash
# telemt/api.sh — обращения к локальному API telemt, путь к БД трафика, получение ссылок


# ── API: запрос с обработкой ошибок ──────────────────────────────
telemt_api() {
    local method="$1" path="$2" body="${3:-}"
    local url="http://127.0.0.1:9091${path}"
    if [ -n "$body" ]; then
        curl -s --max-time 10 -X "$method" -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null
    else
        curl -s --max-time 10 -X "$method" "$url" 2>/dev/null
    fi
}

telemt_api_ok() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null
}

telemt_api_error() {
    echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); e=d.get('error',{}); print(e.get('message','неизвестная ошибка'))" 2>/dev/null
}

# ── Путь к файлу накопленной статистики трафика ──────────────────
telemt_traffic_db_path() {
    if [ "${TELEMT_MODE:-}" = "docker" ]; then
        echo "${TELEMT_WORK_DIR_DOCKER}/traffic-usage.json"
    else
        echo "/var/lib/telemt/traffic-usage.json"
    fi
}

# ── Показ пользователей ───────────────────────────────────────────
telemt_fetch_links() {
    local attempts_max="${1:-15}"
    local attempt=0
    info "Запрашиваю данные через API..."
    while [ $attempt -lt "$attempts_max" ]; do
        local resp; resp=$(telemt_api GET "/v1/users" || true)
        if echo "$resp" | grep -q "tg://proxy"; then
            echo ""
            local traffic_db
            traffic_db=$(telemt_traffic_db_path)
            TELEMT_TRAFFIC_DB="$traffic_db" echo "$resp" | python3 -c "
import sys, json
import os
from datetime import datetime, timezone, timedelta
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; GRAY='\033[0;37m'; RESET='\033[0m'
def fmt_bytes(b):
    if not b: return '0 B'
    for u in ('B','KB','MB','GB','TB'):
        if b < 1024: return f'{b:.1f} {u}' if u != 'B' else f'{int(b)} B'
        b /= 1024
    return f'{b:.2f} PB'

db_path = os.environ.get('TELEMT_TRAFFIC_DB', '').strip()
state = {'users': {}, 'settings': {'ip_retention_days': 30, 'traffic_retention_days': 90}}
if db_path:
    try:
        with open(db_path, 'r', encoding='utf-8') as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                state = loaded
                if not isinstance(state.get('users'), dict):
                    state['users'] = {}
                if not isinstance(state.get('settings'), dict):
                    state['settings'] = {'ip_retention_days': 30, 'traffic_retention_days': 90}
    except Exception:
        state = {'users': {}, 'settings': {'ip_retention_days': 30, 'traffic_retention_days': 90}}

retention_days = int(state.get('settings', {}).get('ip_retention_days', 30) or 30)
if retention_days < 1:
    retention_days = 30
traffic_retention_days = int(state.get('settings', {}).get('traffic_retention_days', 90) or 90)
if traffic_retention_days not in (60, 90):
    traffic_retention_days = 90
now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=retention_days)

data = json.load(sys.stdin)
users = data if isinstance(data, list) else data.get('users', data.get('data', []))
if isinstance(users, dict): users = list(users.values())
for u in users:
    name = u.get('username') or u.get('name') or 'user'
    tls  = u.get('links', {}).get('tls', [])
    conns = u.get('current_connections', 0)
    aips  = u.get('active_unique_ips', 0)
    al    = u.get('active_unique_ips_list', [])
    rips  = u.get('recent_unique_ips', 0)
    rl    = u.get('recent_unique_ips_list', [])
    oct   = int(u.get('total_octets') or 0)
    mc    = u.get('max_tcp_conns')
    mi    = u.get('max_unique_ips')
    q     = u.get('data_quota_bytes')
    exp   = u.get('expiration_rfc3339')

    rec = state['users'].get(name, {})
    last_raw = rec.get('last_raw')
    total_acc = int(rec.get('total_accumulated', 0) or 0)
    delta = 0
    if last_raw is None:
        total_acc = oct
        delta = 0
    else:
        try:
            last_raw = int(last_raw)
        except Exception:
            last_raw = 0
        delta = (oct - last_raw) if oct >= last_raw else oct
        total_acc += delta

    monthly = rec.get('monthly', {})
    if not isinstance(monthly, dict):
        monthly = {}
    mon_key = now.strftime('%Y-%m')
    monthly[mon_key] = int(monthly.get(mon_key, 0) or 0) + max(delta, 0)
    month_total = int(monthly.get(mon_key, 0) or 0)

    daily = rec.get('daily', {})
    if not isinstance(daily, dict):
        daily = {}
    day_key = now.strftime('%Y-%m-%d')
    daily[day_key] = int(daily.get(day_key, 0) or 0) + max(delta, 0)
    day_total = int(daily.get(day_key, 0) or 0)

    # Храним трафик в JSON только в пределах окна настроек (60/90 дней).
    daily_cutoff = now - timedelta(days=traffic_retention_days)
    daily_pruned = {}
    for dkey, dval in daily.items():
        try:
            ddt = datetime.fromisoformat(dkey + 'T00:00:00+00:00')
            if ddt >= daily_cutoff:
                daily_pruned[dkey] = int(dval or 0)
        except Exception:
            continue
    hist = rec.get('ip_history', {})
    if not isinstance(hist, dict):
        hist = {}

    seen_ips = set([ip for ip in (al or []) + (rl or []) if ip])
    for ip in seen_ips:
        ip_rec = hist.get(ip, {})
        first_seen = ip_rec.get('first_seen') or now.isoformat()
        hits = int(ip_rec.get('hits', 0) or 0) + 1
        hist[ip] = {
            'first_seen': first_seen,
            'last_seen': now.isoformat(),
            'hits': hits,
        }

    pruned = {}
    for ip, ip_rec in hist.items():
        last = (ip_rec or {}).get('last_seen')
        keep = False
        if isinstance(last, str):
            try:
                keep = datetime.fromisoformat(last.replace('Z', '+00:00')) >= cutoff
            except Exception:
                keep = False
        if keep:
            pruned[ip] = ip_rec

    state['users'][name] = {
        'last_raw': oct,
        'total_accumulated': total_acc,
        'ip_history': pruned,
        'monthly': monthly,
        'daily': daily_pruned
    }

    print(f'{BOLD}{CYAN}┌─ {name}{RESET}')
    if tls: print(f'{BOLD}│  Ссылка:{RESET}      {tls[0]}')
    print(f'{BOLD}│  Подключений:{RESET} {conns}' + (f' / {mc}' if mc else ''))
    print(f'{BOLD}│  Активных IP:{RESET} {aips}' + (f' / {mi}' if mi else ''))
    for ip in al: print(f'{BOLD}│{RESET}    {GREEN}▸ {ip}{RESET}')
    print(f'{BOLD}│  Недавних IP:{RESET} {rips}')
    print(f'{BOLD}│  Трафик:{RESET}')
    print(f'{BOLD}│    За сегодня:{RESET}    {fmt_bytes(day_total)}')
    print(f'{BOLD}│    В этом месяце:{RESET} {fmt_bytes(month_total)}')
    print(f'{BOLD}│    Всего:{RESET}        {fmt_bytes(total_acc)}')
    print(f'{BOLD}│    Сейчас (runtime):{RESET} {fmt_bytes(oct)}' + (f' / {fmt_bytes(q)}' if q else ''))
    if exp: print(f'{BOLD}│  Истекает:{RESET}    {exp}')
    print(f'{BOLD}└{chr(9472)*44}{RESET}'); print()

state['settings']['ip_retention_days'] = retention_days
state['settings']['traffic_retention_days'] = traffic_retention_days
state['updated_at'] = now.isoformat()
if db_path:
    try:
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        with open(db_path, 'w', encoding='utf-8') as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except Exception:
        pass
" 2>/dev/null || echo "$resp"
            [ -n "$traffic_db" ] && info "Накопленная статистика: $traffic_db"
            return 0
        fi
        attempt=$((attempt+1)); sleep 2; echo -n "."
    done
    echo ""; warn "API не ответил. Попробуй: curl -s http://127.0.0.1:9091/v1/users"
    return 1
}
