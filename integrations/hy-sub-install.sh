#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  SERVER-MANAGER — Hysteria2 ↔ Remnawave Subscription Sync       ║
# ║                                                                  ║
# ║  Устанавливает:                                                  ║
# ║  1. hy-webhook      — синхронизация + GET /uri/:shortUuid        ║
# ║  2. Встроенный proxy в hy-webhook — per-user hy2:// без зависим. ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

ok()       { echo -e "${GREEN}  ✓ $*${NC}"; }
info()     { echo -e "${DIM}    $*${NC}"; }
warn()     { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()      { echo -e "\n${RED}  ✗  $*${NC}\n"; exit 1; }
detail()   { echo -e "${DIM}    → $*${NC}"; }
cfg_auto() { echo -e "${GREEN}  ✓ ${WHITE}$1${NC}${DIM} = $2  (авто)${NC}"; }
cfg_manual(){ echo -e "${YELLOW}  ✎ ${WHITE}$1${NC}${DIM} = $2  (вручную)${NC}"; }
cfg_gen()  { echo -e "${CYAN}  ⚙ ${WHITE}$1${NC}${DIM} = $2  (сгенерировано)${NC}"; }

STEP_NUM=0
TOTAL_STEPS=6

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo ""
    echo -e "${BOLD}${CYAN}━━━ [${STEP_NUM}/${TOTAL_STEPS}] $* ━━━${NC}"
    echo ""
}

# ── Очистка при ошибке ────────────────────────────────────────────
cleanup() {
    local line="${1:-?}" cmd="${2:-?}"
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗  Ошибка — установка прервана                         ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}  Строка ${line}: ${cmd}${NC}"
    echo ""
    echo -e "${YELLOW}  Подробности: journalctl -u hy-webhook -n 20 --no-pager${NC}"
    echo ""
    rm -rf /tmp/hy_patch_*.py 2>/dev/null || true
    read -rp "  Нажмите Enter для выхода..." < /dev/tty 2>/dev/null || true
    exit 1
}
trap 'cleanup $LINENO "$BASH_COMMAND"' ERR

# ── Проверки ──────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && err "Запустите от root"
[ -d /opt/remnawave ]            || err "Remnawave не установлена"
[ -f /etc/hysteria/config.yaml ] || err "Hysteria2 не установлена"

# ── Идемпотентность ───────────────────────────────────────────────
DO_WEBHOOK=true
DO_SUBPAGE=true
TOTAL_STEPS=7

if systemctl is-active --quiet hy-webhook 2>/dev/null && \
   systemctl is-active --quiet remna-sub-injector 2>/dev/null; then
    echo ""
    echo -e "  ${YELLOW}●${NC} ${BOLD}Интеграция уже установлена${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Переустановить полностью"
    echo -e "       ${GRAY}webhook + форк subscription-page${NC}"
    echo -e "  ${BOLD}2)${NC} Обновить hy-webhook + proxy"
    echo -e "       ${GRAY}скачать новый бинарник, обновить конфиг${NC}"
    echo -e "  ${BOLD}3)${NC} Обновить hy-webhook"
    echo -e "       ${GRAY}заменить скрипт синхронизации${NC}"
    echo -e "  ${BOLD}0)${NC} ${GRAY}Отмена${NC}"
    echo ""
    read -rp "  Выбор: " reinstall_ch < /dev/tty
    case "$reinstall_ch" in
        1) info "Переустановка полностью..." ;;
        2) DO_WEBHOOK=false; TOTAL_STEPS=6 ;;
        3) DO_SUBPAGE=false; TOTAL_STEPS=5 ;;
        0) exit 0 ;;
        *) err "Неверный выбор" ;;
    esac
fi

# ── Параметры ─────────────────────────────────────────────────────
step "Конфигурация"

HY_DOMAIN=$(grep -A2 'domains:' /etc/hysteria/config.yaml | grep -- '- ' | head -1 | tr -d ' -')
LISTEN_LINE=$(grep '^listen:' /etc/hysteria/config.yaml | head -1)
SUB_DOMAIN=$(grep "^SUB_PUBLIC_DOMAIN=" /opt/remnawave/.env | cut -d= -f2 | tr -d '"' | cut -d'/' -f1)

