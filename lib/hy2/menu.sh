# shellcheck shell=bash
# Hysteria2: меню, миграция и sub-режимы

# ── Простые действия (были в старом hysteria.sh) ─────────────────────────────
hysteria_logs() {
    header "Hysteria2 — Логи"
    journalctl -u "${HYSTERIA_SVC:-hysteria-server}" -n 80 --no-pager 2>/dev/null \
        || warn "Логи недоступны"
}

hysteria_status() {
    header "Hysteria2 — Статус"
    hy_is_installed 2>/dev/null \
        && echo -e "  Версия:  $(hysteria version 2>/dev/null | head -1)"
    systemctl --no-pager status "${HYSTERIA_SVC:-hysteria-server}" 2>/dev/null \
        || warn "Сервис не найден"
}

hysteria_restart() {
    systemctl restart "${HYSTERIA_SVC:-hysteria-server}" \
        && ok "Hysteria2 перезапущен" || warn "Ошибка перезапуска"
}

hysteria_migrate() {
    header "Hysteria2 — Перенос на новый сервер"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Hysteria2 не установлена на этом сервере"; return 1; }
    ensure_sshpass

    ask_ssh_target
    init_ssh_helpers hysteria
    local rip="$_SSH_IP" rport="$_SSH_PORT" ruser="$_SSH_USER"

    info "Проверка подключения..."
    RUN echo ok >/dev/null 2>&1 || { err "Не удалось подключиться к ${rip}:${rport}"; return 1; }
    ok "Подключение успешно"

    # Получаем домен из конфига
    local domain hy_port
    domain=$(hy_get_domain)
    hy_port=$(hy_get_port)

    # 1. Установка Hysteria2 на новом сервере
    info "Установка Hysteria2 на новом сервере..."
    RUN "curl -fsSL --max-time 30 https://get.hy2.sh/ -o /tmp/hy2-install.sh && bash /tmp/hy2-install.sh; rm -f /tmp/hy2-install.sh" || { err "Ошибка установки"; return 1; }
    ok "Hysteria2 установлен"

    # 2. Копирование конфига
    info "Копирование конфигурации..."
    RUN "mkdir -p /etc/hysteria"
    PUT "$HYSTERIA_CONFIG" "${ruser}@${rip}:/etc/hysteria/config.yaml"
    ok "Конфиг скопирован"

    # 3. Копирование сертификата Let's Encrypt
    if [ -d "/etc/letsencrypt/live/${domain}" ]; then
        info "Копирование SSL-сертификата..."
        RUN "mkdir -p /etc/letsencrypt"
        PUT /etc/letsencrypt/live    "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || true
        PUT /etc/letsencrypt/archive "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || true
        PUT /etc/letsencrypt/renewal "${ruser}@${rip}:/etc/letsencrypt/" 2>/dev/null || true
        ok "Сертификат скопирован (действует до истечения, затем обновится автоматически)"
    else
        warn "Сертификат /etc/letsencrypt/live/${domain} не найден — Hysteria переиздаст его через ACME после смены DNS"
    fi

    # 4. Открытие портов и запуск
    info "Открытие портов и запуск сервиса..."
    RUN bash << REMOTE
ufw allow 22/tcp  >/dev/null 2>&1 || true
ufw allow ${hy_port}/udp >/dev/null 2>&1 || true
ufw allow ${hy_port}/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
apt-get install -y qrencode >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now hysteria-server
REMOTE
    ok "Сервис запущен на новом сервере"

    # 5. Копирование URI-файлов
    # Копируем URI-файлы с явной проверкой — glob в scp без файлов передаёт литеральную строку с *
    for _f in /root/hysteria-${domain}*.txt /root/hysteria-${domain}*.yaml; do
        [ -f "$_f" ] && PUT "$_f" "${ruser}@${rip}:/root/" 2>/dev/null || true
    done

    # 6. Копирование этого скрипта
    local script_path; script_path=$(realpath "$0" 2>/dev/null || echo "/root/server-manager.sh")
    PUT "$script_path" "${ruser}@${rip}:${script_path}" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅  Перенос Hysteria2 завершён                    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}Следующие шаги:${NC}"
    echo ""
    echo -e "  ${WHITE}1. Обновите DNS A-запись:${NC}"
    echo -e "     ${CYAN}${domain}${NC}  →  ${WHITE}${rip}${NC}"
    echo ""
    echo -e "  ${WHITE}2. После обновления DNS сертификат обновится автоматически.${NC}"
    echo ""
    echo -e "  ${WHITE}3. Проверьте работу на новом сервере, затем остановите старый:${NC}"
    echo -e "     ${CYAN}systemctl stop hysteria-server${NC}"
    echo ""

    # ── Мониторинг DNS и автоматический перезапуск ────────────────
    local wait_dns
    read -rp "  Ждать обновления DNS и автоматически перезапустить сервис? (y/N): " wait_dns < /dev/tty
    if [[ "${wait_dns:-N}" =~ ^[yY]$ ]]; then
        echo ""
        info "Мониторинг DNS: ожидаем когда ${domain} → ${rip}"
        info "Проверка каждые 30 секунд. Ctrl+C для отмены."
        echo ""

        local attempt=0 max_attempts=120  # максимум 60 минут
        local resolved_ip=""

        while true; do
            attempt=$((attempt + 1))
            resolved_ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)

            printf "  [%3d] %s → %s" "$attempt" "$domain" "${resolved_ip:-не резолвится}"

            if [ "$resolved_ip" = "$rip" ]; then
                echo ""
                echo ""
                ok "DNS обновлён: ${domain} → ${rip}"
                echo ""
                info "Перезапускаем hysteria-server на новом сервере..."
                if RUN "systemctl restart hysteria-server" 2>/dev/null; then
                    ok "Сервис перезапущен — ACME переиздаст сертификат автоматически"
                    echo ""
                    info "Проверка статуса через 10 секунд..."
                    sleep 10
                    local svc_status
                    svc_status=$(RUN "systemctl is-active hysteria-server" 2>/dev/null || echo "unknown")
                    if [ "$svc_status" = "active" ]; then
                        ok "hysteria-server активен ✓"
                    else
                        warn "Сервис не запустился. Проверьте логи:"
                        echo -e "     ${CYAN}ssh ${ruser}@${rip} journalctl -u hysteria-server -n 30${NC}"
                    fi
                else
                    warn "Не удалось перезапустить сервис. Перезапустите вручную:"
                    echo -e "     ${CYAN}ssh ${ruser}@${rip} systemctl restart hysteria-server${NC}"
                fi
                echo ""
                echo -e "  ${YELLOW}Убедитесь что всё работает, затем остановите старый сервер:${NC}"
                echo -e "     ${CYAN}systemctl stop hysteria-server${NC}"
                echo ""
                break
            else
                # Показываем прогресс-бар ожидания 30 секунд
                printf " — ожидание"
                for i in $(seq 1 6); do
                    sleep 5
                    printf "."
                done
                printf "
