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
    local _d=""
    [ -f "$HYSTERIA_CONFIG" ] && _d=$(awk '/domains:/{f=1;next} f&&/^  - /{gsub(/[[:space:]]*-[[:space:]]*/,""); print; exit}' "$HYSTERIA_CONFIG" 2>/dev/null)
    if [ -z "$_d" ]; then
        _d=$(grep "^HY_DOMAIN=" /etc/hy-webhook.env 2>/dev/null | cut -d= -f2 | tr -d '"')
    fi
    echo "$_d"
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
    local username pass
    read -rp "  Логин [admin]: " username < /dev/tty
    username="${username:-admin}"
    read -rp "  Пароль (пусто = авто): " new_pass < /dev/tty
    if [ -z "$new_pass" ]; then
        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $new_pass"
    fi

    local _users_db="/var/lib/hy-webhook/users.json"
    local _is_http_auth=false
    grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && _is_http_auth=true

    if $_is_http_auth; then
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
u["${new_user}"] = "$_hash"
with open("$_tmp", "w") as f: json.dump(u, f, indent=2)
PYEOF2
        mv "$_tmp" "$_users_db" && chmod 644 "$_users_db" || rm -f "$_tmp"
        systemctl restart hy-webhook 2>/dev/null || true
        ok "Пользователь '${new_user}' добавлен (HTTP auth)"
        # URI использует MD5 хеш как пароль
        new_pass="$_hash"
    else
        # userpass — пишем в config.yaml
        local _tmp; _tmp=$(mktemp)
        awk "/^  userpass:/{print; print \"    ${new_user}: \\"${new_pass}\\"\" ; next}1" \
            "$HYSTERIA_CONFIG" > "$_tmp" \
            && mv "$_tmp" "$HYSTERIA_CONFIG" && chmod 644 "$HYSTERIA_CONFIG" \
            || rm -f "$_tmp"
        systemctl restart "$HYSTERIA_SVC"
        ok "Пользователь '${new_user}' добавлен"
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