# Парсим порт — поддерживаем форматы:
# 0.0.0.0:8443  |  0.0.0.0:8443,20000-29999  |  [::]:8443  |  [::]:8443,20000-29999
HY_PORT=$(echo "$LISTEN_LINE" | grep -oE ':[0-9]+(,[0-9]+-[0-9]+)?$' | tr -d ':')
HY_PORT="${HY_PORT:-8443}"

# Определяем Port Hopping
if echo "$HY_PORT" | grep -q ','; then
    HAS_PORT_HOPPING=true
    MAIN_PORT=$(echo "$HY_PORT" | cut -d',' -f1)
    HOP_RANGE=$(echo "$HY_PORT" | cut -d',' -f2)
    info "Port Hopping обнаружен: порт $MAIN_PORT, диапазон $HOP_RANGE"
else
    HAS_PORT_HOPPING=false
    MAIN_PORT="$HY_PORT"
    HOP_RANGE=""
    info "Порт Hysteria2: $HY_PORT"
fi

if [ -n "$HY_DOMAIN" ]; then
    cfg_auto "HY_DOMAIN" "$HY_DOMAIN:$HY_PORT"
else
    echo -e "  ${YELLOW}  ✎ HY_DOMAIN${NC}${DIM} = не определён${NC}"
    read -rp "  Домен Hysteria2: " HY_DOMAIN < /dev/tty
fi
if [ -n "$SUB_DOMAIN" ]; then
    cfg_auto "SUB_DOMAIN" "$SUB_DOMAIN"
else
    echo -e "  ${YELLOW}  ✎ SUB_DOMAIN${NC}${DIM} = не определён${NC}"
    read -rp "  Домен подписок Remnawave: " SUB_DOMAIN < /dev/tty
fi

# ── Port Hopping ──────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Port Hopping${NC} ${GRAY}— рандомизация UDP порта, усложняет блокировку${NC}"
echo -e "  ${GRAY}──────────────────────────────────────────────────${NC}"

if $HAS_PORT_HOPPING; then
    echo -e "  ${GREEN}●${NC} Сейчас включён: ${CYAN}${MAIN_PORT} + ${HOP_RANGE}${NC}"
    echo ""
    echo -e "  ${BOLD}0)${NC} ${GRAY}Пропустить — оставить как есть${NC}"
    echo -e "  ${BOLD}1)${NC} Отключить Port Hopping"
else
    echo -e "  ${GRAY}●${NC} Сейчас: один порт ${CYAN}${MAIN_PORT}${NC}"
    echo ""
    echo -e "  ${BOLD}0)${NC} ${GRAY}Пропустить — оставить как есть${NC}"
    echo -e "  ${BOLD}1)${NC} ${CYAN}${MAIN_PORT} + 20000-29999${NC}  ${YELLOW}★ рекомендуется${NC}"
    echo -e "  ${BOLD}2)${NC} ${CYAN}${MAIN_PORT} + 40000-49999${NC}"
    echo -e "  ${BOLD}3)${NC} ${CYAN}${MAIN_PORT} + 50000-59999${NC}"
    echo -e "  ${BOLD}4)${NC} ${GRAY}Свой диапазон...${NC}"
fi
echo -e "  ${GRAY}──────────────────────────────────────────────────${NC}"

read -rp "  Выбор [0 — пропустить]: " hop_ch < /dev/tty
hop_ch="${hop_ch:-0}"

if $HAS_PORT_HOPPING; then
    case "$hop_ch" in
        0) info "Port Hopping оставлен без изменений" ;;
        1)
            sed -i "s|^listen:.*|listen: 0.0.0.0:${MAIN_PORT}|" /etc/hysteria/config.yaml
            ufw delete allow "${HOP_RANGE}/udp" >/dev/null 2>&1 || true
            HY_PORT="$MAIN_PORT"
            HAS_PORT_HOPPING=false; HOP_RANGE=""
            systemctl restart hysteria-server
            ok "Port Hopping отключён — порт: $MAIN_PORT"
            ;;
        *) info "Port Hopping оставлен без изменений" ;;
    esac
