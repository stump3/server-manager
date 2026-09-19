# ████████████████████  MIGRATE SECTION  ███████████████████████████
# panel_migrate() — перенос только Panel (см. migrate_all() для полного
# стека Panel+MTProxy+Hysteria2). Раньше эта функция искала do_migrate()
# через `declare -f` (наследие архитектуры, где ожидалось, что do_migrate
# станет обычной sourced-функцией) — это никогда не могло сработать:
# do_migrate существует только как текст heredoc внутри генерируемого
# /usr/local/bin/remnawave_panel (lib/panel/mgmt_script.sh), а не как
# функция в этом процессе. Фоллбэк на `panel_menu migrate` тоже был
# мёртвым на практике: panel_menu() не принимает аргументов вообще, так
# что "migrate" молча игнорировался, и оператор просто попадал в общее
# меню Panel. Вместо этого вызываем тот же рабочий Panel-transfer пайплайн,
# которым уже пользуется migrate_all() для своей Panel-части.
panel_migrate() {
    header "📦 Перенос Panel на другой сервер"
    migrate_prepare_target panel || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"
    migrate_transfer_panel
}


# ═══════════════════════════════════════════════════════════════════

migrate_prepare_target() {
    # A-2 follow-up: this used to always request "full" dependency
    # installation (remote_install_deps full ...) regardless of caller,
    # even when called from panel_migrate() -- a Panel-only transfer.
    # remote_install_deps's own docstring: "full — base + unzip cron
    # qrencode + /etc/hysteria" (lib/common/ssh.sh) -- none of which a
    # Panel-only migration needs; the pre-A-2 do_migrate() correctly
    # used "panel" here (`remote_install_deps panel "$(_detect_ws)"`).
    # init_ssh_helpers's own mode branching only distinguishes "telemt"
    # from everything else (panel and full hit the same `*` case,
    # producing identical _SSH_OPTS/_SCP_OPTS) -- passing the variant
    # through there is harmless/for-consistency, not a functional fix.
    # Default stays "full" so migrate_all()'s existing no-argument call
    # (below) is byte-for-byte unaffected.
    local variant="${1:-full}"
    ensure_sshpass

    # ── Данные нового сервера ──────────────────────────────────────
    ask_ssh_target || { warn "Ошибка ввода данных SSH"; return 1; }
    init_ssh_helpers "$variant"
    check_ssh_connection || return 1

    # ── Зависимости ────────────────────────────────────────────────
    local _remote_ws="nginx"
    [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnawave-caddy" /opt/remnawave/docker-compose.yml && _remote_ws="caddy"
    remote_install_deps "$variant" "$_remote_ws"
    return 0
}

# ═══════════════════════════════════════════════════════════════════

migrate_transfer_panel_ssl() {
    # SSL
    if [ -d /etc/letsencrypt/live ]; then
        RUN "mkdir -p /etc/letsencrypt" 2>/dev/null || true
        local ssl_ok=true
        # SSH-02 same-class fix (docs/LEGACY_AUDIT.md §8 / contract 7):
        # same $_SSH_PASS variable as lib/common/ssh.sh's RUN/PUT (already
        # fixed), set up by the same ask_ssh_target/init_ssh_helpers full
        # chain in migrate_prepare_target() earlier in migrate_all()'s
        # flow — identical execution context, not a new decision. Only
        # the argv-exposure mechanism changes; -r/-P/StrictHostKeyChecking
        # and the multi-source scp invocation are otherwise unchanged.
        sshpass -f <(printf '%s\n' "$_SSH_PASS") scp -r -P "$rport" -o StrictHostKeyChecking=no \
            /etc/letsencrypt/live \
            /etc/letsencrypt/archive \
            /etc/letsencrypt/renewal \
            "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || ssl_ok=false
        $ssl_ok && ok "SSL сертификаты переданы" || warn "Ошибка передачи SSL"
    fi
}


# migrate_dest_existing_state_detected — remote analog of
# panel_install_existing_state_detected() (lib/panel/install.sh): true if
# the DESTINATION server already has the remnawave-db-data named Docker
# volume, i.e. an existing Panel installation whose data
# migrate_transfer_panel() below is about to overwrite/destroy. Same
# identity check, same semantics -- executed over RUN (which returns the
# remote command's exact exit code, lib/common/ssh.sh) instead of
# locally. `command -v docker` is checked first, same as the local
# version, so a genuinely blank destination (no Docker yet) correctly
# reads as "no existing state" rather than erroring.
migrate_dest_existing_state_detected() {
    RUN "command -v docker >/dev/null 2>&1 && docker volume inspect remnawave-db-data >/dev/null 2>&1" 2>/dev/null
}

migrate_transfer_panel() {
    if [ -d /opt/remnawave ] && [ -f /opt/remnawave/docker-compose.yml ]; then
        info "Переносим Panel..."

        # CONFIRMED DEFECT (lifecycle audit, migration destination-DB
        # pass): everything below this point -- PUT overwriting the
        # destination's .env/docker-compose.yml, then `docker volume rm
        # remnawave-db-data` followed by restoring this run's
        # `pg_dumpall -c` dump -- silently destroyed any ALREADY-EXISTING
        # Panel installation on the destination, with no confirmation of
        # any kind. `pg_dumpall -c` itself emits DROP DATABASE/DROP ROLE
        # statements ahead of the restore, so the destination's existing
        # data was lost even on the branch where `docker volume rm`
        # fails silently because a running container still holds the
        # volume open -- precisely the case a live existing install
        # produces. This is the same class of operation
        # panel_remove()/panel_reinstall() (lib/panel/management.sh) both
        # gate behind an explicit warning + typed 'YES' confirmation;
        # migrate had no destination-side equivalent, only
        # panel_install_existing_state_detected() for the LOCAL side of a
        # plain install. Fix: same detection semantics via
        # migrate_dest_existing_state_detected() above, gated the same
        # way as panel_reinstall()'s own confirmation prompt, placed
        # before ANY destination mutation begins (PUT included).
        if migrate_dest_existing_state_detected; then
            warn "На новом сервере уже обнаружена существующая установка Panel (volume remnawave-db-data)."
            warn "Продолжение ПЕРЕЗАПИШЕТ конфигурацию и УНИЧТОЖИТ текущие данные БД на новом сервере!"
            local _dest_confirm
            read -rp "  Продолжить и перезаписать данные на новом сервере? Введите 'YES': " _dest_confirm < /dev/tty
            if [ "$_dest_confirm" != "YES" ]; then
                info "Перенос отменён"
                return 1
            fi
        fi

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

        migrate_transfer_panel_ssl

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
        # RPANEL is an UNQUOTED heredoc: the local shell expands every
        # unescaped $name/$((...)) while building the text, before
        # `RUN bash -s` runs. $dumpb below is intentionally expanded
        # locally (baked into the remote script as a literal filename).
        # _pg_wait is a REMOTE-only loop counter, so its reads are
        # escaped (\$) — unescaped, `set -u` (server-manager.sh:13)
        # aborts the local process with "_pg_wait: unbound variable"
        # before RUN is invoked.
        local dumpb; dumpb=$(basename "$dump")
        RUN bash -s << RPANEL
set -e; cd /opt/remnawave
docker volume rm remnawave-db-data 2>/dev/null || true
docker compose up -d remnawave-db remnawave-redis >/dev/null 2>&1
# Ждём готовности PostgreSQL через pg_isready вместо фиксированного sleep
_pg_wait=0
until docker compose exec -T remnawave-db pg_isready -U postgres -q 2>/dev/null; do
    sleep 1; _pg_wait=\$((_pg_wait+1))
    [ "\$_pg_wait" -ge 60 ] && { echo "PostgreSQL не поднялся за 60 сек" >&2; exit 1; }
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
    return 0
}

migrate_transfer_mtproxy() {
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
    return 0
}

migrate_transfer_hysteria() {
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
    return 0
}

migrate_copy_script() {
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
    return 0
}

migrate_summary() {
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

migrate_all() {
    header "Перенос всего стека (Panel + MTProxy + Hysteria2)"
    echo ""
    migrate_prepare_target || return 1
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    migrate_transfer_panel || return 1

    migrate_transfer_mtproxy

    migrate_transfer_hysteria

    migrate_copy_script

    migrate_summary
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
        echo -e "  ${BOLD}0)${RESET}  ◀️ Назад"
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
