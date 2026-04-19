# ████████████████████  MIGRATE SECTION  ███████████████████████████
# panel_migrate() — перенос Panel через migrate_menu
# Вызывает do_migrate из panel.sh если доступна,
# иначе подгружает panel.sh из того же каталога
panel_migrate() {
    if declare -f do_migrate >/dev/null 2>&1; then
        do_migrate
        return $?
    fi
    # Пробуем подгрузить panel.sh
    local _panel_sh
    _panel_sh="$(dirname "${BASH_SOURCE[0]}")/panel.sh"
    if [ -f "$_panel_sh" ]; then
        # shellcheck source=/dev/null
        source "$_panel_sh"
        if declare -f do_migrate >/dev/null 2>&1; then
            do_migrate
            return $?
        fi

        # Совместимость со старыми/кастомными версиями panel.sh,
        # где отдельной do_migrate может не быть.
        if declare -f panel_menu >/dev/null 2>&1; then
            panel_menu migrate
            return $?
        fi

        err "В panel.sh не найдена функция do_migrate/panel_menu."
        return 1
    fi
    err "Модуль panel.sh не найден. Запустите через главное меню."
    return 1
}


# ═══════════════════════════════════════════════════════════════════

migrate_all() {
    header "Перенос всего стека (Panel + MTProxy + Hysteria2)"
    echo ""
    ensure_sshpass

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target || { warn "Ошибка ввода данных SSH"; return 1; }
    init_ssh_helpers full
    check_ssh_connection || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    # ── Зависимости ────────────────────────────────────────────────
    remote_install_deps full

    # ── Panel ──────────────────────────────────────────────────────
    if [ -d /opt/remnawave ] && [ -f /opt/remnawave/docker-compose.yml ]; then
        info "Переносим Panel..."

        # Дамп БД со сжатием
        local dump="/tmp/panel_migrate_$(date +%Y%m%d_%H%M%S).sql.gz"
        cd /opt/remnawave
        docker compose exec -T remnawave-db pg_dumpall -c -U postgres 2>/dev/null | gzip -9 > "$dump"
        local dump_size; dump_size=$(stat -c%s "$dump" 2>/dev/null || echo "0")
        if [ "$dump_size" -lt 1000 ]; then
            warn "Дамп БД подозрительно мал (${dump_size} байт)"
            rm -f "$dump"; return 1
        fi
        ok "Дамп БД создан ($(du -sh "$dump" | cut -f1))"

        # Создаём директорию на новом сервере
        RUN "mkdir -p /opt/remnawave" 2>/dev/null || true

        # Передача файлов по одному — scp надёжнее с явными источниками
        local transfer_ok=true
        local _ws_cfg; [ -f /opt/remnawave/Caddyfile ] && _ws_cfg=/opt/remnawave/Caddyfile || _ws_cfg=/opt/remnawave/nginx.conf
        for _f in "$dump" /opt/remnawave/.env /opt/remnawave/docker-compose.yml "$_ws_cfg"; do
            [ -f "$_f" ] || continue
            PUT "$_f" "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null || { transfer_ok=false; break; }
        done
        if $transfer_ok; then
            ok "Файлы панели переданы"
        else
            warn "Ошибка передачи файлов панели"; rm -f "$dump"; return 1
        fi

        # SSL
        if [ -d /etc/letsencrypt/live ]; then
            RUN "mkdir -p /etc/letsencrypt" 2>/dev/null || true
            local ssl_ok=true
            sshpass -p "$_SSH_PASS" scp -r -P "$rport" -o StrictHostKeyChecking=no \
                /etc/letsencrypt/live \
                /etc/letsencrypt/archive \
                /etc/letsencrypt/renewal \
                "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || ssl_ok=false
            $ssl_ok && ok "SSL сертификаты переданы" || warn "Ошибка передачи SSL"
        fi

        # Caddyfile (если Caddy)
        [ -f /opt/remnawave/Caddyfile ] &&             PUT /opt/remnawave/Caddyfile "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null && ok "Caddyfile передан" || true

        # Selfsteal
        [ -d /var/www/html ] && [ "$(ls -A /var/www/html 2>/dev/null)" ] && \
            PUT /var/www/html/. "${ruser}@${rip}:/var/www/html/" 2>/dev/null && ok "Selfsteal сайт передан" || true

        # Hysteria сертификаты
        [ -d /etc/ssl/certs/hysteria ] && \
            PUT /etc/ssl/certs/hysteria "${ruser}@${rip}:/etc/ssl/certs/" 2>/dev/null \
            && ok "Сертификаты Hysteria2 переданы" || true

        # Восстановление
        local dumpb; dumpb=$(basename "$dump")
        RUN bash -s << RPANEL
set -e; cd /opt/remnawave
docker volume rm remnawave-db-data 2>/dev/null || true
docker compose up -d remnawave-db remnawave-redis >/dev/null 2>&1
# Ждём готовности PostgreSQL через pg_isready вместо фиксированного sleep
_pg_wait=0
until docker compose exec -T remnawave-db pg_isready -U postgres -q 2>/dev/null; do
    sleep 1; _pg_wait=$((_pg_wait+1))
    [ "$_pg_wait" -ge 60 ] && { echo "PostgreSQL не поднялся за 60 сек" >&2; exit 1; }
done
zcat /opt/remnawave/$dumpb | docker compose exec -T remnawave-db psql -U postgres postgres >/dev/null 2>&1 || true
docker compose up -d >/dev/null 2>&1
RPANEL
        rm -f "$dump"; RUN "rm -f /opt/remnawave/$dumpb" 2>/dev/null || true
        PUT /usr/local/bin/remnawave_panel "${ruser}@${rip}:/usr/local/bin/remnawave_panel" 2>/dev/null
        RUN "chmod +x /usr/local/bin/remnawave_panel && grep -q 'alias rp=' /etc/bash.bashrc || echo \"alias rp='remnawave_panel'\" >> /etc/bash.bashrc" 2>/dev/null || true
        ok "Panel перенесена"
    else
        warn "Panel не найдена, пропускаю"
    fi

    # ── MTProxy ────────────────────────────────────────────────────
    if [ -f "$TELEMT_CONFIG_SYSTEMD" ]; then
        info "Переносим MTProxy..."
        local cp dp ub lb
        cp=$(grep -E "^port\s*=" "$TELEMT_CONFIG_SYSTEMD" | head -1 | grep -oE "[0-9]+" || echo "8443")
        dp=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_SYSTEMD" | head -1 | grep -oP '(?<=")[^"]+' || echo "")
        [ -z "$dp" ] && dp="1c.ru"  # fallback если regex не совпал
        ub=$(awk '/^\[access\.users\]/{f=1;next} f&&/^\[/{exit} f&&/=/{print}' "$TELEMT_CONFIG_SYSTEMD")
        if declare -f telemt_extract_limits_block >/dev/null 2>&1; then
            lb=$(telemt_extract_limits_block "$TELEMT_CONFIG_SYSTEMD")
        else
            lb=$(awk '
                /^\[(access\.user_max_tcp_conns|access\.user_expirations|access\.user_data_quota|access\.user_max_unique_ips)\]$/ {
                    in_section=1; print; next
                }
                /^\[access\.user_limits\./ {
                    in_section=1; print; next
                }
                /^\[/ { in_section=0 }
                in_section { print }
            ' "$TELEMT_CONFIG_SYSTEMD" || true)
        fi

        echo "$ub" | RUN "mkdir -p /etc/telemt && { cat << 'NCONF'
[general]
use_middle_proxy = true
log_level = \"normal\"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = \"*\"

[server]
port = $cp

[server.api]
enabled   = true
listen    = \"127.0.0.1:9091\"
whitelist = [\"127.0.0.1/32\"]

[[server.listeners]]
ip = \"0.0.0.0\"

[censorship]
tls_domain    = \"$dp\"
mask          = true
tls_emulation = true
tls_front_dir = \"/opt/telemt/tlsfront\"

[access.users]
NCONF
cat; } > /etc/telemt/telemt.toml"
        [ -n "$lb" ] && echo "$lb" | RUN "echo '' >> /etc/telemt/telemt.toml && cat >> /etc/telemt/telemt.toml"

        RUN bash << RTELEMT
set -e
ARCH=\$(uname -m); LIBC=\$(ldd --version 2>&1|grep -iq musl&&echo musl||echo gnu)
URL="https://github.com/telemt/telemt/releases/latest/download/telemt-\${ARCH}-linux-\${LIBC}.tar.gz"
TMP=\$(mktemp -d); curl -fsSL "\$URL"|tar -xz -C "\$TMP"; install -m 0755 "\$TMP/telemt" /usr/local/bin/telemt; rm -rf "\$TMP"
id telemt &>/dev/null || useradd -d /opt/telemt -m -r -U telemt
mkdir -p /opt/telemt/tlsfront; chown -R telemt:telemt /etc/telemt /opt/telemt
cat > /etc/systemd/system/telemt.service << 'SVC'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecReload=/bin/kill -HUP \$MAINPID
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload; systemctl enable telemt; systemctl restart telemt
command -v ufw &>/dev/null && ufw allow $cp/tcp >/dev/null 2>&1 || true
RTELEMT
        ok "MTProxy перенесён"
    else
        warn "MTProxy (systemd) не найден, пропускаю"
    fi

    # ── Hysteria2 ──────────────────────────────────────────────────
    if hy_is_installed 2>/dev/null && [ -f "$HYSTERIA_CONFIG" ]; then
        info "Переносим Hysteria2..."
        PUT /etc/hysteria/config.yaml "${ruser}@${rip}:/etc/hysteria/" 2>/dev/null
        [ -d /var/lib/hysteria ] && PUT /var/lib/hysteria "${ruser}@${rip}:/var/lib/" 2>/dev/null || true
        # Копируем URI файлы
        for f in /root/hysteria-*.txt; do
            [ -f "$f" ] && PUT "$f" "${ruser}@${rip}:/root/" 2>/dev/null || true
        done
        # Используем официальный установщик — тот же что в hysteria_migrate/hysteria_install
        RUN "curl -fsSL --max-time 30 https://get.hy2.sh/ -o /tmp/hy2-install.sh && bash /tmp/hy2-install.sh; rm -f /tmp/hy2-install.sh && systemctl enable hysteria-server"             || { warn "Ошибка установки Hysteria2 на новом сервере"; }
        # Если использовался HTTP auth — конфиг уже содержит auth.type: http
        # Hysteria стартует с ACME сертификатом из /var/lib/hysteria/acme/ (скопирован выше)
        RUN "systemctl restart hysteria-server" 2>/dev/null || warn "Hysteria2 не запустилась — проверьте конфиг на новом сервере"
        ok "Hysteria2 перенесена"
    else
        warn "Hysteria2 не найдена, пропускаю"
    fi

    # ── Копируем скрипт ────────────────────────────────────────────
    local sm_src="${SCRIPT_DIR:-/root/server-manager}"
    if [ -d "$sm_src" ] && [ -f "${sm_src}/server-manager.sh" ]; then
        RUN "mkdir -p /root/server-manager" 2>/dev/null || true
        PUT "${sm_src}/." "${ruser}@${rip}:/root/server-manager/" 2>/dev/null && \
            RUN "chmod +x /root/server-manager/server-manager.sh && \
                 ln -sf /root/server-manager/server-manager.sh /usr/local/bin/server-manager" \
                2>/dev/null && ok "server-manager установлен на новом сервере" || true
    else
        # Fallback: скачиваем через curl
        RUN "curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash" \
            2>/dev/null && ok "server-manager установлен через curl" || true
    fi

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ ПЕРЕНОС ВСЕГО СТЕКА ЗАВЕРШЁН                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}Следующие шаги:${NC}"
    echo -e "  ${CYAN}1.${NC} Обновите DNS-записи на новый IP: ${CYAN}${rip}${NC}"
    echo -e "  ${CYAN}2.${NC} После обновления DNS перевыпустите SSL:"
    echo -e "     ${CYAN}ssh ${ruser}@${rip} remnawave_panel ssl${NC}"
    echo -e "  ${CYAN}3.${NC} Проверьте работу всех сервисов"
    echo -e "  ${CYAN}4.${NC} Остановите старые сервисы когда всё ОК"
    echo ""

    read -rp "  Остановить все сервисы на ЭТОМ сервере? (y/n): " stop_old < /dev/tty
    if [[ "$stop_old" =~ ^[yY]$ ]]; then
        [ -d /opt/remnawave ] && cd /opt/remnawave && docker compose stop >/dev/null 2>&1 && ok "Panel остановлена"
        systemctl stop telemt 2>/dev/null && ok "MTProxy остановлен" || true
        systemctl stop hysteria-server 2>/dev/null && ok "Hysteria2 остановлена" || true
    fi
}

migrate_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  📦  Перенос сервисов${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} 🛡️   Перенести Remnawave Panel"
        echo -e "  ${BOLD}2)${RESET} 📡  Перенести MTProxy (telemt)"
        echo -e "  ${BOLD}3)${RESET} 🚀  Перенести Hysteria2"
        echo -e "  ${BOLD}4)${RESET} 📦  Перенести всё (Panel + MTProxy + Hysteria2)"
        echo -e "  ${BOLD}5)${RESET} 💾  Бэкап / Восстановление (backup-restore)"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_migrate || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) { [ -z "$TELEMT_MODE" ] && {
                       TELEMT_MODE="systemd"
                       TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"
                       TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD"
                   }
                   telemt_menu_migrate; } || true
               read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            3) hysteria_migrate || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            4) { check_root; migrate_all; } || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            5) panel_backup_restore || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_backup_restore() {
    header "Бэкап / Восстановление"
    local script_url="https://raw.githubusercontent.com/Remnawave/backup-restore/main/backup-restore.sh"
    local script_path="/usr/local/bin/remnawave-backup"

    if command -v remnawave-backup &>/dev/null; then
        info "backup-restore уже установлен — запускаем..."
        remnawave-backup
        return
    fi

    info "Скачиваем backup-restore скрипт..."
    if curl -fsSL "$script_url" -o "$script_path" 2>/dev/null; then
        chmod +x "$script_path"
        ok "backup-restore установлен: $script_path"
        remnawave-backup
    else
        warn "Не удалось скачать скрипт"
        echo -e "  Установите вручную:"
        echo -e "  ${CYAN}curl -fsSL $script_url | bash${NC}"
        return 1
    fi
}