else
    NEW_RANGE=""
    case "$hop_ch" in
        0) info "Порт оставлен без изменений" ;;
        1) NEW_RANGE="20000-29999" ;;
        2) NEW_RANGE="40000-49999" ;;
        3) NEW_RANGE="50000-59999" ;;
        4)
            read -rp "  Диапазон (например 30000-39999): " NEW_RANGE < /dev/tty
            [[ "$NEW_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || err "Неверный формат диапазона"
            ;;
        *) info "Порт оставлен без изменений" ;;
    esac
    if [ -n "$NEW_RANGE" ]; then
        sed -i "s|^listen:.*|listen: 0.0.0.0:${MAIN_PORT},${NEW_RANGE}|" /etc/hysteria/config.yaml
        START_PORT=$(echo "$NEW_RANGE" | cut -d'-' -f1)
        END_PORT=$(echo "$NEW_RANGE" | cut -d'-' -f2)
        ufw allow "${START_PORT}:${END_PORT}/udp" >/dev/null 2>&1 || true
        HY_PORT="${MAIN_PORT},${NEW_RANGE}"
        HAS_PORT_HOPPING=true; HOP_RANGE="$NEW_RANGE"
        systemctl restart hysteria-server
        ok "Port Hopping включён: $HY_PORT"
        info "Совместимые клиенты: Hiddify, Nekoray, v2rayN 7.x+"
        warn "Некоторые старые клиенты не поддерживают Port Hopping в URI"
    fi
fi

get_saved_hy_name() {
    local env_file="/etc/hy-webhook.env"
    local line value

    [ -f "$env_file" ] || return 0
    line=$(grep -m1 '^HY_NAME=' "$env_file" 2>/dev/null || true)
    [ -n "$line" ] || return 0

    value="${line#HY_NAME=}"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Поддерживаем оба формата:
    # HY_NAME=ger-hy2
    # HY_NAME="ger hy2"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
    fi

    printf '%s' "$value"
}

DEFAULT_HY_NAME="$(get_saved_hy_name)"
DEFAULT_HY_NAME="${DEFAULT_HY_NAME:-🇩🇪 Germany Hysteria2}"

read -rp "  Название подключения [${DEFAULT_HY_NAME}]: " HY_NAME < /dev/tty
HY_NAME="${HY_NAME:-$DEFAULT_HY_NAME}"

# API токен Remnawave для GET /uri/:shortUuid в hy-webhook
# Создайте в панели: Settings → API Tokens → Create (опционально)
if [ -z "${REMNAWAVE_API_TOKEN:-}" ]; then
    echo ""
    info "API токен Remnawave — опционально, для /uri/:shortUuid endpoint"
    info "Создайте в панели: Settings → API Tokens → Create"
    read -rp "  API токен (Enter — пропустить): " REMNAWAVE_API_TOKEN < /dev/tty
    REMNAWAVE_API_TOKEN="${REMNAWAVE_API_TOKEN:-}"
fi

# ── Шаг 1: hy-webhook ────────────────────────────────────────────
if $DO_WEBHOOK; then

step "Установка hy-webhook"

mkdir -p /opt/hy-webhook /var/lib/hy-webhook

# Копируем hy-webhook.py ПЕРВЫМ — до записи env и перезапуска сервиса
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/hy-webhook.py" ]; then
    cp "${SCRIPT_DIR}/hy-webhook.py" /opt/hy-webhook/hy-webhook.py
    info "Используется локальный hy-webhook.py"
elif [ -f /root/hy-webhook.py ]; then
    cp /root/hy-webhook.py /opt/hy-webhook/hy-webhook.py
    info "Используется /root/hy-webhook.py"
else
    info "Скачиваем hy-webhook.py с GitHub..."
    curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/integrations/hy-webhook.py" \
        -o /opt/hy-webhook/hy-webhook.py \
        || err "Не удалось скачать hy-webhook.py"
fi
chmod +x /opt/hy-webhook/hy-webhook.py
ok "hy-webhook.py установлен"

# Секрет — используем существующий или генерируем новый
SECRETS_FILE="/etc/hy-webhook.env"
if [ -f "$SECRETS_FILE" ]; then
    WEBHOOK_SECRET=$(grep '^WEBHOOK_SECRET=' "$SECRETS_FILE" | cut -d= -f2)
    info "Используется существующий webhook secret"
else
    WEBHOOK_SECRET=$(openssl rand -hex 32)
    info "Webhook secret сгенерирован"
fi

# Если sub-injector уже установлен — отключаем встроенный proxy (PROXY_PORT=0)
# hy-webhook.py поддерживает PROXY_PORT=0 как флаг отключения встроенного proxy
_PROXY_PORT=3020
systemctl is-active --quiet remna-sub-injector 2>/dev/null && _PROXY_PORT=0 || true

# Экранируем значения с пробелами/спецсимволами через printf
_HY_NAME_ESC=$(printf '%s' "${HY_NAME}" | sed "s/'/'\\''/g")

cat > "$SECRETS_FILE" << SECRETEOF
WEBHOOK_SECRET=${WEBHOOK_SECRET}
HYSTERIA_CONFIG=/etc/hysteria/config.yaml
USERS_DB=/var/lib/hy-webhook/users.json
LISTEN_PORT=8766
HYSTERIA_SVC=hysteria-server
REMNAWAVE_URL=http://127.0.0.1:3000
REMNAWAVE_TOKEN=${REMNAWAVE_API_TOKEN:-}
HY_DOMAIN=${HY_DOMAIN}
HY_PORT=${HY_PORT}
HY_NAME=${_HY_NAME_ESC}
URI_CACHE_TTL=60
PROXY_PORT=${_PROXY_PORT}
UPSTREAM_URL=http://127.0.0.1:3010
LISTEN_HOST=0.0.0.0
DEBUG_LOG=0
SECRETEOF
chmod 600 "$SECRETS_FILE"
ok "Secrets сохранены в $SECRETS_FILE с правами 600"

cat > /etc/systemd/system/hy-webhook.service << 'SVCEOF'
[Unit]
Description=Remnawave → Hysteria2 Webhook Sync
After=network.target hysteria-server.service

[Service]
Type=simple
EnvironmentFile=/etc/hy-webhook.env
ExecStart=/usr/bin/python3 /opt/hy-webhook/hy-webhook.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now hy-webhook

# Разрешаем Docker контейнерам обращаться к hy-webhook
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow in from 172.16.0.0/12 to any port 8766 >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    ok "UFW: доступ Docker → порт 8766 разрешён"
fi

for i in $(seq 1 10); do
    systemctl is-active --quiet hy-webhook && break || sleep 1
done
systemctl is-active --quiet hy-webhook \
    && ok "hy-webhook запущен на порту 8766" \
    || err "hy-webhook не запустился — journalctl -u hy-webhook -n 20"

# ── Шаг 2: HTTP auth mode ────────────────────────────────────────
step "Переключение Hysteria2 в HTTP auth"

_HY_CFG=/etc/hysteria/config.yaml
_CURRENT_AUTH=$(grep -A2 "^auth:" "$_HY_CFG" 2>/dev/null | grep "type:" | awk "{print \$2}" || echo "")
_USERPASS_SNAPSHOT="/tmp/hy2-userpass-snapshot.yaml"
rm -f "$_USERPASS_SNAPSHOT"

if [ "$_CURRENT_AUTH" = "http" ]; then
    ok "Hysteria2 уже в HTTP auth режиме"
else
    info "Переключаем в HTTP auth (без перезапуска при смене пользователей)..."
    # Снимок нужен, чтобы после переключения auth не потерять userpass-учётки
    # при первой установке интеграции.
    cp -f "$_HY_CFG" "$_USERPASS_SNAPSHOT" 2>/dev/null || true
    python3 - << PYEOF2
import re
cfg_path = "/etc/hysteria/config.yaml"
with open(cfg_path) as f:
    cfg = f.read()
auth_http = "auth:\n  type: http\n  http:\n    url: http://127.0.0.1:8766/auth\n"
cfg = re.sub(r"auth:.*?(?=^[a-z]|\Z)", auth_http, cfg, flags=re.MULTILINE|re.DOTALL)
with open(cfg_path, "w") as f:
    f.write(cfg)
print("  auth: http записан в config.yaml")
PYEOF2
    systemctl restart hysteria-server 2>/dev/null \
        && ok "Hysteria2 перезапущена в HTTP auth режиме" \
        || warn "Hysteria2 не перезапустилась — проверьте конфиг"
fi

# ── Шаг 3: Синхронизация пользователей ───────────────────────────
step "Синхронизация существующих пользователей Hysteria2"

# Python вынесен во временный файл чтобы избежать конфликта скобок с bash
cat > /tmp/hy_patch_sync.py << 'PYEOF'
import re, json, os, sys
HYSTERIA_CONFIG = "/etc/hysteria/config.yaml"
USERS_DB = "/var/lib/hy-webhook/users.json"
SNAPSHOT = "/tmp/hy2-userpass-snapshot.yaml"
source_cfg = SNAPSHOT if os.path.exists(SNAPSHOT) else HYSTERIA_CONFIG
with open(source_cfg) as f:
    config = f.read()
users = {}
in_userpass = False
for line in config.split('\n'):
    if 'userpass:' in line:
        in_userpass = True
        continue
    if in_userpass:
        m = re.match(r'\s{4}(\S+):\s*"([^"]+)"', line)
        if m:
            users[m.group(1)] = m.group(2)
        elif line.strip() and not line.startswith(' '):
            break
if not users:
    # В HTTP auth режиме секция userpass может отсутствовать — это штатно.
    try:
        with open(USERS_DB) as f:
            existing = json.load(f)
        if isinstance(existing, dict):
            print(f"INFO: userpass не найден (HTTP auth), оставляем users.json: {len(existing)}")
        else:
            print("INFO: userpass не найден (HTTP auth), users.json не изменён")
    except Exception:
        print("INFO: userpass не найден (HTTP auth), users.json ещё не создан")
    sys.exit(0)
os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
with open(USERS_DB, 'w') as f:
    json.dump(users, f, indent=2)
print(f"Синхронизировано: {len(users)}")
for u in users:
    print(f"  - {u}")
PYEOF
python3 /tmp/hy_patch_sync.py
rm -f "$_USERPASS_SNAPSHOT" 2>/dev/null || true
ok "Пользователи синхронизированы"

# ── Шаг 3: Вебхуки в панели ──────────────────────────────────────
step "Настройка вебхуков Remnawave"

WEBHOOK_SECRET=$(grep '^WEBHOOK_SECRET=' /etc/hy-webhook.env | cut -d= -f2)
WEBHOOK_GATEWAY_IP=""

# Из контейнера Remnawave localhost указывает на сам контейнер, поэтому
# определяем gateway docker-сети панели и используем его в WEBHOOK_URL.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "remnawave"; then
    RNW_NETWORK=$(docker inspect remnawave --format '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null | head -n1)
    if [ -n "$RNW_NETWORK" ]; then
        WEBHOOK_GATEWAY_IP=$(docker network inspect "$RNW_NETWORK" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
    fi
fi

[ -z "$WEBHOOK_GATEWAY_IP" ] && WEBHOOK_GATEWAY_IP="172.17.0.1"

sed -i "s|^WEBHOOK_ENABLED=.*|WEBHOOK_ENABLED=true|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=http://${WEBHOOK_GATEWAY_IP}:8766/webhook|" /opt/remnawave/.env

# Поддерживаем два формата конфигурации Remnawave:
# 1) Новый: WEBHOOK_SECRET_HEADER=<имя заголовка>, WEBHOOK_SECRET=<секрет>
# 2) Старый: WEBHOOK_SECRET_HEADER=<секрет>
if grep -q "^WEBHOOK_SECRET=" /opt/remnawave/.env; then
    sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=X-Remnawave-Signature|" /opt/remnawave/.env
    sed -i "s|^WEBHOOK_SECRET=.*|WEBHOOK_SECRET=${WEBHOOK_SECRET}|" /opt/remnawave/.env
else
    sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=${WEBHOOK_SECRET}|" /opt/remnawave/.env
fi

ok "Вебхуки включены в .env"
info "WEBHOOK_URL установлен: http://${WEBHOOK_GATEWAY_IP}:8766/webhook"
cd /opt/remnawave && docker compose up -d --force-recreate remnawave >/dev/null 2>&1
ok "Remnawave перезапущена"

fi # DO_WEBHOOK


if $DO_SUBPAGE; then

step "Установка sub-injector"

INJECTOR_DIR="/opt/remna-sub-injector"
INJECTOR_BIN="$INJECTOR_DIR/sub-injector"
INJECTOR_CFG="$INJECTOR_DIR/config.toml"
_ARCH=$(uname -m)
case "$_ARCH" in
    x86_64|amd64)  _ARCH="x86_64" ;;
    aarch64|arm64) _ARCH="aarch64" ;;
    *) warn "Архитектура $_ARCH не поддерживается — попробуем x86_64"; _ARCH="x86_64" ;;
