# ████████████████████  MIGRATE SECTION  ███████████████████████████
# ═══════════════════════════════════════════════════════════════════

migrate_all() {
    header "Перенос всего стека (Panel + MTProxy + Hysteria2)"
    echo ""
    ensure_sshpass

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target
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
            err "Дамп БД подозрительно мал (${dump_size} байт)"
            rm -f "$dump"; return 1
        fi
        ok "Дамп БД создан ($(du -sh "$dump" | cut -f1))"

        # Передача файлов
        PUT "$dump" /opt/remnawave/.env /opt/remnawave/docker-compose.yml /opt/remnawave/nginx.conf \
            "${ruser}@${rip}:/opt/remnawave/" 2>/dev/null && ok "Файлы панели переданы" \
            || { err "Ошибка передачи файлов панели"; rm -f "$dump"; return 1; }

        # SSL
        [ -d /etc/letsencrypt/live ] && \
            PUT /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal \
                "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null \
            && ok "SSL сертификаты переданы" || warn "Ошибка передачи SSL"

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
sleep 20
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
        dp=$(grep -E "^tls_domain\s*=" "$TELEMT_CONFIG_SYSTEMD" | head -1 | grep -oP '(?<="K)[^"]+' || echo "petrovich.ru")
        ub=$(awk '/^\[access\.users\]/{f=1;next} f&&/^\[/{exit} f&&/=/{print}' "$TELEMT_CONFIG_SYSTEMD")
        lb=$(awk '/^\[access\.user_limits\./{f=1} f{print}' "$TELEMT_CONFIG_SYSTEMD" || true)

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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
        RUN "bash <(curl -fsSL https://get.hy2.sh/) && systemctl enable hysteria-server && systemctl restart hysteria-server" \
            || { warn "Ошибка установки Hysteria2 на новом сервере"; }
        ok "Hysteria2 перенесена"
    else
        warn "Hysteria2 не найдена, пропускаю"
    fi

    # ── Копируем скрипт ────────────────────────────────────────────
    PUT "$0" "${ruser}@${rip}:/root/server-manager.sh" 2>/dev/null && \
        RUN "chmod +x /root/server-manager.sh" 2>/dev/null && ok "server-manager.sh скопирован" || true

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
