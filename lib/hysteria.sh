# ███████████████████  HYSTERIA2 SECTION  ██████████████████████████
# ═══════════════════════════════════════════════════════════════════



hy_is_installed() { command -v hysteria &>/dev/null; }

hy_is_running() { systemctl is-active --quiet hysteria-server 2>/dev/null; }

hy_port_is_free() {
    local p="$1"
    ss -tulpn 2>/dev/null | awk '{print $5}' | grep -qE ":${p}$" && return 1 || return 0
}

hy_port_label() {
    local p="$1"
    if hy_port_is_free "$p"; then
        echo "свободен ✓"
    else
        local proc
        proc=$(ss -tulpn 2>/dev/null | awk '{print $5,$7}' | grep ":${p} " \
            | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
        [ -n "$proc" ] && echo "занят ($proc) ✗" || echo "занят ✗"
    fi
}

hy_is_valid_fqdn() {
    local d="$1"
    [[ "$d" == *.* ]] || return 1
    [[ "${#d}" -le 253 ]] || return 1
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

hy_get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" \
               "https://icanhazip.com" "https://checkip.amazonaws.com"; do
        ip="$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d ' \r\n' || true)"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

hy_resolve_a() {
    local domain="$1"
    if command -v dig &>/dev/null; then
        dig +short A "$domain" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+\.' || true
    else
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.' || true
    fi
}

# ── Вспомогательные функции для чтения конфига ───────────────────
hy_get_domain() {
    [ -f "$HYSTERIA_CONFIG" ] || { echo ""; return 1; }
    awk '/domains:/{f=1;next} f&&/^  - /{gsub(/[[:space:]]*-[[:space:]]*/,""); print; exit}' "$HYSTERIA_CONFIG"
}

hy_get_port() {
    [ -f "$HYSTERIA_CONFIG" ] || { echo ""; return 1; }
    awk '/^listen:/{match($0,/[0-9]+$/); print substr($0,RSTART,RLENGTH); exit}' "$HYSTERIA_CONFIG"
}

# Читает домен и порт за один проход файла (быстрее двух отдельных вызовов)
hy_get_domain_port() {
    [ -f "$HYSTERIA_CONFIG" ] || { echo ":"; return 1; }
    awk '
        /^listen:/{match($0,/[0-9]+$/); port=substr($0,RSTART,RLENGTH)}
        /domains:/{f=1; next}
        f&&/^  - /{gsub(/[[:space:]]*-[[:space:]]*/,""); dom=$0; f=0}
        END{print dom ":" port}
    ' "$HYSTERIA_CONFIG"
}

# ── Установка ─────────────────────────────────────────────────────
hysteria_install() {
    step "Установка / Переустановка Hysteria2"

    # ── Переустановка ──────────────────────────────────────────────
    if hy_is_installed; then
        echo ""
        echo -e "  ${YELLOW}Hysteria2 уже установлена.${NC}"
        echo -e "  ${BOLD}1)${RESET} Переустановить (сохранить пользователей и настройки)"
        echo -e "  ${BOLD}2)${RESET} Переустановить полностью (сброс конфига)"
        echo -e "  ${BOLD}0)${RESET} Отмена"
        echo ""
        local reinstall_ch
        read -rp "  Выбор: " reinstall_ch < /dev/tty
        case "$reinstall_ch" in
            1)
                info "Переустановка с сохранением конфига..."
                local backup_cfg="/tmp/hysteria_backup_$(date +%Y%m%d_%H%M%S).yaml"
                cp "$HYSTERIA_CONFIG" "$backup_cfg" 2>/dev/null && info "Конфиг сохранён: $backup_cfg"
                systemctl stop "$HYSTERIA_SVC" 2>/dev/null || true
                bash <(curl -fsSL https://get.hy2.sh/) || { err "Ошибка установки"; return 1; }
                cp "$backup_cfg" "$HYSTERIA_CONFIG"
                systemctl restart "$HYSTERIA_SVC"
                ok "Hysteria2 переустановлена, конфиг восстановлен"
                return 0
                ;;
            2)
                warn "Конфиг будет удалён!"
                read -rp "  Продолжить? (y/N): " _yn < /dev/tty
                [[ "${_yn:-N}" =~ ^[yY]$ ]] || return 1
                systemctl stop "$HYSTERIA_SVC" 2>/dev/null || true
                rm -f "$HYSTERIA_CONFIG"
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор"; return 1 ;;
        esac
    fi

    # ── Домен ──────────────────────────────────────────────────────
    local domain=""
    while true; do
        read -rp "  Домен (например cdn.example.com): " domain < /dev/tty
        hy_is_valid_fqdn "$domain" && break
        warn "Некорректный домен. Нужен FQDN вида sub.example.com"
    done

    # ── Email ──────────────────────────────────────────────────────
    local email=""
    read -rp "  Email для ACME (необязателен, Enter — пропустить): " email < /dev/tty
    email="${email// /}"

    # ── CA ─────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Центр сертификации (CA):${NC}"
    echo "  ┌──────────────────────────────────────────────────────────────────┐"
    echo "  │  1) Let's Encrypt  — стандарт, рекомендуется                    │"
    echo "  │  2) ZeroSSL        — резерв если Let's Encrypt заблокирован      │"
    echo "  │  3) Buypass        — сертификат на 180 дней вместо 90            │"
    echo "  └──────────────────────────────────────────────────────────────────┘"
    local ca_choice="" ca_name ca_label
    while [[ ! "$ca_choice" =~ ^[123]$ ]]; do
        read -rp "  Выбор [1]: " ca_choice < /dev/tty
        ca_choice="${ca_choice:-1}"
    done
    case "$ca_choice" in
        1) ca_name="letsencrypt"; ca_label="Let's Encrypt" ;;
        2) ca_name="zerossl";     ca_label="ZeroSSL" ;;
        3) ca_name="buypass";     ca_label="Buypass" ;;
    esac
    ok "CA: $ca_label"

    # ── Порт / Port Hopping ────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Режим порта:${NC}"
    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │  1) Один порт      — стандарт                          │"
    echo "  │  2) Port Hopping   — диапазон UDP (обход блокировок)   │"
    echo "  └────────────────────────────────────────────────────────┘"
    local port_mode=""
    while [[ ! "$port_mode" =~ ^[12]$ ]]; do
        read -rp "  Выбор [1]: " port_mode < /dev/tty
        port_mode="${port_mode:-1}"
    done

    local port port_hop_start port_hop_end listen_addr
    if [ "$port_mode" = "2" ]; then
        echo ""
        echo -e "  ${WHITE}Диапазон портов для Port Hopping:${NC}"
        read -rp "  Начало диапазона [20000]: " port_hop_start < /dev/tty
        port_hop_start="${port_hop_start:-20000}"
        read -rp "  Конец диапазона [29999]: "  port_hop_end < /dev/tty
        port_hop_end="${port_hop_end:-29999}"
        # Основной порт — первый в диапазоне
        port="$port_hop_start"
        listen_addr="0.0.0.0:${port_hop_start}-${port_hop_end}"
        ok "Port Hopping: UDP ${port_hop_start}-${port_hop_end}"
    else
        echo ""
        echo -e "  ${WHITE}Выберите UDP порт:${NC}"
        echo "  ⚠️  Порт 443 занят Xray/Reality если установлен Remnawave"
        info "Проверка портов..."
        local l8443 l2053 l2083 l2087
        l8443=$(hy_port_label 8443); l2053=$(hy_port_label 2053)
        l2083=$(hy_port_label 2083); l2087=$(hy_port_label 2087)
        echo "  ┌──────────────────────────────────────────────────────────┐"
        printf "  │  1) 8443  — рекомендуется  [%-26s]  │\n" "$l8443"
        printf "  │  2) 2053  — альтернатива   [%-26s]  │\n" "$l2053"
        printf "  │  3) 2083  — альтернатива   [%-26s]  │\n" "$l2083"
        printf "  │  4) 2087  — альтернатива   [%-26s]  │\n" "$l2087"
        echo "  │  5) Ввести свой порт                                     │"
        echo "  └──────────────────────────────────────────────────────────┘"
        local port_choice=""
        while [[ ! "$port_choice" =~ ^[12345]$ ]]; do
            read -rp "  Выбор [1]: " port_choice < /dev/tty
            port_choice="${port_choice:-1}"
        done
        case "$port_choice" in
            1) port=8443 ;; 2) port=2053 ;; 3) port=2083 ;; 4) port=2087 ;;
            5) while true; do
                   read -rp "  Порт (1-65535): " port < /dev/tty
                   [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) && break
                   warn "Некорректный порт"
               done ;;
        esac
        listen_addr="0.0.0.0:${port}"
        if ! hy_port_is_free "$port"; then
            warn "Порт $port занят!"
            local fp; read -rp "  Продолжить? (y/N): " fp < /dev/tty
            [[ "${fp:-N}" =~ ^[yY]$ ]] || { warn "Отмена"; return 1; }
        fi
        ok "Порт: $port"
    fi

    # ── IPv6 ───────────────────────────────────────────────────────
    echo ""
    local use_ipv6=false
    if ip -6 addr show 2>/dev/null | grep -q "inet6.*global"; then
        read -rp "  Включить IPv6 поддержку? (y/N): " ipv6_ch < /dev/tty
        [[ "${ipv6_ch:-N}" =~ ^[yY]$ ]] && {
            use_ipv6=true
            if [ "$port_mode" = "2" ]; then
                listen_addr="[::]:${port_hop_start}-${port_hop_end}"
            else
                listen_addr="[::]:${port}"
            fi
            ok "IPv6 включён"
        }
    fi

    # ── Пользователь ───────────────────────────────────────────────
    local username pass
    read -rp "  Логин [admin]: " username < /dev/tty
    username="${username:-admin}"
    read -rp "  Пароль (пусто = авто): " pass < /dev/tty
    if [ -z "$pass" ]; then
        pass=$(openssl rand -base64 24 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $pass"
    fi

    # ── Название подключения ───────────────────────────────────────
    local conn_name
    read -rp "  Название подключения [Hysteria2]: " conn_name < /dev/tty
    conn_name="${conn_name:-Hysteria2}"

    # ── Masquerade ─────────────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Режим маскировки:${NC}"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  1) bing.com          — рекомендуется, поддерживает HTTP/3  │"
    echo "  │  2) yahoo.com         — стабильный, поддерживает HTTP/3     │"
    echo "  │  3) cdn.apple.com     — нейтральный, поддерживает HTTP/3    │"
    echo "  │  4) speed.hetzner.de  — нейтральный, поддерживает HTTP/3    │"
    echo "  │  5) /var/www/html     — локальная заглушка (Remnawave)      │"
    echo "  │  6) Ввести свой URL                                          │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    local masq_choice="" masq_type masq_url
    masq_type="proxy"; masq_url=""
    while [[ ! "$masq_choice" =~ ^[123456]$ ]]; do
        read -rp "  Выбор [1]: " masq_choice < /dev/tty
        masq_choice="${masq_choice:-1}"
    done
    case "$masq_choice" in
        1) masq_url="https://www.bing.com" ;;
        2) masq_url="https://www.yahoo.com" ;;
        3) masq_url="https://cdn.apple.com" ;;
        4) masq_url="https://speed.hetzner.de" ;;
        5) masq_type="file"
           if [ ! -d /var/www/html ]; then
               mkdir -p /var/www/html
               cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Please wait</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.dots{display:flex;gap:15px;margin-bottom:30px}.d{width:20px;height:20px;background:#fff;border-radius:50%;animation:b 1.4s infinite ease-in-out both}.d:nth-child(1){animation-delay:-0.32s}.d:nth-child(2){animation-delay:-0.16s}@keyframes b{0%,80%,100%{transform:scale(0);opacity:0.2}40%{transform:scale(1);opacity:1}}.t{color:#555;font-size:14px;letter-spacing:2px;font-weight:600}</style></head><body><div class="dots"><div class="d"></div><div class="d"></div><div class="d"></div></div><div class="t">RETRYING CONNECTION</div></body></html>
HTML
               ok "Заглушка создана: /var/www/html"
           else
               ok "Используется существующая /var/www/html"
           fi ;;
        6) while true; do
               read -rp "  URL (https://...): " masq_url < /dev/tty
               [[ "$masq_url" =~ ^https?:// ]] && break
               warn "URL должен начинаться с https://"
           done ;;
    esac
    [ "$masq_type" = "proxy" ] && ok "Маскировка: proxy → $masq_url" \
                                || ok "Маскировка: file → /var/www/html"

    # ── Алгоритм скорости ──────────────────────────────────────────
    echo ""
    echo -e "  ${WHITE}Алгоритм контроля скорости:${NC}"
    echo "  [1] BBR    — стандартный, рекомендуется для стабильных каналов"
    echo "  [2] Brutal — агрессивный, для нестабильных каналов / мобильного"
    local speed_mode use_brutal=false bw_up bw_down
    read -rp "  Выбор [1]: " speed_mode < /dev/tty
    speed_mode="${speed_mode:-1}"
    if [ "$speed_mode" = "2" ]; then
        use_brutal=true
        warn "Указывайте реальную скорость — Brutal создаёт до 1.4× нагрузки"
        read -rp "  Download (Mbps) [100]: " bw_down < /dev/tty; bw_down="${bw_down:-100}"
        read -rp "  Upload (Mbps) [50]: "   bw_up   < /dev/tty; bw_up="${bw_up:-50}"
        ok "Brutal: ↓${bw_down} / ↑${bw_up} Mbps"
    else
        ok "BBR (по умолчанию)"
    fi

    # ── Зависимости ────────────────────────────────────────────────
    step "Установка зависимостей"
    apt-get update -y -q && apt-get install -y -q curl ca-certificates openssl qrencode dnsutils

    # ── Проверка DNS ───────────────────────────────────────────────
    step "Проверка DNS"
    local server_ip domain_ips
    server_ip=$(hy_get_public_ip || true)
    [ -z "$server_ip" ] && { err "Не удалось определить IP сервера"; return 1; }
    ok "IP сервера: $server_ip"
    domain_ips=$(hy_resolve_a "$domain" || true)
    [ -z "$domain_ips" ] && { err "Домен $domain не резолвится. Создайте A-запись → $server_ip"; return 1; }
    echo "  A-записи: $(echo "$domain_ips" | tr '\n' ' ')"
    if ! echo "$domain_ips" | grep -qx "$server_ip"; then
        warn "Домен не указывает на этот сервер ($server_ip)!"
        local fc; read -rp "  Продолжить принудительно? (y/N): " fc < /dev/tty
        [[ "${fc:-N}" =~ ^[yY]$ ]] || { warn "Исправьте DNS и запустите снова"; return 1; }
    else
        ok "DNS корректен: $domain → $server_ip"
    fi

    # ── Установка бинарника ────────────────────────────────────────
    step "Установка Hysteria2"
    bash <(curl -fsSL https://get.hy2.sh/) || { err "Ошибка установки"; return 1; }
    command -v hysteria &>/dev/null || { err "Бинарник hysteria не найден"; return 1; }
    ok "Hysteria2 установлен: $(hysteria version 2>/dev/null | grep Version | awk '{print $2}')"

    # ── Конфиг ────────────────────────────────────────────────────
    step "Запись конфигурации"
    install -d -m 0755 "$HYSTERIA_DIR"
    local acme_email_line=""
    [ -n "$email" ] && acme_email_line="  email: ${email}"

    local bw_block=""
    $use_brutal && bw_block="
bandwidth:
  up: ${bw_up} mbps
  down: ${bw_down} mbps"

    local masq_block
    if [ "$masq_type" = "file" ]; then
        masq_block="masquerade:
  type: file
  file:
    dir: /var/www/html"
    else
        masq_block="masquerade:
  type: proxy
  proxy:
    url: ${masq_url}
    rewriteHost: true"
    fi

    cat > "$HYSTERIA_CONFIG" << EOF
listen: ${listen_addr}

acme:
  type: http
  domains:
    - ${domain}
  ca: ${ca_name}
${acme_email_line}

auth:
  type: userpass
  userpass:
    ${username}: "${pass}"
${bw_block}
${masq_block}

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
    ok "Конфигурация записана: $HYSTERIA_CONFIG"

    # ── Сервис ─────────────────────────────────────────────────────
    systemctl daemon-reload
    command -v ufw &>/dev/null && ufw allow 80/tcp >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1
    ok "UFW: временно открыт порт 80 для ACME"
    systemctl enable --now "$HYSTERIA_SVC"

    # Ждём сертификат
    info "Ждём получения сертификата..."
    local i=0
    while [ $i -lt 30 ]; do
        journalctl -u "$HYSTERIA_SVC" -n 20 --no-pager 2>/dev/null | grep -q "server up and running" && break
        sleep 1; i=$((i+1))
    done
    command -v ufw &>/dev/null && ufw delete allow 80/tcp >/dev/null 2>&1
    ok "UFW: порт 80 закрыт"
    ok "Сервис $HYSTERIA_SVC запущен"

    # ── UFW ────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow 22/tcp >/dev/null 2>&1
        if [ "$port_mode" = "2" ]; then
            ufw allow "${port_hop_start}:${port_hop_end}/udp" >/dev/null 2>&1
            ok "UFW: открыт диапазон ${port_hop_start}-${port_hop_end}/udp"
        else
            ufw allow "${port}/udp" >/dev/null 2>&1
            ufw allow "${port}/tcp" >/dev/null 2>&1
            ok "UFW: открыт ${port}/udp и ${port}/tcp"
        fi
        ufw --force enable >/dev/null 2>&1
    fi

    # ── Проверка сертификата ───────────────────────────────────────
    sleep 3
    local cert_expiry=""
    local cert_path="/var/lib/hysteria/acme/certificates/acme-v02.api.letsencrypt.org-directory/${domain}/${domain}.crt"
    if [ -f "$cert_path" ]; then
        cert_expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || true)
        [ -n "$cert_expiry" ] && ok "Сертификат действует до: $cert_expiry"
    fi

    # ── URI и файлы ────────────────────────────────────────────────
    local uri txt_file yaml_file qr_file
    local uri_port="$port"
    [ "$port_mode" = "2" ] && uri_port="${port_hop_start}-${port_hop_end}"
    uri="hy2://${username}:${pass}@${domain}:${uri_port}?sni=${domain}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"
    txt_file="/root/hysteria-${domain}.txt"
    yaml_file="/root/hysteria-${domain}.yaml"
    qr_file="/root/hysteria-${domain}.png"

    echo "$uri" > "$txt_file"

    cat > "$yaml_file" << EOF
proxies:
  - name: ${conn_name}
    type: hysteria2
    server: ${domain}
    port: ${port}
$([ "$port_mode" = "2" ] && echo "    ports: ${port_hop_start}-${port_hop_end}")
    username: ${username}
    password: "${pass}"
    sni: ${domain}
    alpn:
      - h3
    skip-cert-verify: false
$($use_brutal && echo "    up: \"${bw_up} mbps\"" && echo "    down: \"${bw_down} mbps\"")

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - ${conn_name}

rules:
  - MATCH,Proxy
EOF

    qrencode -o "$qr_file" -s 8 "$uri" 2>/dev/null && ok "QR PNG: $qr_file"

    # ── Итог ───────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}  ✓ Hysteria2 установлен${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Конфигурация${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}Сервер    ${NC}${domain}:${uri_port}"
    echo -e "  ${GRAY}Логин     ${NC}${username}"
    echo -e "  ${GRAY}Пароль    ${NC}${pass}"
    echo -e "  ${GRAY}Режим     ${NC}$( [ "$port_mode" = "2" ] && echo "Port Hopping ${port_hop_start}-${port_hop_end}" || echo "Один порт" )"
    echo -e "  ${GRAY}IPv6      ${NC}$( $use_ipv6 && echo "включён" || echo "выключен" )"
    echo -e "  ${GRAY}Алгоритм  ${NC}$( $use_brutal && echo "Brutal ↓${bw_down}/↑${bw_up} Mbps" || echo "BBR" )"
    [ -n "$cert_expiry" ] && echo -e "  ${GRAY}SSL до    ${NC}${cert_expiry}"
    echo ""
    echo -e "${BOLD}${WHITE}  URI подключения${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${CYAN}${uri}${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}  Файлы${NC}"
    echo -e "${GRAY}  ──────────────────────────────${NC}"
    echo -e "  ${GRAY}URI          ${NC}${txt_file}"
    echo -e "  ${GRAY}Clash/Mihomo ${NC}${yaml_file}"
    echo -e "  ${GRAY}QR PNG       ${NC}${qr_file}"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}${WHITE}  QR-код${NC}"
        echo -e "${GRAY}  ──────────────────────────────${NC}"
        qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
        echo ""
    fi
}