esac
INJECTOR_URL="https://github.com/stump3/server-manager/releases/latest/download/sub-injector-${_ARCH}-linux"

mkdir -p "$INJECTOR_DIR"

# ── Скачиваем бинарник из releases stump3/server-manager ─────────
info "Скачиваем sub-injector..."
if curl -fsSL "$INJECTOR_URL" -o "${INJECTOR_BIN}.new" 2>/dev/null; then
    systemctl stop remna-sub-injector 2>/dev/null || true
    mv "${INJECTOR_BIN}.new" "$INJECTOR_BIN"
    chmod +x "$INJECTOR_BIN"
    ok "sub-injector установлен: $INJECTOR_BIN"
else
    warn "Бинарник недоступен — собираем из sub-injector/ репозитория"
    # Устанавливаем Rust если нет, или подключаем уже установленный
    if ! command -v cargo &>/dev/null; then
        if [ -f "$HOME/.cargo/env" ]; then
            # Rust установлен но не в PATH — подключаем
            # shellcheck source=/dev/null
            source "$HOME/.cargo/env"
        fi
    fi
    if ! command -v cargo &>/dev/null; then
        info "Устанавливаем зависимости сборки (gcc, pkg-config, libssl-dev)..."
        apt-get install -y -q build-essential pkg-config libssl-dev 2>/dev/null             || { warn "apt не сработал — пробуем продолжить без него"; }
        info "Устанавливаем Rust (потребуется 2-3 минуты)..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path             || err "Не удалось установить Rust"
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    # build-essential нужен даже если cargo уже есть (линкер cc)
    if ! command -v cc &>/dev/null; then
        info "Устанавливаем build-essential (линкер cc не найден)..."
        apt-get install -y -q build-essential 2>/dev/null || true
    fi
    command -v cargo &>/dev/null || err "cargo не найден после установки Rust"

    # Используем локальные исходники если есть, иначе скачиваем
    SCRIPT_REPO_DIR="$(dirname "$0")/.."
    INJECTOR_SRC="/tmp/sm-sub-injector"
    rm -rf "$INJECTOR_SRC" && mkdir -p "$INJECTOR_SRC/src"

    if [ -f "${SCRIPT_REPO_DIR}/sub-injector/src/main.rs" ]; then
        cp "${SCRIPT_REPO_DIR}/sub-injector/Cargo.toml" "$INJECTOR_SRC/"
        cp "${SCRIPT_REPO_DIR}/sub-injector/src/main.rs" "$INJECTOR_SRC/src/"
        info "Используются локальные исходники sub-injector"
    else
        curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/sub-injector/Cargo.toml"             -o "$INJECTOR_SRC/Cargo.toml" || err "Не удалось скачать Cargo.toml"
        curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/sub-injector/src/main.rs"             -o "$INJECTOR_SRC/src/main.rs" || err "Не удалось скачать main.rs"
    fi

    info "Сборка sub-injector (2-5 минут)..."
    cd "$INJECTOR_SRC"
    if ! cargo build --release 2>&1 | tail -10; then
        err "Сборка sub-injector завершилась с ошибкой"
    fi
    [ -f "target/release/sub-injector" ] || err "Бинарник не найден после сборки"
    systemctl stop remna-sub-injector 2>/dev/null || true
    cp target/release/sub-injector "$INJECTOR_BIN"
    chmod +x "$INJECTOR_BIN"
    ok "sub-injector собран из исходников"
