# shellcheck shell=bash
# panel/mgmt_script.sh — генерация /usr/local/bin/remnawave_panel
# (management-скрипт, устанавливаемый на сервер; тело heredoc не
# является кодом server-manager, это текст генерируемого файла)

panel_install_mgmt_script() {
    local panel_domain="$1" cookie_key="$2" cookie_val="$3" mode="$4"
    # NOTE: $mode above is accepted (both callers — install.sh and
    # management.sh's panel_reinstall_mgmt() — already pass it as the 4th
    # arg) but intentionally NOT interpolated into the heredoc below: the
    # heredoc delimiter is the single-quoted 'MGMTEOF', so nothing in it
    # is substituted at generation time in the first place (every other
    # $-prefixed thing inside is deployed-script-runtime syntax, not a
    # server-manager variable). The deployed script instead re-derives
    # MODE itself at runtime via its own _detect_mode() (see below,
    # same fingerprint as management.sh's panel_reinstall_mgmt()) — this
    # is deliberate, not an oversight: the mgmt script can be
    # reinstalled/updated independently of any install-time value, so a
    # value baked in at generation time could go stale.
    local mgmt="/usr/local/bin/remnawave_panel"
    cat > "$mgmt" << 'MGMTEOF'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; PURPLE='\033[0;35m'; NC='\033[0m'
DIR="/opt/remnawave"
_ok()   { echo -e "${GREEN}✅ $*${NC}"; }
_info() { echo -e "${CYAN}ℹ  $*${NC}"; }
_warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
_spinner() {
    local pid=$1 text="${2:-Подождите...}" spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' delay=0.1
    while kill -0 "$pid" 2>/dev/null; do
        for((i=0;i<${#spinstr};i++)); do
            printf "\r${YELLOW}[%s] %s${NC}" "${spinstr:$i:1}" "$text">/dev/tty; sleep $delay
        done
    done; printf "\r\033[K">/dev/tty
}
_detect_ws() { grep -q "remnawave-caddy" /opt/remnawave/docker-compose.yml 2>/dev/null && echo "caddy" || echo "nginx"; }
# _detect_mode — runtime fingerprint, NOT the value passed in at
# generation time (panel_install_mgmt_script's own $mode/$4 argument is
# intentionally unused inside this heredoc — see that function's
# comment). This script is deployed standalone and reinstalled/updated
# independently of the install-time call, so it re-derives MODE itself
# every time it runs, from the same nginx.conf shape check verified
# against real generated output for all four variants (kept in sync with
# lib/panel/management.sh's panel_reinstall_mgmt(), which needs the exact
# same fingerprint for its own display purposes and cannot source this
# file at runtime either — same standalone-copy constraint as
# _migrate_env_for_remnawave_v2 below):
#   MODE=1 — conf.d-style nginx.conf, no top-level `stream {`
#   MODE=F — top-level `stream {` (SNI routing to REALITY), no
#            "xray_xhttp" upstream (Variant F has no XHTTP inbound)
#   MODE=J — top-level `stream {` AND an "xray_xhttp" upstream
#   MODE=2 — no nginx.conf's stream{} shape applies (remote, no Node);
#            Caddy (ws=caddy) never reaches this function at all, since
#            F/J don't support Caddy and 1/2 don't need MODE here.
_detect_mode() {
    local nc="/opt/remnawave/nginx.conf"
    if [ -f "$nc" ] && grep -q "^stream {" "$nc" 2>/dev/null; then
        grep -q "xray_xhttp" "$nc" 2>/dev/null && echo "J" || echo "F"
    else
        grep -q "remnanode" /opt/remnawave/docker-compose.yml 2>/dev/null && echo "1" || echo "2"
    fi
}
# Keep in sync with panel_migrate_env_for_remnawave_v2 in
# lib/panel/migrate.sh (same migration logic, same atomic-write
# pattern) — this script is deployed standalone and can't source that
# file at runtime, so the two copies have to be kept identical by hand.
_migrate_env_for_remnawave_v2() {
    local env_file="$DIR/.env"
    [ -f "$env_file" ] || { _warn ".env не найден: $env_file"; return 1; }

    local sed_args=()
    local secret_action=""
    if grep -q '^JWT_AUTH_SECRET=' "$env_file" && ! grep -q '^APP_SECRET=' "$env_file"; then
        sed_args+=(-e 's/^JWT_AUTH_SECRET=/APP_SECRET=/')
        secret_action="renamed"
    elif grep -q '^JWT_AUTH_SECRET=' "$env_file" && grep -q '^APP_SECRET=' "$env_file"; then
        sed_args+=(-e '/^JWT_AUTH_SECRET=/d')
        secret_action="deduped"
    fi

    local removed=0
    for key in JWT_API_TOKENS_SECRET SWAGGER_PATH SCALAR_PATH IS_DOCS_ENABLED; do
        if grep -q "^${key}=" "$env_file"; then
            sed_args+=(-e "/^${key}=/d")
            removed=1
        fi
    done

    if [ "${#sed_args[@]}" -eq 0 ]; then
        return 0
    fi

    local _tmp; _tmp=$(mktemp)
    if sed "${sed_args[@]}" "$env_file" > "$_tmp" \
            && mv "$_tmp" "$env_file" && chmod 600 "$env_file"; then
        [ "$secret_action" = "renamed" ] && _ok ".env: JWT_AUTH_SECRET переименован в APP_SECRET"
        [ "$secret_action" = "deduped" ] && _ok ".env: удалён дублирующий JWT_AUTH_SECRET"
    else
        rm -f "$_tmp"
        _warn ".env: не удалось применить миграцию атомарно"
        return 1
    fi
    [ "$removed" = "1" ] && _ok ".env: удалены устаревшие переменные Remnawave"
}
do_status() {
    local ws; ws=$(_detect_ws)
    local ws_svc; [ "$ws" = "caddy" ] && ws_svc="remnawave-caddy" || ws_svc="remnawave-nginx"
    echo -e "${WHITE}📊 Статус:${NC}"
    for c in remnawave remnawave-db remnawave-redis $ws_svc remnawave-subscription-page remnanode; do
        s=$(docker ps --format '{{.Status}}' -f "name=$c" 2>/dev/null | head -1)
        [ -n "$s" ] && echo "$s" | grep -qE "^Up|healthy" \
            && echo -e "  ${GREEN}●${NC} $c — $s" || echo -e "  ${YELLOW}◐${NC} $c — $s" \
            || echo -e "  ${RED}○${NC} $c"
    done
    echo ""
    docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null \
        | grep -E "remnawave|remnanode" | sort \
        | awk -F"\t" '{printf "  %-36s %6s   %s\n", $1, $2, $3}'
}
do_logs() {
    local s="${1:-panel}"; cd "$DIR"
    local ws; ws=$(_detect_ws)
    case $s in
        nginx|caddy) docker logs "remnawave-${ws}" --tail=50 -f ;;
        sub)   docker logs remnawave-subscription-page --tail=50 -f ;;
        node)  docker logs remnanode --tail=50 -f ;;
        *)     docker compose logs --tail=50 -f remnawave ;;
    esac
}
do_restart() {
    local s="${1:-all}"; cd "$DIR"
    local ws; ws=$(_detect_ws)
    local ws_svc="remnawave-${ws}"
    case $s in
        nginx|caddy) docker compose restart "$ws_svc"; _ok "${ws^} перезапущен" ;;
        panel)  docker compose restart remnawave; _ok "Панель перезапущена" ;;
        sub)    docker compose restart remnawave-subscription-page; _ok "Sub перезапущена" ;;
        node)   docker compose restart remnanode; _ok "Нода перезапущена" ;;
        all)
            docker compose down>/dev/null 2>&1 & _spinner $! "Остановка..."
            docker compose up -d>/dev/null 2>&1 & _spinner $! "Запуск..."
            _ok "Всё перезапущено" ;;
        *) echo "Укажите: all|nginx|caddy|panel|sub|node" ;;
    esac
}
do_update() {
    cd "$DIR"
    _warn "Перед обновлением будет создан бэкап БД и конфигов."
    do_backup
    _migrate_env_for_remnawave_v2 || return 1
    docker compose pull>/dev/null 2>&1 & _spinner $! "Загрузка..."
    docker compose down>/dev/null 2>&1 & _spinner $! "Остановка..."
    docker compose up -d>/dev/null 2>&1 & _spinner $! "Запуск..."
    docker image prune -f>/dev/null 2>&1; _ok "Обновлено"
}
do_ssl() {
    local ws; ws=$(_detect_ws); cd "$DIR"
    if [ "$ws" = "caddy" ]; then
        _info "Caddy управляет SSL автоматически через ACME"
        docker exec remnawave-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
            && _ok "Caddy конфиг перезагружен" \
            || _warn "Не удалось перезагрузить Caddy"
    else
        certbot renew --quiet
        docker compose restart remnawave-nginx
        _ok "SSL обновлён"
    fi
}
do_backup() {
    local ts b ws_cfg
    ts=$(date +%Y%m%d_%H%M%S); b="$DIR/backups"; mkdir -p "$b"; cd "$DIR"
    [ -f "$DIR/Caddyfile" ] && ws_cfg="$DIR/Caddyfile" || ws_cfg="$DIR/nginx.conf"
    docker compose exec -T remnawave-db pg_dump -U postgres postgres>"$b/db_$ts.sql" 2>/dev/null \
        && _ok "БД → $b/db_$ts.sql" || _warn "Ошибка бэкапа БД"
    tar -czf "$b/configs_$ts.tar.gz" "$DIR/.env" "$DIR/docker-compose.yml" "$ws_cfg" 2>/dev/null
    _ok "Конфиги → $b/configs_$ts.tar.gz"
    find "$b" -mtime +7 -delete 2>/dev/null||true
}
do_health() {
    local ws; ws=$(_detect_ws)
    do_status; echo ""
    if [ "$ws" = "nginx" ]; then
        echo -e "${WHITE}🔒 SSL:${NC}"
        for d in /etc/letsencrypt/live/*/; do
            dom=$(basename "$d")
            exp=$(openssl x509 -in "$d/fullchain.pem" -noout -enddate 2>/dev/null|sed 's/notAfter=//')
            [ -n "$exp" ] && echo -e "  ${GREEN}✓${NC} $dom — $exp"
        done; echo ""
        echo -e "${WHITE}Nginx:${NC}"
        docker exec remnawave-nginx nginx -t 2>&1|sed 's/^/  /'||true; echo ""
    else
        echo -e "${WHITE}🔒 Caddy SSL (ACME):${NC}"
        docker exec remnawave-caddy caddy validate --config /etc/caddy/Caddyfile 2>&1|sed 's/^/  /'||true; echo ""
    fi
    echo -e "${WHITE}API:${NC}"
    curl -s --max-time 5 "http://127.0.0.1:3000/api/auth/status" \
        -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' 2>/dev/null | \
        jq -e '.response'>/dev/null 2>&1 \
        && echo -e "  ${GREEN}✓${NC} API доступен" || echo -e "  ${RED}✗${NC} API недоступен"
}
do_open_port() {
    local ws; ws=$(_detect_ws)
    if [ "$ws" = "caddy" ]; then
        _warn "Открытие дополнительного порта не поддерживается для Caddy"
        _info "Для экстренного доступа: rp restart && rp logs caddy"
        return 0
    fi
    local mode; mode=$(_detect_mode)
    if [ "$mode" = "F" ] || [ "$mode" = "J" ]; then
        _warn "Экстренное открытие порта 8443 не поддерживается для Variant $mode"
        _info "Variant $mode's nginx.conf uses a top-level stream{} SNI router, not the plain conf.d-style single-vhost file this sed-based mechanism expects — inserting 'listen 8443 ssl;' into it would not do what MODE=1/2 users expect, and for Variant J port 8443 is already the public XHTTP listener."
        return 1
    fi
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    ss -tuln|grep -q ":8443" && { _warn "Порт 8443 занят"; return 1; }
    sed -i "/server_name $pd;/a \\    listen 8443 ssl;" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    ufw allow 8443/tcp>/dev/null 2>&1; ufw reload>/dev/null 2>&1
    local ck cv
    ck=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '~\*\K\w+(?==)')
    cv=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '=\K\w+(?= 1)')
    _ok "Порт 8443 открыт."
    echo -e "  ${WHITE}https://${pd}:8443/auth/login?${ck}=${cv}${NC}"
    _warn "Закройте после работы: remnawave_panel close_port"
}
do_close_port() {
    local ws; ws=$(_detect_ws)
    if [ "$ws" = "caddy" ]; then _warn "Не применимо для Caddy"; return 0; fi
    local mode; mode=$(_detect_mode)
    if [ "$mode" = "F" ] || [ "$mode" = "J" ]; then
        _warn "Не применимо для Variant $mode (см. 'rp open_port' — эта пара команд для MODE=1/2)"
        return 1
    fi
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    sed -i "/server_name $pd;/,/}/{s/    listen 8443 ssl;//}" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    ufw delete allow 8443/tcp>/dev/null 2>&1; ufw reload>/dev/null 2>&1
    _ok "Порт 8443 закрыт"
}
do_migrate() {
    header "📦 Перенос Panel на другой сервер"

    # ── Проверки ───────────────────────────────────────────────────
    [ -d /opt/remnawave ] || { err "Панель не установлена"; return 1; }
    [ -f /opt/remnawave/docker-compose.yml ] || { err "docker-compose.yml не найден"; return 1; }
    command -v sshpass &>/dev/null || apt-get install -y -q sshpass 2>/dev/null

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target
    init_ssh_helpers panel
    check_ssh_connection || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    # ── Проверка свободного места ──────────────────────────────────
    _info "Проверяем свободное место на новом сервере..."
    local remote_free local_used
    remote_free=$(RUN "df -BM /opt --output=avail | tail -1 | tr -d 'M'" 2>/dev/null || echo "0")
    local_used=$(du -sm /opt/remnawave 2>/dev/null | awk '{print $1}' || echo "0")
    if [ "$remote_free" -lt "$((local_used * 2))" ] 2>/dev/null; then
        _warn "Мало места на новом сервере: ${remote_free}MB свободно, нужно ~$((local_used * 2))MB"
        read -rp "  Продолжить всё равно? (y/n): " fc < /dev/tty
        [[ "$fc" =~ ^[yY]$ ]] || return 1
    fi

    # ── Установка зависимостей на новом сервере ────────────────────
    remote_install_deps panel "$(_detect_ws)"

    # ── Дамп БД ────────────────────────────────────────────────────
    _info "Создаём дамп базы данных..."
    local dump="/tmp/panel_migrate_$(date +%Y%m%d_%H%M%S).sql.gz"
    cd /opt/remnawave
    docker compose exec -T remnawave-db pg_dumpall -c -U postgres 2>/dev/null | gzip -9 > "$dump"

    # Проверяем размер дампа
    local dump_size; dump_size=$(stat -c%s "$dump" 2>/dev/null || echo "0")
    if [ "$dump_size" -lt 1000 ]; then
        err "Дамп БД подозрительно мал (${dump_size} байт) — возможна ошибка"
        rm -f "$dump"
        return 1
    fi
    _ok "Дамп БД создан ($(du -sh "$dump" | cut -f1))"

    # ── Передача файлов ────────────────────────────────────────────
    _info "Передаём файлы панели..."
    local ws_cfg_src
    [ -f /opt/remnawave/Caddyfile ] && ws_cfg_src=/opt/remnawave/Caddyfile || ws_cfg_src=/opt/remnawave/nginx.conf
    PUT "$dump" \
        /opt/remnawave/.env \
        /opt/remnawave/docker-compose.yml \
        "$ws_cfg_src" \
        "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null \
        && _ok "Файлы панели переданы" || { err "Ошибка передачи файлов панели"; return 1; }

    # SSL сертификаты
    _info "Передаём SSL сертификаты..."
    if [ -d /etc/letsencrypt/live ] && [ -d /etc/letsencrypt/archive ]; then
        PUT /etc/letsencrypt/live \
            /etc/letsencrypt/archive \
            /etc/letsencrypt/renewal \
            "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null \
            && _ok "SSL сертификаты переданы" || _warn "Ошибка передачи SSL — перевыпустите вручную"
    else
        _warn "SSL сертификаты не найдены в /etc/letsencrypt"
    fi

    # Hysteria сертификаты (если есть)
    if [ -d /etc/ssl/certs/hysteria ]; then
        _info "Передаём сертификаты Hysteria2..."
        PUT /etc/ssl/certs/hysteria \
            "${ruser}@${rip}:/etc/ssl/certs/" 2>/dev/null \
            && _ok "Сертификаты Hysteria2 переданы" || _warn "Ошибка передачи сертификатов Hysteria2"
    fi

    # Selfsteal сайт
    if [ -d /var/www/html ] && [ "$(ls -A /var/www/html 2>/dev/null)" ]; then
        _info "Передаём selfsteal сайт..."
        PUT /var/www/html/. "${ruser}@${rip}:/var/www/html/" 2>/dev/null \
            && _ok "Selfsteal сайт передан" || _warn "Ошибка передачи сайта"
    fi

    _ok "Все файлы переданы"

    # ── Запуск на новом сервере ────────────────────────────────────
    _info "Запускаем стек на новом сервере..."
    local dumpb; dumpb=$(basename "$dump")
    RUN bash -s << RSTART
set -e
cd /opt/remnawave

# Удаляем старый volume БД если есть
docker volume rm remnawave-db-data 2>/dev/null || true

# Запускаем только БД и Redis
docker compose up -d remnawave-db remnawave-redis >/dev/null 2>&1
echo "Ждём запуска БД..."
_pw=0
until docker compose exec -T remnawave-db pg_isready -U postgres -q 2>/dev/null; do
    sleep 2; _pw=$((_pw+1))
    [ "$_pw" -ge 30 ] && { echo "PostgreSQL не поднялся за 60 сек" >&2; exit 1; }
done

# Восстанавливаем дамп
echo "Восстанавливаем базу данных..."
zcat /opt/remnawave/$dumpb | docker compose exec -T remnawave-db psql -U postgres postgres >/dev/null 2>&1 || true

# Запускаем весь стек
docker compose up -d >/dev/null 2>&1
echo "Стек запущен"
RSTART
    _ok "Стек запущен на новом сервере"

    # ── Копируем скрипты управления ────────────────────────────────
    PUT /usr/local/bin/remnawave_panel \
        "${ruser}@${rip}:/usr/local/bin/remnawave_panel" 2>/dev/null && \
    RUN "chmod +x /usr/local/bin/remnawave_panel" 2>/dev/null && \
    RUN "grep -q 'alias rp=' /etc/bash.bashrc || echo \"alias rp='remnawave_panel'\" >> /etc/bash.bashrc" 2>/dev/null
    _ok "Скрипт управления установлен"

    # ── Копируем репозиторий server-manager ───────────────────────
    local _sm_dir="${SCRIPT_DIR:-$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")}"
    if [ -d "$_sm_dir" ] && [ -f "$_sm_dir/server-manager.sh" ]; then
        RUN "mkdir -p /root/server-manager" 2>/dev/null || true
        PUT "$_sm_dir/." "${ruser}@${rip}:/root/server-manager/" 2>/dev/null || true
        RUN "chmod +x /root/server-manager/server-manager.sh &&             ln -sf /root/server-manager/server-manager.sh /usr/local/bin/server-manager" 2>/dev/null || true
        _ok "server-manager скопирован на новый сервер"
    else
        warn "Не удалось определить каталог server-manager — скопируйте вручную"
    fi

    # ── Очистка ────────────────────────────────────────────────────
    rm -f "$dump"
    RUN "rm -f /opt/remnawave/$dumpb" 2>/dev/null || true

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    _ok "Перенос панели завершён!"
    echo ""
    echo -e "  ${WHITE}Следующие шаги:${NC}"
    echo -e "  ${CYAN}1.${NC} Обновите DNS-записи на новый IP: ${CYAN}${rip}${NC}"
    echo -e "  ${CYAN}2.${NC} После обновления DNS перевыпустите SSL:"
    echo -e "     ${CYAN}ssh ${ruser}@${rip} remnawave_panel ssl${NC}"
    echo -e "  ${CYAN}3.${NC} Проверьте работу панели"
    echo -e "  ${CYAN}4.${NC} Остановите старый сервер когда всё ОК"
    echo ""

    read -rp "  Остановить панель на ЭТОМ сервере? (y/n): " stop_old < /dev/tty
    if [[ "$stop_old" =~ ^[yY]$ ]]; then
        cd /opt/remnawave && docker compose stop >/dev/null 2>&1
        _ok "Панель на старом сервере остановлена"
    else
        _info "Панель на старом сервере продолжает работать"
    fi
}
show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${PURPLE}  REMNAWAVE PANEL${NC}"
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    local ws_svc; ws_svc="remnawave-$(_detect_ws)"
    for c in remnawave $ws_svc remnawave-subscription-page remnanode; do
        s=$(docker ps --format '{{.Status}}' -f "name=$c" 2>/dev/null|head -1)
        if [ -n "$s" ] && echo "$s"|grep -qE "^Up|healthy"; then
            echo -e "  ${GREEN}●${NC} $c"
        elif [ -n "$s" ]; then
            echo -e "  ${YELLOW}◐${NC} $c — $s"
        else
            echo -e "  ${RED}○${NC} $c"
        fi
    done
    echo ""
    echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  📋 Логи        ${BOLD}2)${NC}  📊 Статус    ${BOLD}3)${NC}  🔄 Перезапуск"
    echo -e "  ${BOLD}4)${NC}  ▶️  Старт       ${BOLD}5)${NC}  📦 Обновить  ${BOLD}6)${NC}  🔒 SSL"
    echo -e "  ${BOLD}7)${NC}  💾 Бэкап       ${BOLD}8)${NC}  🏥 Диагноз   ${BOLD}9)${NC}  🔓 Порт 8443"
    echo -e " ${BOLD}10)${NC}  🔐 Закрыть    ${BOLD}11)${NC}  📦 Перенос"
    echo ""
    echo -e "  ${BOLD}q)${NC}  Выход"
    echo ""
}
case "$1" in
    status)      do_status ;;
    logs)        do_logs "${2:-panel}" ;;
    restart)     do_restart "${2:-all}" ;;
    start)       cd /opt/remnawave && docker compose up -d; _ok "Запущено" ;;
    stop)        cd /opt/remnawave && docker compose down; _ok "Остановлено" ;;
    update)      do_update ;;
    ssl)         do_ssl ;;
    backup)      do_backup ;;
    health)      do_health ;;
    open_port)   do_open_port ;;
    close_port)  do_close_port ;;
    migrate)     do_migrate ;;
    help|--help)
        echo "remnawave_panel (rp) — управление Remnawave Panel"
        echo "Команды: status logs restart start stop update ssl backup health open_port close_port migrate"
        ;;
    "")
        while true; do
            show_menu
            read -p "  Выбор: " ch < /dev/tty
            case $ch in
                1) read -p "  Логи (panel/nginx/caddy/sub/node) [panel]: " s < /dev/tty; do_logs "${s:-panel}" ;;
                2) do_status; read -t 0.1 -n 1000 _flush < /dev/tty 2>/dev/null || true; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                3) read -p "  Что перезапустить? [all]: " s < /dev/tty; do_restart "${s:-all}"; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                4) cd /opt/remnawave && docker compose up -d; _ok "Запущено"; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                5) do_update; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                6) do_ssl; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                7) do_backup; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                8) do_health; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                9) do_open_port; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
               10) do_close_port; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
               11) do_migrate; read -p "  Нажмите Enter для продолжения..." < /dev/tty ;;
                q|Q) exit 0 ;;
                *) sleep 0.3 ;;
            esac
        done ;;
    *) echo "Неизвестная команда. rp help"; exit 1 ;;
esac
MGMTEOF
    chmod +x "$mgmt"
    grep -q "alias rp=" /etc/bash.bashrc 2>/dev/null || \
        echo "alias rp='remnawave_panel'" >> /etc/bash.bashrc
    ok "Команда 'remnawave_panel' (rp) создана"
}