# ── Статус ────────────────────────────────────────────────────────
hysteria_status() {
    header "Hysteria2 — Статус"
    if hy_is_installed; then
        echo -e "  Версия:  $(hysteria version 2>/dev/null | head -1)"
    fi
    systemctl --no-pager status "$HYSTERIA_SVC" 2>/dev/null || warn "Сервис не найден"
    if [ -f "$HYSTERIA_CONFIG" ]; then
        echo ""
        echo -e "  ${WHITE}Конфигурация:${NC}"
        local dom port usr dp
        dp=$(hy_get_domain_port 2>/dev/null || true)
        dom="${dp%%:*}"; [ -z "$dom" ] && dom="—"
        port="${dp##*:}"; [ -z "$port" ] && port="—"
        # Первый пользователь из userpass (Python для надёжности)
        usr=$(python3 -c "
import re, sys
try:
    cfg = open('$HYSTERIA_CONFIG').read()
    m = re.search(r'userpass:
(    ([^
:]+):', cfg)
    print(m.group(2).strip() if m else '—')
except: print('—')
" 2>/dev/null || echo "—")
        echo "    Домен: $dom    Порт: $port    Пользователь: $usr"
    fi
}

# ── Логи ──────────────────────────────────────────────────────────
hysteria_logs() {
    header "Hysteria2 — Логи"
    journalctl -u "$HYSTERIA_SVC" -n 80 --no-pager 2>/dev/null || warn "Логи недоступны"
}

# ── Перезапуск ────────────────────────────────────────────────────
hysteria_restart() {
    systemctl restart "$HYSTERIA_SVC" && ok "Hysteria2 перезапущен" || warn "Ошибка перезапуска"
}

# ── Добавить пользователя ─────────────────────────────────────────
# ── Удалить пользователя Hysteria2 ───────────────────────────────
hysteria_delete_user() {
    header "Hysteria2 — Удалить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local -a users=()
    while IFS= read -r line; do
        local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
        [ -n "$u" ] && users+=("$u")
    done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены в конфиге"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя для удаления:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
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

    # Удаляем строку из userpass
    sed -i "/^    ${selected}:/d" "$HYSTERIA_CONFIG"

    ok "Пользователь '${selected}' удалён"

    # Перезапускаем сервис
    systemctl reload "$HYSTERIA_SVC" 2>/dev/null || systemctl restart "$HYSTERIA_SVC"
    sleep 1
    ok "Конфиг применён"
}

hysteria_add_user() {
    header "Hysteria2 — Добавить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден. Сначала установите Hysteria2"; return 1; }

    local new_user new_pass
    # Показываем существующих пользователей
    local existing
    existing=$(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:" | sed 's/:.*//' | tr -d ' ' | tr '\n' ' ')
    [ -n "$existing" ] && info "Существующие пользователи: ${existing}"

    # Ввод имени с проверкой на дубликат
    while true; do
        read -rp "  Имя пользователя: " new_user < /dev/tty
        [ -z "$new_user" ] && { warn "Имя не может быть пустым"; continue; }
        if grep -qE "^    ${new_user}:" "$HYSTERIA_CONFIG" 2>/dev/null; then
            warn "Пользователь '${new_user}' уже существует."
            echo ""
            echo -e "  ${BOLD}1)${RESET} Ввести другое имя"
            echo -e "  ${BOLD}2)${RESET} Заменить пароль для '${new_user}'"
            echo -e "  ${BOLD}0)${RESET} Отмена"
            local ch; read -rp "  Выбор: " ch < /dev/tty
            case "$ch" in
                1) continue ;;
                2)
                    read -rp "  Новый пароль (пусто = авто): " new_pass < /dev/tty
                    if [ -z "$new_pass" ]; then
                        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
                        info "Сгенерирован пароль: $new_pass"
                    fi
                    sed -i "s/^    ${new_user}:.*$/    ${new_user}: \"${new_pass}\"/" "$HYSTERIA_CONFIG"
                    systemctl reload "$HYSTERIA_SVC" 2>/dev/null || systemctl restart "$HYSTERIA_SVC"
                    ok "Пароль для '${new_user}' обновлён"
                    return 0 ;;
                *) return 0 ;;
            esac
        else
            break
        fi
    done

    read -rp "  Пароль (пусто = авто): " new_pass < /dev/tty
    if [ -z "$new_pass" ]; then
        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $new_pass"
    fi

    # Вставляем под userpass:
    sed -i "/^  userpass:/a\\    ${new_user}: \"${new_pass}\"" "$HYSTERIA_CONFIG"
    systemctl reload "$HYSTERIA_SVC" 2>/dev/null || systemctl restart "$HYSTERIA_SVC"
    ok "Пользователь '${new_user}' добавлен"

    # Генерируем URI для нового пользователя
    local dom port conn_name uri
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    # Собираем существующие названия из URI-файла
    local users_file="/root/hysteria-${dom}-users.txt"
    local main_file="/root/hysteria-${dom}.txt"
    local -a existing_names=()
    for f in "$users_file" "$main_file"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            local n; n=$(echo "$line" | grep -a "hy2://" | sed 's/.*#//')
            [ -n "$n" ] && existing_names+=("$n")
        done < "$f"
    done
    # Убираем дубликаты
    local -a unique_names=()
    for n in "${existing_names[@]}"; do
        local found=0
        for u in "${unique_names[@]}"; do [ "$u" = "$n" ] && found=1 && break; done
        [ $found -eq 0 ] && unique_names+=("$n")
    done

    echo ""
    echo -e "  ${WHITE}Название подключения:${NC}"
    local i=1
    for n in "${unique_names[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${n}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}${i})${RESET} Ввести новое название"
    echo ""
    local ch; read -rp "  Выбор [${i}]: " ch < /dev/tty
    ch="${ch:-$i}"
    if [[ "$ch" =~ ^[0-9]+$ ]] && [ "$ch" -ge 1 ] && [ "$ch" -lt "$i" ]; then
        conn_name="${unique_names[$((ch-1))]}"
    else
        read -rp "  Новое название [${new_user}]: " conn_name < /dev/tty
        conn_name="${conn_name:-$new_user}"
    fi
    uri="hy2://${new_user}:${new_pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    echo ""
    echo "  QR-код:"
    qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    echo "$uri" >> "/root/hysteria-${dom}-users.txt"
    ok "URI сохранён: /root/hysteria-${dom}-users.txt"
}