fi

# ── Конфиг ────────────────────────────────────────────────────────
if [ -f "$INJECTOR_CFG" ]; then
    info "Конфиг уже существует — пропускаем"
else
    cat > "$INJECTOR_CFG" << TOMLEOF
upstream_url = "http://127.0.0.1:3010"
bind_addr = "0.0.0.0:3020"

[[injections]]
header = "User-Agent"
contains = ["throne", "hiddify", "happ", "nekobox", "nekoray", "v2rayn", "v2rayng", "sing-box", "clash.meta", "mihomo"]
per_user_url = "http://127.0.0.1:8766/uri"
TOMLEOF
    ok "Конфиг создан: $INJECTOR_CFG"
fi

# ── Systemd ───────────────────────────────────────────────────────
cat > /etc/systemd/system/remna-sub-injector.service << 'SVCEOF'
[Unit]
Description=Remnawave Subscription Injector
After=network.target hy-webhook.service

[Service]
Type=simple
WorkingDirectory=/opt/remna-sub-injector
ExecStart=/opt/remna-sub-injector/sub-injector /opt/remna-sub-injector/config.toml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now remna-sub-injector

# sub-injector занял :3020 — отключаем встроенный proxy в hy-webhook
if grep -q "^PROXY_PORT=3020" /etc/hy-webhook.env 2>/dev/null; then
    sed -i "s/^PROXY_PORT=.*/PROXY_PORT=0/" /etc/hy-webhook.env
    systemctl is-active --quiet hy-webhook && systemctl restart hy-webhook || true
    ok "hy-webhook: встроенный proxy отключён (sub-injector занял :3020)"