[K"
            fi

            if [ "$attempt" -ge "$max_attempts" ]; then
                echo ""
                warn "Таймаут 60 минут. DNS так и не обновился."
                warn "Обновите DNS вручную и перезапустите сервис:"
                echo -e "     ${CYAN}ssh ${ruser}@${rip} systemctl restart hysteria-server${NC}"
                break
            fi
        done
    fi
}

hysteria_merge_sub() {
    header "Hysteria2 — Объединённая подписка"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Hysteria2 не установлена"; return 1; }
    command -v python3 &>/dev/null || { warn "Требуется python3"; return 1; }

    local dom
    dom=$(hy_get_domain)

    # Собираем URI Hysteria2
    local -a hy_uris=()
    for f in "/root/hysteria-${dom}.txt" "/root/hysteria-${dom}-users.txt"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^hy2:// ]] && hy_uris+=("$line")
        done < "$f"
    done
    [ ${#hy_uris[@]} -eq 0 ] && { warn "URI Hysteria2 не найдены"; return 1; }

    # Домен подписок из .env
    local sub_domain=""
    [ -f /opt/remnawave/.env ] && sub_domain=$(grep "^SUB_PUBLIC_DOMAIN=" /opt/remnawave/.env | cut -d= -f2 | tr -d ' ')
    if [ -z "$sub_domain" ]; then
        read -rp "  Домен подписок Remnawave (sub.example.com): " sub_domain < /dev/tty
    fi
    info "Домен подписок: $sub_domain"

    # Selfsteal домен
    local selfsteal_dom=""
    if [ -f /opt/remnawave/nginx.conf ]; then
        selfsteal_dom=$(grep -B3 "root /var/www/html" /opt/remnawave/nginx.conf | grep "server_name" | awk '{print $2}' | tr -d ';' | head -1)
    fi

    local merge_name
    read -rp "  Имя endpoint'а [hy-merge]: " merge_name < /dev/tty
    merge_name="${merge_name:-hy-merge}"

    # Записываем URI в файл для merger скрипта
    local hy_uris_file="/etc/hy-merger-uris.txt"
    printf '%s\n' "${hy_uris[@]}" > "$hy_uris_file"
    ok "URI сохранены: $hy_uris_file (${#hy_uris[@]} шт.)"

    # Создаём Python merger скрипт
    local script_path="/usr/local/bin/hy_sub_merger.py"
    cat > "$script_path" << 'PYEOF'
#!/usr/bin/env python3
import http.server, urllib.request, base64, ssl, os

HY_URIS_FILE = "/etc/hy-merger-uris.txt"
SUB_DOMAIN = os.environ.get("SUB_DOMAIN", "")
PORT = int(os.environ.get("MERGER_PORT", "18080"))

def get_hy_uris():
    try:
        with open(HY_URIS_FILE) as f:
            return [l.strip() for l in f if l.strip().startswith("hy2://")]
    except:
        return []

class MergerHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        token = self.path.strip("/")
        if not token:
            self.send_response(404); self.end_headers(); return
        rw_uris = []
        try:
            ctx = ssl.create_default_context()
            url = f"https://{SUB_DOMAIN}/{token}"
            req = urllib.request.Request(url, headers={"User-Agent": "clash"})
            with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                raw = resp.read()
            try:
                decoded = base64.b64decode(raw).decode("utf-8")
            except:
                decoded = raw.decode("utf-8")
            rw_uris = [l for l in decoded.splitlines() if l.strip()]
        except Exception as e:
            pass
        all_uris = rw_uris + get_hy_uris()
        merged = base64.b64encode("\n".join(all_uris).encode()).decode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Profile-Update-Interval", "12")
        self.end_headers()
        self.wfile.write(merged.encode())

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), MergerHandler)
    print(f"Merger running on port {PORT}", flush=True)
    server.serve_forever()
PYEOF
    chmod +x "$script_path"
    ok "Merger скрипт: $script_path"

    # Systemd сервис
    cat > /etc/systemd/system/hy-merger.service << SVCEOF
[Unit]
Description=Hysteria2 Subscription Merger
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/hy_sub_merger.py
Restart=always
RestartSec=5
Environment=MERGER_PORT=18080
Environment=SUB_DOMAIN=${sub_domain}

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable --now hy-merger
    sleep 2
    if systemctl is-active --quiet hy-merger; then
        ok "Сервис hy-merger запущен"
    else
        warn "Сервис не запустился: journalctl -u hy-merger -n 20"
        return 1
    fi

    # Добавляем location в nginx конфиг панели
    if [ -f /opt/remnawave/nginx.conf ]; then
        if grep -q "hy-merger" /opt/remnawave/nginx.conf; then
            info "location уже есть в nginx.conf"
        else
            local loc_block="
    # Hysteria2 merged subscription
    location ~* ^/${merge_name}/(.+)\$ {
        proxy_pass http://127.0.0.1:18080/\$1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }"
            # Вставляем перед "root /var/www/html"
            sed -i "s|    root /var/www/html; index index.html;|${loc_block}\n    root /var/www/html; index index.html;|" /opt/remnawave/nginx.conf
            cd /opt/remnawave && docker compose restart remnawave-nginx >/dev/null 2>&1
            ok "location добавлен в nginx, перезапущен"
        fi
    else
        warn "nginx.conf не найден — добавьте location вручную"
    fi

    echo ""
    echo -e "  ${GREEN}══════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  Объединённая подписка готова!${NC}"
    echo -e "  ${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    if [ -n "$selfsteal_dom" ]; then
        echo -e "  ${CYAN}Ссылка (вместо оригинальной Remnawave):${NC}"
        echo -e "  ${WHITE}https://${selfsteal_dom}/${merge_name}/ТОКЕН${NC}"
        echo ""
        echo -e "  ${GRAY}Пример: https://${selfsteal_dom}/${merge_name}/uR5UffbwYXMA${NC}"
    else
        echo -e "  https://SELFSTEAL_DOMAIN/${merge_name}/ТОКЕН"
    fi
    echo ""
    echo -e "  ${YELLOW}Обновить URI Hysteria (после добавления пользователей):${NC}"
    echo -e "  ${CYAN}printf '%s\\n' \$(cat /root/hysteria-*.txt | grep hy2://) > /etc/hy-merger-uris.txt${NC}"
    echo -e "  ${CYAN}systemctl restart hy-merger${NC}"
}


hysteria_publish_sub() {
    header "Hysteria2 — Опубликовать подписку"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Hysteria2 не установлена"; return 1; }

    local dom; dom=$(hy_get_domain)
    local port; port=$(hy_get_port)

    # Собираем все URI из файлов
    local -a uris=()
    for f in "/root/hysteria-${dom}.txt" "/root/hysteria-${dom}-users.txt"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^hy2:// ]] && uris+=("$line")
        done < "$f"
    done

    if [ ${#uris[@]} -eq 0 ]; then
        warn "URI не найдены в /root/hysteria-${dom}*.txt"
        return 1
    fi

    info "Найдено URI: ${#uris[@]}"
    echo ""

    # Кодируем в base64
    local sub_content; sub_content=$(printf '%s
' "${uris[@]}" | base64 -w 0)

    # Путь для публикации
    local sub_dir="/var/www/html/sub"
    local sub_file="${sub_dir}/${dom}"
    mkdir -p "$sub_dir"
    echo "$sub_content" > "$sub_file"
    chmod 644 "$sub_file"
    ok "Подписка сохранена: $sub_file"

    # Ищем порт Nginx (не 443, не внутренний)
    local nginx_port=""
    [ -f /opt/remnawave/nginx.conf ] &&         nginx_port=$(grep -E "listen [0-9]+" /opt/remnawave/nginx.conf | grep -v "443\|ssl\|127\." |             awk '{print $2}' | tr -d ';' | head -1)

    echo ""
    echo -e "  ${CYAN}Ссылка на подписку:${NC}"
    if [ -n "$nginx_port" ]; then
        echo -e "  ${WHITE}http://${dom}:${nginx_port}/sub/${dom}${NC}"
    else
        echo -e "  ${WHITE}http://${dom}/sub/${dom}${NC}"
        echo -e "  ${GRAY}(убедитесь что Nginx отдаёт /var/www/html/sub/)${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Содержимое (base64):${NC}"
    echo "  $sub_content" | head -c 80
    echo "..."
    echo ""
    read -rp "  Enter для возврата..." < /dev/tty
}

hysteria_menu() {
    # Загружаем данные один раз при входе (hy_get_domain_port — один проход файла)
    local ver dom port dp
    ver=$(get_hysteria_version 2>/dev/null || true)
    dp=$(hy_get_domain_port 2>/dev/null || true)
    dom="${dp%%:*}"
    port="${dp##*:}"
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  🚀  Hysteria2${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────────${NC}"
        if [ -n "$ver" ] || [ -n "$dom" ]; then
            [ -n "$ver" ] && echo -e "  ${GRAY}Версия  ${NC}${ver}"
            [ -n "$dom" ] && echo -e "  ${GRAY}Сервер  ${NC}${dom}${port:+:$port}"
            echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  🔧  Установка"
        echo -e "  ${BOLD}2)${RESET}  ⚙️  Управление"
        echo -e "  ${BOLD}3)${RESET}  👥  Пользователи"
        echo -e "  ${BOLD}4)${RESET}  🔗  Подписка"
        echo -e "  ${BOLD}5)${RESET}  📦  Миграция на другой сервер"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_install || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            2) hysteria_submenu_manage || true ;;
            3) hysteria_submenu_users || true ;;
            4) hysteria_submenu_sub || true ;;
            5) hysteria_migrate || true; read -rp "Enter..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

hysteria_submenu_manage() {
    while true; do
        clear
        header "Hysteria2 — Управление"
        echo -e "  ${BOLD}1)${RESET} 📊  Статус"
        echo -e "  ${BOLD}2)${RESET} 📋  Логи"
        echo -e "  ${BOLD}3)${RESET} 🔄  Перезапустить"
        echo -e "  ${BOLD}4)${RESET} 🗑️   Удалить полностью"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_status || true; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_logs || true;   read -rp "Enter..." < /dev/tty ;;
            3) hysteria_restart || true; read -rp "Enter..." < /dev/tty ;;
            4) hysteria_uninstall || true; read -rp "  Нажмите Enter для продолжения..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

hysteria_submenu_users() {
    while true; do
        clear
        header "Hysteria2 — Пользователи"
        echo -e "  ${BOLD}1)${RESET} ➕  Добавить пользователя"
        echo -e "  ${BOLD}2)${RESET} ➖  Удалить пользователя"
        echo -e "  ${BOLD}3)${RESET} 👥  Пользователи и ссылки"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_add_user || true; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_delete_user || true; read -rp "Enter..." < /dev/tty ;;
            3) hysteria_show_links || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

hysteria_submenu_sub() {
    while true; do
        clear
        header "Hysteria2 — Подписка"
        echo -e "  ${BOLD}1)${RESET} 📤  Опубликовать подписку"
        echo -e "  ${BOLD}2)${RESET} 🔗  Объединить с подпиской Remnawave (merger)"
        echo -e "  ${BOLD}3)${RESET} 🪝  Интеграция с Remnawave (webhook + sub-page)"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_publish_sub || true; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_merge_sub || true; read -rp "Enter..." < /dev/tty ;;
            3) hysteria_remnawave_integration || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}
