# shellcheck shell=bash
# Hysteria2: интеграция с Remnawave

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