fi

for i in $(seq 1 10); do
    systemctl is-active --quiet remna-sub-injector && break || sleep 1
done
systemctl is-active --quiet remna-sub-injector     && ok "remna-sub-injector запущен — порт 3020"     || err "remna-sub-injector не запустился — journalctl -u remna-sub-injector -n 20"

# ── nginx: sub домен → injector :3020 ────────────────────────────
step "Обновление веб-сервера"

if [ -f /opt/remnawave/Caddyfile ]; then
    if grep -q "3010" /opt/remnawave/Caddyfile; then
        sed -i "s|127.0.0.1:3010|127.0.0.1:3020|g" /opt/remnawave/Caddyfile
        docker exec remnawave-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
            && ok "Caddy: sub домен → injector :3020" \
            || { cd /opt/remnawave && docker compose restart remnawave-caddy >/dev/null 2>&1
                 ok "Caddy перезапущен: sub → :3020"; }
    elif grep -q "3020" /opt/remnawave/Caddyfile; then
        ok "Caddy уже настроен на :3020"
    else
        warn "Upstream :3010 не найден в Caddyfile — настройте вручную"
    fi
elif [ -f /opt/remnawave/nginx.conf ]; then
    if grep -q "3010" /opt/remnawave/nginx.conf; then
        sed -i "s|127.0.0.1:3010|127.0.0.1:3020|g" /opt/remnawave/nginx.conf
        docker exec remnawave-nginx nginx -t >/dev/null 2>&1 \
            && { cd /opt/remnawave && docker compose restart remnawave-nginx >/dev/null 2>&1
                 ok "Nginx: sub домен → injector :3020"; } \
            || warn "Nginx конфиг невалиден — проверьте вручную"
    elif grep -q "3020" /opt/remnawave/nginx.conf; then
        ok "Nginx уже настроен на :3020"
    else
        warn "Upstream :3010 не найден в nginx.conf — настройте вручную"
    fi