hysteria_add_user() {
    header "Hysteria2 — Добавить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local new_user=""
    while [ -z "$new_user" ]; do
        read -rp "  Логин: " new_user < /dev/tty
        new_user="${new_user// /}"
        [ -z "$new_user" ] && warn "Логин не может быть пустым"
    done

    local new_pass=""
    read -rp "  Пароль (пусто = авто): " new_pass < /dev/tty
    if [ -z "$new_pass" ]; then
        new_pass=$(openssl rand -base64 18 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        info "Сгенерирован пароль: $new_pass"
    fi

    local _users_db="/var/lib/hy-webhook/users.json"
    local _is_http_auth=false
    grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && _is_http_auth=true

    if $_is_http_auth; then
        local _hash; _hash=$(echo -n "$new_pass" | md5sum | awk '{print $1}')
        mkdir -p "$(dirname "$_users_db")"
        local _tmp; _tmp=$(mktemp)
        python3 << PYEOF
import json
db = "$_users_db"
try:
    with open(db) as f: u = json.load(f)
except Exception: u = {}
u["${new_user}"] = "$_hash"
with open("$_tmp", "w") as f: json.dump(u, f, indent=2)
PYEOF
        mv "$_tmp" "$_users_db" && chmod 644 "$_users_db" || rm -f "$_tmp"
        systemctl restart hy-webhook 2>/dev/null || true
        ok "Пользователь '${new_user}' добавлен (HTTP auth)"
        new_pass="$_hash"
    else
        if awk '/^  userpass:/,/^[^ ]/{print}' "$HYSTERIA_CONFIG" | grep -qE "^[[:space:]]{4}${new_user}:"; then
            warn "Пользователь '${new_user}' уже существует"; return 1
        fi
        local _tmp; _tmp=$(mktemp)
        awk "/^  userpass:/{print; print \"    ${new_user}: \\\"${new_pass}\\\"\" ; next}1" \
            "$HYSTERIA_CONFIG" > "$_tmp" \
            && mv "$_tmp" "$HYSTERIA_CONFIG" && chmod 644 "$HYSTERIA_CONFIG" \
            || rm -f "$_tmp"
        systemctl restart "$HYSTERIA_SVC"
        ok "Пользователь '${new_user}' добавлен"
    fi

    local dom port
    dom=$(hy_get_domain)
    port=$(hy_get_port)
    local uri="hy2://${new_user}:${new_pass}@${dom}:${port}?sni=${dom}&alpn=h3&insecure=0&allowInsecure=0#${new_user}"
    echo ""
    echo -e "  ${CYAN}URI:${NC}"
    echo "  $uri"
    qrencode -t ANSIUTF8 "$uri" 2>/dev/null || true
    echo "$uri" >> "/root/hysteria-${dom}-users.txt"
    ok "URI сохранён: /root/hysteria-${dom}-users.txt"
}

hysteria_delete_user() {
    header "Hysteria2 — Удалить пользователя"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local -a users=()
    local _users_db="/var/lib/hy-webhook/users.json"
    if [ -f "$_users_db" ] && python3 -c "import json; json.load(open('$_users_db'))" 2>/dev/null; then
        while IFS= read -r u; do
            [ -n "$u" ] && users+=("$u")
        done < <(python3 -c "import json; [print(u) for u in json.load(open('$_users_db'))]" 2>/dev/null)
    fi
    if [ ${#users[@]} -eq 0 ]; then
        while IFS= read -r line; do
            local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
            [ -n "$u" ] && users+=("$u")
        done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")
    fi
    [ ${#users[@]} -eq 0 ] && { warn "Пользователи не найдены"; return 1; }

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
    [[ "$ch" == "0" ]] && return 0
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || [ "$ch" -lt 1 ] || [ "$ch" -gt ${#users[@]} ]; then
        warn "Неверный выбор"; return 1
    fi
    local victim="${users[$((ch-1))]}"

    read -rp "  Удалить '${victim}'? (y/N): " _yn < /dev/tty
    [[ "${_yn:-N}" =~ ^[yY]$ ]] || { warn "Отмена"; return 1; }

    local _is_http_auth=false
    grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && _is_http_auth=true
    if $_is_http_auth && [ -f "$_users_db" ]; then
        local _tmp; _tmp=$(mktemp)
        python3 << PYEOF
import json
db = "$_users_db"
with open(db) as f: u = json.load(f)
u.pop("${victim}", None)
with open("$_tmp", "w") as f: json.dump(u, f, indent=2)
PYEOF
        mv "$_tmp" "$_users_db" && chmod 644 "$_users_db" || rm -f "$_tmp"
        systemctl restart hy-webhook 2>/dev/null || true
    else
        local _tmp; _tmp=$(mktemp)
        awk -v user="$victim" '
            $0 ~ "^    "user":" {next}
            {print}
        ' "$HYSTERIA_CONFIG" > "$_tmp" \
            && mv "$_tmp" "$HYSTERIA_CONFIG" && chmod 644 "$HYSTERIA_CONFIG" \
            || rm -f "$_tmp"
        systemctl restart "$HYSTERIA_SVC" 2>/dev/null || true
    fi

    local dom; dom=$(hy_get_domain)
    for f in "/root/hysteria-${dom}-users.txt" "/root/hysteria-${dom}.txt"; do
        [ -f "$f" ] || continue
        local _tmp; _tmp=$(mktemp)
        grep -av "hy2://${victim}:" "$f" > "$_tmp" && mv "$_tmp" "$f" || rm -f "$_tmp"
    done
    ok "Пользователь '${victim}' удалён"
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

# ── Показать ссылки пользователей ────────────────────────────────
hysteria_show_links() {
    header "Hysteria2 — Пользователи и ссылки"
    [ -f "$HYSTERIA_CONFIG" ] || { warn "Конфиг не найден"; return 1; }

    local dom port
    dom=$(hy_get_domain)
    port=$(hy_get_port)

    # Читаем пользователей из users.json (HTTP auth) или из config.yaml (userpass)
    local -a users=()
    local _users_db="/var/lib/hy-webhook/users.json"
    if [ -f "$_users_db" ] && python3 -c "import json; json.load(open('$_users_db'))" 2>/dev/null; then
        while IFS= read -r u; do
            [ -n "$u" ] && users+=("$u")
        done < <(python3 -c "import json; [print(u) for u in json.load(open('$_users_db'))]" 2>/dev/null)
    fi
    # Fallback: читаем из userpass блока в конфиге
    if [ ${#users[@]} -eq 0 ]; then
        while IFS= read -r line; do
            local u; u=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
            [ -n "$u" ] && users+=("$u")
        done < <(awk '/^  userpass:/,/^[^ ]/' "$HYSTERIA_CONFIG" | grep -E "^    [^:]+:")
    fi

    if [ ${#users[@]} -eq 0 ]; then
        warn "Пользователи не найдены"; return 1
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
    local pass=""
    # Сначала пробуем users.json (HTTP auth режим)
    local _users_db="/var/lib/hy-webhook/users.json"
    if [ -f "$_users_db" ]; then
        pass=$(python3 -c "
import json, sys
d = json.load(open('$_users_db'))
safe = '${selected}'.replace(' ', '_')
print(d.get('${selected}') or d.get(safe) or '')
" 2>/dev/null)
    fi
    # Fallback: парсим userpass блок в config.yaml
    if [ -z "$pass" ] && command -v python3 &>/dev/null; then
        pass=$(python3 -c "
import sys, re
cfg = open('$HYSTERIA_CONFIG').read()
m = re.search(r'^ {4}' + re.escape('${selected}') + r':\s*[\"\x27]?([^\"\x27\n]+)[\"\x27]?', cfg, re.M)
print(m.group(1).strip() if m else '')
" 2>/dev/null)
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
    read -rp "  Enter для возврата..." < /dev/tty
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


# ── Интеграция Hysteria2 → Remnawave (webhook + subscription-page) ────────────

hysteria_remnawave_integration() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${WHITE}  🪝  Интеграция Hysteria2 → Remnawave${NC}"
        echo -e "${GRAY}  ────────────────────────────────────────${NC}"
        echo ""

        # Режим auth hysteria
        local auth_mode="userpass"
        [ -f "$HYSTERIA_CONFIG" ] && grep -q "type: http" "$HYSTERIA_CONFIG" 2>/dev/null && auth_mode="http"

        # hy-webhook статус с деталями
        local hw_status hw_detail=""
        if systemctl is-active --quiet hy-webhook 2>/dev/null; then
            local hw_port; hw_port=$(grep "^LISTEN_PORT=" /etc/hy-webhook.env 2>/dev/null | cut -d= -f2)
            local hw_users; hw_users=$(python3 - << 'PYEOF' 2>/dev/null
import json
try:
    with open('/var/lib/hy-webhook/users.json') as f:
        data = json.load(f)
except Exception:
    print(0)
    raise SystemExit
if isinstance(data, dict):
    print(len(data))
elif isinstance(data, list):
    print(len(data))
else:
    print(0)
PYEOF
)
            hw_detail="${GRAY}  :${hw_port:-8766}  ${hw_users} users${NC}"
            hw_status="${GREEN}●${NC}"
        else
            hw_status="${GRAY}○${NC}"
        fi

        # sub-injector статус с деталями
        local inj_status inj_detail=""
        if systemctl is-active --quiet remna-sub-injector 2>/dev/null; then
            local inj_cfg="/opt/remna-sub-injector/config.toml"
            local inj_port; inj_port=$(grep "^bind_addr" "$inj_cfg" 2>/dev/null | grep -oE '[0-9]+$')
            inj_detail="${GRAY}  :${inj_port:-3020}${NC}"
            [ "$auth_mode" = "http" ] && inj_detail+="${GRAY}  no-restart${NC}"
            inj_status="${GREEN}●${NC}"
        else
            inj_status="${GRAY}○${NC}"
        fi

        printf "  %-12s %b%b\n" "hy-webhook"   "$(echo -e "$hw_status")"  "$(echo -e "$hw_detail")"
        printf "  %-12s %b%b\n" "sub-injector" "$(echo -e "$inj_status")" "$(echo -e "$inj_detail")"
        echo ""
        local auth_badge
        [ "$auth_mode" = "http" ] \
            && auth_badge="${GREEN}HTTP auth${NC} ${GRAY}— без перезапуска${NC}" \
            || auth_badge="${YELLOW}userpass${NC} ${GRAY}— перезапуск при изменениях${NC}"
        echo -e "  ${GRAY}Режим auth: ${NC}$(echo -e "$auth_badge")"
        echo ""
        echo -e "  ${BOLD}1)${RESET} 🔧  Установить / переустановить"
        echo -e "  ${BOLD}2)${RESET} 🔐  Режим аутентификации Hysteria2"
        echo -e "  ${BOLD}3)${RESET} 📋  Добавить UA-паттерн клиента"
        echo -e "  ${BOLD}4)${RESET} 🧵  Многопоточность hy-webhook"
        echo -e "  ${BOLD}5)${RESET} 🔍  Расширенное логирование"
        echo -e "  ${BOLD}6)${RESET} 📜  Логи hy-webhook"
        echo -e "  ${BOLD}7)${RESET} 📜  Логи sub-injector"
        echo ""
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        read -t 0.1 -n 1000 _hy_integration_menu_flush < /dev/tty 2>/dev/null || true
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) _hy_integration_install ;;
            2) _hy_integration_auth_mode ;;
            3) _hy_integration_add_ua ;;
            4) _hy_integration_threading ;;
            5) _hy_integration_debug_log ;;
            6) journalctl -u hy-webhook -n 50 --no-pager; read -rp "  Enter..." < /dev/tty ;;
            7) journalctl -u remna-sub-injector -n 50 --no-pager; read -rp "  Enter..." < /dev/tty ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

_hy_integration_install() {
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local install_script="${script_dir}/../integrations/hy-sub-install.sh"
    local cleanup_tmp=false

    if [ ! -f "$install_script" ]; then
        info "Скачиваем hy-sub-install.sh..."
        install_script=$(mktemp /tmp/hy-sub-install.XXXXXX.sh)
        if ! curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/integrations/hy-sub-install.sh" \
                -o "$install_script" 2>/dev/null; then
            err "Не удалось скачать hy-sub-install.sh"
            return 1
        fi
        chmod +x "$install_script"
        cleanup_tmp=true
    fi

    local dom port conn_name uri_file
    dom=$(hy_get_domain 2>/dev/null || true)
    port=$(hy_get_port 2>/dev/null || true)
    conn_name=""
    for uri_file in "/root/hysteria-${dom}.txt" "/root/hysteria-${dom}-users.txt"; do
        [ -f "$uri_file" ] || continue
        conn_name=$(grep -m1 "^hy2://" "$uri_file" 2>/dev/null | sed "s/.*#//" | tr -d "\n" || true)
        [ -n "$conn_name" ] && break
    done

    info "Запускаем установку интеграции (hy-webhook + subscription)..."
    if ! HY_DOMAIN="$dom" HY_PORT="$port" HY_CONN_NAME="$conn_name" HY_CONFIG="$HYSTERIA_CONFIG" \
            bash "$install_script"; then
        warn "hy-sub-install.sh завершился с ошибкой"
        echo ""
        echo -e "  ${GRAY}Последние логи hy-webhook:${NC}"
        journalctl -u hy-webhook -n 20 --no-pager 2>/dev/null || true
        echo ""
        read -rp "  Нажмите Enter для продолжения..." < /dev/tty
    fi
    # Сбрасываем накопленный ввод (например, зажатый Enter), чтобы он не
    # "нажимал" следующий пункт меню сразу после возврата из установщика.
    read -t 0.1 -n 1000 _hy_integration_flush < /dev/tty 2>/dev/null || true
    [ "$cleanup_tmp" = true ] && rm -f "$install_script"
}

# ── Установка sub-injector ─────────────────────────────────────────
_hy_sub_injector_install() {
    local domain="${1:-}" port="${2:-}"
    local install_dir="/opt/remna-sub-injector"
    local bin_path="${install_dir}/sub-injector"
    local cfg_path="${install_dir}/config.toml"
    local svc_path="/etc/systemd/system/remna-sub-injector.service"

    header "Установка sub-injector"
    mkdir -p "$install_dir"

    # ── Скачиваем бинарь ──────────────────────────────────────────
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) warn "Архитектура $arch не поддерживается sub-injector"; return 1 ;;
    esac

    local bin_url="https://github.com/stump3/server-manager/releases/latest/download/sub-injector-${arch}-linux"
    info "Скачиваю sub-injector (${arch})..."

    if curl -fsSL --max-time 30 "$bin_url" -o "$bin_path" 2>/dev/null && [ -s "$bin_path" ]; then
        chmod +x "$bin_path"
        ok "Бинарь скачан: $bin_path"
    else
        warn "Не удалось скачать бинарь — пробуем собрать из исходников..."
        _hy_sub_injector_build "$bin_path" || return 1
    fi

    # ── Создаём config.toml если не существует ───────────────────
    if [ ! -f "$cfg_path" ]; then
        info "Создаю config.toml..."
        local webhook_url="http://127.0.0.1:8766/uri"
        cat > "$cfg_path" << TOMLEOF
upstream_url = "http://127.0.0.1:3010"
bind_addr = "0.0.0.0:3020"

[[injections]]
header = "User-Agent"
contains = ["hiddify", "happ", "nekobox", "nekoray", "v2rayng"]
per_user_url = "${webhook_url}"
TOMLEOF
        ok "config.toml создан: $cfg_path"
    else
        info "config.toml уже существует, пропускаю"
    fi

    # ── Создаём systemd unit ──────────────────────────────────────
    info "Создаю systemd unit..."
    cat > "$svc_path" << SVCEOF
[Unit]
Description=Remnawave Sub Injector
Documentation=https://github.com/stump3/server-manager
After=network.target hy-webhook.service

[Service]
Type=simple
ExecStart=${bin_path} ${cfg_path}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable remna-sub-injector 2>/dev/null || true

    # Останавливаем старый экземпляр если был
    systemctl stop remna-sub-injector 2>/dev/null || true
    systemctl start remna-sub-injector 2>/dev/null

    sleep 1
    if systemctl is-active --quiet remna-sub-injector 2>/dev/null; then
        ok "sub-injector запущен на :3020"
    else
        warn "sub-injector не запустился — проверьте конфиг:"
        journalctl -u remna-sub-injector -n 20 --no-pager 2>/dev/null || true
    fi
}

# ── Сборка sub-injector из исходников (fallback) ───────────────────
_hy_sub_injector_build() {
    local bin_path="$1"
    info "Устанавливаю зависимости сборки..."
    apt-get install -y -q build-essential pkg-config libssl-dev 2>/dev/null || true

    # Устанавливаем Rust если нет
    if ! command -v cargo &>/dev/null; then
        [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env" 2>/dev/null || true
    fi
    if ! command -v cargo &>/dev/null; then
        info "Устанавливаю Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path 2>/dev/null
        source "$HOME/.cargo/env" 2>/dev/null || true
    fi
    command -v cargo &>/dev/null || { err "Не удалось установить Rust/cargo"; return 1; }

    # Скачиваем исходники
    local src_dir; src_dir=$(mktemp -d /tmp/sub-injector-src.XXXXXX)
    info "Скачиваю исходники sub-injector..."
    local raw="https://raw.githubusercontent.com/stump3/server-manager/main/sub-injector"
    mkdir -p "${src_dir}/src"
    curl -fsSL --max-time 30 "${raw}/Cargo.toml" -o "${src_dir}/Cargo.toml" 2>/dev/null ||         { err "Не удалось скачать Cargo.toml"; rm -rf "$src_dir"; return 1; }
    curl -fsSL --max-time 30 "${raw}/src/main.rs" -o "${src_dir}/src/main.rs" 2>/dev/null ||         { err "Не удалось скачать main.rs"; rm -rf "$src_dir"; return 1; }

    info "Сборка (может занять 2-5 минут)..."
    local old_pwd; old_pwd="$(pwd)"
    cd "$src_dir" && cargo build --release 2>/dev/null
    cd "$old_pwd" 2>/dev/null || cd /
    if [ -f "${src_dir}/target/release/sub-injector" ]; then
        install -m 0755 "${src_dir}/target/release/sub-injector" "$bin_path"
        rm -rf "$src_dir"
        ok "sub-injector собран и установлен"
    else
        rm -rf "$src_dir"
        err "Сборка sub-injector завершилась с ошибкой"
        return 1
    fi
}

_hy_integration_add_ua() {
    local cfg="/opt/remna-sub-injector/config.toml"
    [ -f "$cfg" ] || { warn "Конфиг sub-injector не найден: $cfg"; return 1; }

    header "Добавить UA-паттерн клиента"
    echo ""
    echo -e "  ${GRAY}Текущие паттерны:${NC}"
    grep "contains" "$cfg" | sed 's/contains = /  /' || true
    echo ""
    echo -e "  ${GRAY}Примеры: clash.meta, mihomo, hiddify, v2rayn, singbox${NC}"
    echo ""
    read -rp "  Новый паттерн (Enter — отмена): " new_ua < /dev/tty
    [ -z "$new_ua" ] && return

    if grep -q "\"${new_ua}\"" "$cfg"; then
        warn "Паттерн '$new_ua' уже есть"
        read -rp "  Enter..." < /dev/tty
        return
    fi

    sed -i "s/contains = \[/contains = [\"${new_ua}\", /" "$cfg"
    ok "Добавлен паттерн: $new_ua"
    systemctl restart remna-sub-injector 2>/dev/null && ok "sub-injector перезапущен" || true
    read -rp "  Enter..." < /dev/tty
}

_hy_integration_threading() {
    local py="/opt/hy-webhook/hy-webhook.py"
    [ -f "$py" ] || { warn "hy-webhook.py не найден"; return 1; }

    header "Многопоточность hy-webhook"
    echo ""

    if grep -q "ThreadedHTTPServer" "$py"; then
        ok "Многопоточность уже включена"
        echo ""
        echo -e "  ${GRAY}Каждый вебхук — отдельный поток.${NC}"
        echo -e "  ${GRAY}Панель не зависает при перезапуске Hysteria2.${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Выключить (вернуть однопоточный режим)"
        echo -e "  ${BOLD}0)${RESET} Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        if [ "$ch" = "1" ]; then
            sed -i 's/ThreadedHTTPServer((LISTEN_HOST/HTTPServer((LISTEN_HOST/' "$py"
            ok "Многопоточность выключена"
            systemctl restart hy-webhook && ok "hy-webhook перезапущен"
        fi
    else
        warn "Многопоточность выключена"
        echo ""
        echo -e "  ${GRAY}При однопоточном режиме панель зависает на ~3с при создании${NC}"
        echo -e "  ${GRAY}пользователя пока Hysteria2 перезапускается.${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Включить многопоточность"
        echo -e "  ${BOLD}0)${RESET} Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        if [ "$ch" = "1" ]; then
            python3 - << 'PYEOF'
path = '/opt/hy-webhook/hy-webhook.py'
with open(path) as f:
    c = f.read()
if 'ThreadingMixIn' not in c:
    c = c.replace(
        'from http.server import BaseHTTPRequestHandler, HTTPServer',
        'from http.server import BaseHTTPRequestHandler, HTTPServer\nfrom socketserver import ThreadingMixIn\n\nclass ThreadedHTTPServer(ThreadingMixIn, HTTPServer):\n    daemon_threads = True'
    )
c = c.replace(
    'server = HTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)',
    'server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)'
)
with open(path, 'w') as f:
    f.write(c)
print("ok")
PYEOF
            systemctl restart hy-webhook && ok "hy-webhook перезапущен с многопоточностью"
        fi
    fi
    read -rp "  Enter..." < /dev/tty
}

_hy_integration_debug_log() {
    local env_file="/etc/hy-webhook.env"
    [ -f "$env_file" ] || { warn "Файл $env_file не найден"; return 1; }

    header "Расширенное логирование hy-webhook"
    echo ""

    local current; current=$(grep "^DEBUG_LOG=" "$env_file" 2>/dev/null | cut -d= -f2 || echo "0")
    if [ "$current" = "1" ]; then
        echo -e "  ${GREEN}● Расширенное логирование включено${NC}"
        echo -e "  ${GRAY}  journalctl -u hy-webhook -f${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Выключить"
    else
        echo -e "  ${GRAY}○ Расширенное логирование выключено${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Включить"
        echo -e "  ${GRAY}    Показывает: входящие запросы, URI кэш, детали верификации${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}0)${RESET} Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    [ "$ch" != "1" ] && return

    if [ "$current" = "1" ]; then
        if grep -q "^DEBUG_LOG=" "$env_file"; then
            sed -i "s/^DEBUG_LOG=.*/DEBUG_LOG=0/" "$env_file"
        else
            echo "DEBUG_LOG=0" >> "$env_file"
        fi
        ok "Расширенное логирование выключено"
    else
        if grep -q "^DEBUG_LOG=" "$env_file"; then
            sed -i "s/^DEBUG_LOG=.*/DEBUG_LOG=1/" "$env_file"
        else
            echo "DEBUG_LOG=1" >> "$env_file"
        fi
        ok "Расширенное логирование включено"
    fi
    systemctl restart hy-webhook && ok "hy-webhook перезапущен"
    echo ""
    echo -e "  ${GRAY}Смотреть логи: journalctl -u hy-webhook -f${NC}"
    read -rp "  Enter..." < /dev/tty
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



_hy_integration_auth_mode() {
    local cfg="$HYSTERIA_CONFIG"
    [ -f "$cfg" ] || { warn "Конфиг Hysteria2 не найден: $cfg"; return 1; }

    header "Режим аутентификации Hysteria2"
    echo ""

    local current_mode="userpass"
    grep -q "type: http" "$cfg" 2>/dev/null && current_mode="http"

    if [ "$current_mode" = "http" ]; then
        echo -e "  ${GREEN}● HTTP auth включён${NC}"
        echo -e "  ${GRAY}  Пользователи добавляются без перезапуска Hysteria2${NC}"
        echo -e "  ${GRAY}  При подключении клиента → запрос к hy-webhook /auth${NC}"
        echo ""
        echo -e "  ${BOLD}1)${RESET} Вернуть userpass (потребует перезапуск при изменениях)"
        echo -e "  ${BOLD}0)${RESET} Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        [ "$ch" != "1" ] && return
        # Switch back to userpass
        python3 - << 'PYEOF'
import re
path = '/etc/hysteria/config.yaml'
with open(path) as f:
    content = f.read()
users_json = '/var/lib/hy-webhook/users.json'
try:
    import json
    with open(users_json) as f:
        users = json.load(f)
except:
    users = {}
userpass_block = 'auth:\n  type: userpass\n  userpass:\n'
for u, p in users.items():
    userpass_block += f'    {u}: "{p}"\n'
content = re.sub(r'auth:.*?(?=\n\S|\Z)', userpass_block.rstrip(), content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(content)
print("ok")
PYEOF
        systemctl restart hysteria-server && ok "Hysteria2 перезапущен с userpass auth"

    else
        echo -e "  ${YELLOW}● userpass режим${NC}"
        echo -e "  ${GRAY}  При каждом изменении пользователей — перезапуск Hysteria2${NC}"
        echo -e "  ${GRAY}  Соединения клиентов разрываются на ~30с${NC}"
        echo ""
        echo -e "  ${GREEN}${BOLD}1)${RESET}${GREEN} Включить HTTP auth${NC} ${GRAY}(рекомендуется)${NC}"
        echo -e "  ${GRAY}    Пользователи добавляются без перезапуска Hysteria2${NC}"
        echo -e "  ${BOLD}0)${RESET} Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        [ "$ch" != "1" ] && return
        # Switch to HTTP auth
        python3 - << 'PYEOF'
import re
path = '/etc/hysteria/config.yaml'
with open(path) as f:
    content = f.read()
new_auth = 'auth:\n  type: http\n  http:\n    url: http://127.0.0.1:8766/auth\n    insecure: false'
content = re.sub(r'auth:.*?(?=\n\S|\Z)', new_auth, content, flags=re.DOTALL)
with open(path, 'w') as f:
    f.write(content)
print("ok")
PYEOF
        systemctl restart hysteria-server && ok "Hysteria2 перезапущен с HTTP auth"
        info "Пользователи добавляются без перезапуска сервиса"
    fi
    read -rp "  Enter..." < /dev/tty
}