# ── Миграция ──────────────────────────────────────────────────────
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
    RUN "bash <(curl -fsSL https://get.hy2.sh/)" || { err "Ошибка установки"; return 1; }
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
    local script_path; script_path=$(realpath "$0" 2>/dev/null || echo "/root/setup.sh")
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

# ── Показать ссылки пользователей ────────────────────────────────
hysteria_show_links() {
    header "Hysteria2 — Пользователи и ссылки"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local dom port
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    local -a users=()
    while IFS= read -r line; do
        local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
        [ -n "$u" ] && users+=("$u")
    done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены в конфиге"; return 1
    fi

    echo -e "  ${WHITE}Выберите пользователя:${NC}"
    echo ""
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${u}"
        i=$((i+1))
    done
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""

    local ch; read -rp "  Выбор: " ch < /dev/tty
    [[ "$ch" == "0" ]] && return
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi

    local selected="${users[$((ch-1))]}"
    local pass
    # Python-парсинг надёжнее sed — не ломается на спецсимволах (: # " в пароле)
    if command -v python3 &>/dev/null; then
        pass=$(python3 -c "
import sys, re
cfg = open('$HYSTERIA_CONFIG').read()
m = re.search(r'^ {4}' + re.escape('${selected}') + r':\s*[\"\x27]?([^\"\x27\n]+)[\"\x27]?', cfg, re.M)
print(m.group(1).strip() if m else '')
" 2>/dev/null)
    else
        pass=$(grep -E "^    ${selected}:" "$HYSTERIA_CONFIG" | sed 's/.*: //' | tr -d '"' | tr -d "'")
    fi

    # Ищем сохранённое название из URI-файлов
    local conn_name=""
    for f in "/root/hysteria-${dom}-users.txt" "/root/hysteria-${dom}.txt"; do
        [ -f "$f" ] || continue
        local found_name
        found_name=$(grep -a "hy2://${selected}:" "$f" 2>/dev/null | sed 's/.*#//' | tail -1 || true)
        if [ -n "$found_name" ]; then
            conn_name="$found_name"
            break
        fi
    done
    # Если не нашли — используем имя пользователя
    conn_name="${conn_name:-$selected}"

    local uri="hy2://${selected}:${pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"

    echo ""
    echo -e "  ${CYAN}Пользователь:${NC} ${selected}"
    echo -e "  ${CYAN}Сервер:${NC}       ${dom}:${port}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}${WHITE}  QR-код${NC}"
        echo -e "${GRAY}  ──────────────────────────────${NC}"
        qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    else
        echo -e "  ${GRAY}QR: установите qrencode — apt install qrencode${NC}"
    fi
    echo ""
}

# ── Подменю Hysteria2 ─────────────────────────────────────────────
# hysteria_merge_sub удалена — используется hysteria_merge_sub (http.server, без зависимостей)

# ── Merged подписка (Remnawave + Hysteria2) ──────────────────────
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
        echo -e "  ${BOLD}2)${RESET}  ⚙️   Управление"
        echo -e "  ${BOLD}3)${RESET}  👥  Пользователи"
        echo -e "  ${BOLD}4)${RESET}  🔗  Подписка"
        echo -e "  ${BOLD}5)${RESET}  📦  Миграция на другой сервер"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_install || true ;;
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
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) hysteria_status || true; read -rp "Enter..." < /dev/tty ;;
            2) hysteria_logs || true;   read -rp "Enter..." < /dev/tty ;;
            3) hysteria_restart || true; read -rp "Enter..." < /dev/tty ;;
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
            3) hysteria_show_links || true; read -rp "Enter..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}