else
    warn "Конфиг веб-сервера не найден — обновите upstream вручную на :3020"
fi

fi # DO_SUBPAGE


# ── Очистка временных файлов ──────────────────────────────────────
rm -f /tmp/hy_patch_*.py

# ── Итог ──────────────────────────────────────────────────────────
WEBHOOK_SECRET_DISPLAY=""
[ -f /etc/hy-webhook.env ] && \
    WEBHOOK_SECRET_DISPLAY=$(grep '^WEBHOOK_SECRET=' /etc/hy-webhook.env | cut -d= -f2)

# ── Статус сервисов ───────────────────────────────────────────────
HW_STATUS="${RED}○ не запущен${NC}"
systemctl is-active --quiet hy-webhook 2>/dev/null && HW_STATUS="${GREEN}● запущен${NC}"
INJECTOR_STATUS="${RED}○ не запущен${NC}"
systemctl is-active --quiet remna-sub-injector 2>/dev/null && INJECTOR_STATUS="${GREEN}● запущен${NC}"
RW_STATUS="${RED}○ не запущен${NC}"
docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^remnawave$"     && RW_STATUS="${GREEN}● запущен${NC}"

echo ""
echo -e "${GREEN}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║   ✅  Установка завершена!                               ║${NC}"
echo -e "${GREEN}  ╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Статус сервисов
echo -e "  ${BOLD}Статус сервисов:${NC}"
printf "  %-24s %b\n" "hy-webhook"           "$(echo -e "$HW_STATUS")"
printf "  %-24s %b\n" "remna-sub-injector"   "$(echo -e "$INJECTOR_STATUS")"
printf "  %-24s %b\n" "remnawave"            "$(echo -e "$RW_STATUS")"
echo ""

