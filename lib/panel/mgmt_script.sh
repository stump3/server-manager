# shellcheck shell=bash
# panel/mgmt_script.sh — генерация /usr/local/bin/remnawave_panel
# (management-скрипт, устанавливаемый на сервер; тело heredoc не
# является кодом server-manager, это текст генерируемого файла)

panel_install_mgmt_script() {
    local panel_domain="$1" cookie_key="$2" cookie_val="$3" mode="$4"
    local mgmt="/usr/local/bin/remnawave_panel"
    # FIXED 2026-08-31: `mode` was captured from the caller but never
    # actually used anywhere below — the main body is a QUOTED heredoc
    # (<< 'MGMTEOF'), so $mode never got substituted into the deployed
    # script; it was silently dead. That mattered because do_open_port/
    # do_close_port (further down) assume the classic MODE=1/2 nginx
    # layout (single conf.d server{} per domain, sed-patchable) and have
    # no idea Variant F/J's nginx.conf is structurally different (a full
    # top-level config with stream{} + http{}, panel's server{} listening
    # on loopback only) — see the guard added there. This tiny unquoted
    # header is the one place MODE actually needs to reach the deployed,
    # standalone script.
    cat > "$mgmt" << MGMTEOF_HEADER
#!/bin/bash
MODE="${mode}"
MGMTEOF_HEADER
    cat >> "$mgmt" << 'MGMTEOF'
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
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        _warn "open_port не поддерживается для Variant $MODE"
        _info "nginx.conf у Variant $MODE — это stream{}+http{} топология (SNI-роутинг), а не один server{} на conf.d; открытие 8443 через sed сюда неприменимо."
        _info "Для экстренного доступа: rp restart && rp logs nginx"
        return 1
    fi
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    ss -tuln|grep -q ":8443" && { _warn "Порт 8443 занят"; return 1; }
    # UFW lifecycle audit (this session): checked BEFORE touching
    # anything below, and before the `ufw allow` call further down.
    # Confirmed live against a real ufw: `ufw allow 8443/tcp comment
    # "X"` does NOT add a second rule when a `8443/tcp ALLOW IN
    # Anywhere` rule already exists under a *different* comment (or no
    # comment) -- it silently RELABELS that existing rule to comment
    # "X" ("Rule updated"), because ufw treats the underlying spec as
    # one rule slot regardless of comment. So this function's own
    # ownership comment on the rule it adds (see below) cannot, by
    # itself, stop it from taking over -- under a fresh label -- a
    # rule that already belongs to something else (Hysteria2's own
    # documented recommended default port, lib/hy2/install.sh: "1)
    # 8443 — рекомендуется", opened bare/uncommented; or a live Variant
    # J XHTTP rule, if this MODE=1/2 script is stale leftover from
    # before a reinstall to J -- panel_remove() never deletes this
    # generated script). The `ss -tuln` check above only catches a
    # service currently *listening*, not a firewall rule for a service
    # that is merely stopped/not-yet-started, so it does not cover
    # this. Refusing here, before any relabeling can happen, is the
    # only point this can safely be caught at.
    if command -v ufw &>/dev/null; then
        local _existing_8443
        _existing_8443="$(ufw status numbered 2>/dev/null | grep -F '8443/tcp' | grep -vE '# Panel emergency admin[[:space:]]*$' || true)"
        if [ -n "$_existing_8443" ]; then
            _warn "Порт 8443/tcp уже используется другим UFW-правилом (не этой командой) — вероятно, другим сервисом (например, Hysteria2 или Variant J XHTTP). open_port не будет его трогать."
            printf '%s\n' "$_existing_8443" | sed 's/^/  /' >&2
            return 1
        fi
    fi
    sed -i "/server_name $pd;/a \\    listen 8443 ssl;" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    # Tagged with an ownership comment so do_close_port() below can
    # delete exactly this rule, never a same-port rule belonging to
    # something else -- safe now that the check above guarantees no
    # pre-existing, differently-owned 8443/tcp rule exists to relabel.
    ufw allow 8443/tcp comment "Panel emergency admin">/dev/null 2>&1; ufw reload>/dev/null 2>&1
    local ck cv
    ck=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '~\*\K\w+(?==)')
    cv=$(grep "map \$http_cookie" "$nc" -A2|grep -oP '=\K\w+(?=" 1)')
    _ok "Порт 8443 открыт."
    echo -e "  ${WHITE}https://${pd}:8443/auth/login?${ck}=${cv}${NC}"
    _warn "Закройте после работы: remnawave_panel close_port"
}
do_close_port() {
    local ws; ws=$(_detect_ws)
    if [ "$ws" = "caddy" ]; then _warn "Не применимо для Caddy"; return 0; fi
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        _warn "close_port не поддерживается для Variant $MODE (open_port для него никогда не выполнялся — см. rp open_port)"
        return 1
    fi
    local nc="/opt/remnawave/nginx.conf"
    local pd; pd=$(grep -m1 "server_name " "$nc"|awk '{print $2}'|tr -d ';')
    sed -i "/server_name $pd;/,/}/{s/    listen 8443 ssl;//}" "$nc"
    cd /opt/remnawave && docker compose restart remnawave-nginx>/dev/null 2>&1
    # Same finding as do_open_port() above: deletes ONLY the rule this
    # function itself owns (port 8443/tcp AND its own "Panel emergency
    # admin" comment, matched via read-only `ufw status numbered` and
    # removed by rule number -- same technique already proven for
    # panel_cleanup_xhttp_ufw_rules()/panel_cleanup_colocated_api_ufw_rule()
    # in lib/panel/management.sh, inlined here since this is a
    # standalone generated script with no access to that sourced
    # helper). A bare `ufw delete allow 8443/tcp` (this function's old
    # form) matches and removes ANY existing rule on that port
    # regardless of comment -- confirmed live -- which could silently
    # take down Hysteria2 (same default port, no comment of its own)
    # or a live Variant J XHTTP rule (if this MODE=1/2 script is stale
    # leftover from before a reinstall to J; panel_remove() never
    # deletes this generated script).
    if command -v ufw &>/dev/null; then
        local _status _nums _num
        _status="$(ufw status numbered 2>/dev/null)" || _status=""
        _nums="$(printf '%s\n' "$_status" \
            | grep -F "8443/tcp" \
            | grep -E "# Panel emergency admin[[:space:]]*\$" \
            | grep -oE '^\[ *[0-9]+' \
            | grep -oE '[0-9]+' \
            | sort -rn)" || _nums=""
        for _num in $_nums; do
            ufw --force delete "$_num" >/dev/null 2>&1
        done
        ufw reload>/dev/null 2>&1
    fi
    _ok "Порт 8443 закрыт"
}
do_migrate() {
    # A-2 fix: this used to be a standalone reimplementation of Panel
    # migration, but it called six project-specific SSH helpers
    # (ask_ssh_target/init_ssh_helpers/check_ssh_connection/
    # remote_install_deps/RUN/PUT) that were never embedded here -- they
    # only exist in lib/common/ssh.sh, sourced by the normal
    # server-manager.sh runtime, not by this standalone generated
    # script (see this file's own header comment). Embedding a second
    # copy of them here would fork F1-sensitive SSH timeout/signal/
    # argv-security logic (init_ssh_helpers' RUN/PUT) into a
    # separately-maintained duplicate -- not done. Instead, delegate to
    # the already-working migrate_prepare_target()+migrate_transfer_panel()
    # pipeline (lib/migrate.sh, via panel_migrate()) by re-running
    # server-manager.sh itself, using the same source-tree convention
    # migrate_copy_script() already relies on ("${SCRIPT_DIR:-/root/server-manager}"),
    # bootstrapping it via the same curl fallback migrate_copy_script()
    # already uses if it isn't present.
    _info "📦 Перенос Panel на другой сервер"
    local sm_src="${SCRIPT_DIR:-/root/server-manager}"
    if [ -f "${sm_src}/server-manager.sh" ]; then
        exec bash "${sm_src}/server-manager.sh" migrate
    fi
    _warn "server-manager не найден в ${sm_src} — устанавливаем..."
    if curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash >/dev/null 2>&1 \
            && [ -f "${sm_src}/server-manager.sh" ]; then
        _ok "server-manager установлен. Запустите ещё раз: remnawave_panel migrate"
    else
        _warn "Не удалось установить server-manager. Установите вручную и повторите: curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash"
        return 1
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