# ── Интеграция Hysteria2 → Remnawave (webhook + subscription-page) ────────────

hysteria_remnawave_integration() {
    local script_url="https://raw.githubusercontent.com/stump3/setup_rth/main/hy-sub-install.sh"
    local tmp; tmp=$(mktemp /tmp/hy-sub-install.XXXXXX.sh)

    info "Скачиваем hy-sub-install.sh..."
    if ! curl -fsSL "$script_url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "Не удалось скачать hy-sub-install.sh с GitHub"
        return 1
    fi

    # Извлекаем данные из конфига и URI-файлов, передаём через env
    # чтобы hy-sub-install.sh не спрашивал уже известное
    local dom port conn_name uri_file
    dom=$(hy_get_domain 2>/dev/null || true)
    port=$(hy_get_port 2>/dev/null || true)
    conn_name=""
    for uri_file in "/root/hysteria-${dom}.txt" "/root/hysteria-${dom}-users.txt"; do
        [ -f "$uri_file" ] || continue
        conn_name=$(grep -m1 "^hy2://" "$uri_file" 2>/dev/null | sed "s/.*#//" | tr -d "\n" || true)
        [ -n "$conn_name" ] && break
    done

    [ -n "$dom" ]       && info "Передаём домен:    $dom"
    [ -n "$port" ]      && info "Передаём порт:     $port"
    [ -n "$conn_name" ] && info "Передаём название: $conn_name"
    echo ""

    chmod +x "$tmp"
    HY_DOMAIN="$dom" \
    HY_PORT="$port" \
    HY_CONN_NAME="$conn_name" \
    HY_CONFIG="$HYSTERIA_CONFIG" \
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
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


migrate_menu() {
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
        1) do_migrate ;;
        2) [ -z "$TELEMT_MODE" ] && {
               TELEMT_MODE="systemd"
               TELEMT_CONFIG_FILE="$TELEMT_CONFIG_SYSTEMD"
               TELEMT_WORK_DIR="$TELEMT_WORK_DIR_SYSTEMD"
           }
           telemt_menu_migrate ;;
        3) hysteria_migrate || true ;;
        4) check_root; migrate_all ;;
        5) panel_backup_restore ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
    migrate_menu
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
        err "Не удалось скачать скрипт"
        echo -e "  Установите вручную:"
        echo -e "  ${CYAN}curl -fsSL $script_url | bash${NC}"
    fi
}