# Конфигурация
echo -e "${BOLD}${WHITE}  Конфигурация${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${DIM}Домен   ${NC}${HY_DOMAIN}"
echo -e "  ${DIM}Порт    ${NC}${HY_PORT}"
echo -e "  ${DIM}Название${NC}${HY_NAME}"
if $HAS_PORT_HOPPING; then
    echo -e "  ${DIM}Hopping ${NC}${HOP_RANGE} ${GREEN}(включён)${NC}"
fi
echo ""

# Webhook secret
echo -e "${BOLD}${YELLOW}  ⚠  Webhook secret — сохраните сейчас, больше не показывается!${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${CYAN}${WEBHOOK_SECRET_DISPLAY}${NC}"
echo -e "  ${DIM}Файл: /etc/hy-webhook.env${NC}"
echo ""

echo -e "${BOLD}${WHITE}  Проверка${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${DIM}Webhook health:   ${NC}curl -s http://127.0.0.1:8766/health"
echo -e "  ${DIM}Test URI endpoint:${NC}curl -s http://127.0.0.1:8766/uri/TEST_SHORT_UUID"
echo -e "  ${DIM}Injector health:  ${NC}curl -s http://127.0.0.1:3020/health"
echo -e "  ${DIM}Логи webhook:     ${NC}journalctl -u hy-webhook -f"
echo -e "  ${DIM}Логи injector:    ${NC}journalctl -u remna-sub-injector -f"
echo ""

echo -e "${BOLD}${WHITE}  Что дальше${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${DIM}Подписка: ${NC}https://${SUB_DOMAIN}/ТОКЕН"
echo -e "  • Новые пользователи получат персональный hy2:// URI автоматически"
echo -e "  • Клиенты Hiddify/v2rayNG получают URI через remna-sub-injector"
echo -e "  • Clash/Sing-Box — YAML конфиги проходят без изменений"
echo -e "  • Существующим пользователям — попросите обновить подписку"
echo ""
read -rp "  Нажмите Enter для продолжения..." < /dev/tty 2>/dev/null || true
