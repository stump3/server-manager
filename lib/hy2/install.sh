# shellcheck shell=bash
# Hysteria2: установка и переустановка

hysteria_install() {
    STEP_NUM=0; TOTAL_STEPS=5
    step "Установка / Переустановка Hysteria2"
    STEP_NUM=1

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
                local hy_script; hy_script=$(mktemp /tmp/hy2-install.XXXXXX.sh)
                if ! curl -fsSL --max-time 30 https://get.hy2.sh/ -o "$hy_script" 2>/dev/null; then
                    rm -f "$hy_script"; err "Не удалось скачать установщик Hysteria2"; return 1
                fi
                [ -s "$hy_script" ] || { rm -f "$hy_script"; err "Установщик Hysteria2 пустой"; return 1; }
                local _rc=0; bash "$hy_script" || _rc=$?; rm -f "$hy_script"
                [ $_rc -ne 0 ] && { err "Ошибка установки"; return 1; }
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
    local username new_pass
    read -rp "  Логин [admin]: " username < /dev/tty
    username="${username:-admin}"
    read -rp "  Пароль (пусто = авто): " new_pass < /dev/tty
    if [ -z "$new_pass" ]; then
        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $new_pass"
    fi

    # ── Бинарник + базовый конфиг (первичная установка) ───────────
    if ! hy_is_installed; then
        info "Установка бинарника Hysteria2..."
        local _hy_script; _hy_script=$(mktemp /tmp/hy2-install.XXXXXX.sh)
        if ! curl -fsSL --max-time 30 https://get.hy2.sh/ -o "$_hy_script" 2>/dev/null; then
            rm -f "$_hy_script"; err "Не удалось скачать установщик Hysteria2"; return 1
        fi
        [ -s "$_hy_script" ] || { rm -f "$_hy_script"; err "Установщик Hysteria2 пустой"; return 1; }
        local _rc=0; bash "$_hy_script" || _rc=$?; rm -f "$_hy_script"
        [ $_rc -ne 0 ] && { err "Ошибка установки Hysteria2"; return 1; }
        ok "Бинарник Hysteria2 установлен"
    fi

    local _config_created=false
    if [ ! -f "$HYSTERIA_CONFIG" ]; then
        info "Создание базового конфига Hysteria2..."
        local _acme_email_line=""
        [ -n "$email" ] && _acme_email_line="  email: ${email}"
        mkdir -p "$(dirname "$HYSTERIA_CONFIG")"
        cat > "$HYSTERIA_CONFIG" <<EOF
listen: ${listen_addr}

acme:
  domains:
    - ${domain}
${_acme_email_line}
  ca: ${ca_name}

auth:
  type: userpass
  userpass:
    ${username}: "${new_pass}"
EOF
        chmod 644 "$HYSTERIA_CONFIG"
        _config_created=true
    fi

    local _users_db="/var/lib/hy-webhook/users.json"
    local _is_http_auth=false
    grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && _is_http_auth=true

    if $_config_created; then
        systemctl restart "$HYSTERIA_SVC" 2>/dev/null || true
        ok "Пользователь '${username}' добавлен"
    elif $_is_http_auth; then
        # HTTP auth — пишем MD5 хеш в users.json, Hysteria не перезапускаем
        local _hash; _hash=$(echo -n "$new_pass" | md5sum | awk '{print $1}')
        mkdir -p "$(dirname "$_users_db")"
        local _tmp; _tmp=$(mktemp)
        python3 << PYEOF2
import json
db = "$_users_db"
try:
    with open(db) as f: u = json.load(f)
except Exception: u = {}
u["${username}"] = "$_hash"
with open("$_tmp", "w") as f: json.dump(u, f, indent=2)
PYEOF2
        mv "$_tmp" "$_users_db" && chmod 644 "$_users_db" || rm -f "$_tmp"
        systemctl restart hy-webhook 2>/dev/null || true
        ok "Пользователь '${username}' добавлен (HTTP auth)"
        # URI использует MD5 хеш как пароль
        new_pass="$_hash"
    else
        # userpass — пишем в config.yaml
        local _tmp; _tmp=$(mktemp)
        awk -v user="$username" -v pass="$new_pass" '
        /^  userpass:/ {
            print
            print "    " user ": \"" pass "\""
            next
        }
        1
        ' "$HYSTERIA_CONFIG" > "$_tmp" && \
        mv "$_tmp" "$HYSTERIA_CONFIG" && \
        chmod 644 "$HYSTERIA_CONFIG" || \
        rm -f "$_tmp"
        systemctl restart "$HYSTERIA_SVC"
        ok "Пользователь '${username}' добавлен"
    fi

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
        read -rp "  Новое название [${username}]: " conn_name < /dev/tty
        conn_name="${conn_name:-$username}"
    fi
    uri="hy2://${username}:${new_pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${conn_name}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    echo ""
    echo "  QR-код:"
    qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    echo "$uri" >> "/root/hysteria-${dom}-users.txt"
    ok "URI сохранён: /root/hysteria-${dom}-users.txt"
}
