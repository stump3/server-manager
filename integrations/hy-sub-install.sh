#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  SERVER-MANAGER — Hysteria2 ↔ Remnawave Subscription Sync       ║
# ║                                                                  ║
# ║  Устанавливает:                                                  ║
# ║  1. hy-webhook  — синхронизация пользователей через вебхук      ║
# ║  2. Форк subscription-page — Hysteria2 URI в подписке            ║
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
TOTAL_STEPS=7

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo ""
    echo -e "${BOLD}${CYAN}━━━ [${STEP_NUM}/${TOTAL_STEPS}] $* ━━━${NC}"
    echo ""
}

# ── Очистка при ошибке ────────────────────────────────────────────
cleanup() {
    echo -e "${RED}✗ Ошибка на строке $LINENO — установка прервана${NC}"
    rm -rf /opt/hy-subpage /tmp/hy_patch_*.py 2>/dev/null || true
    systemctl is-active --quiet hy-webhook 2>/dev/null || \
        systemctl stop hy-webhook 2>/dev/null || true
    exit 1
}
trap cleanup ERR

# ── Проверки ──────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && err "Запустите от root"
[ -d /opt/remnawave ]            || err "Remnawave не установлена"
[ -f /etc/hysteria/config.yaml ] || err "Hysteria2 не установлена"

# ── Идемпотентность ───────────────────────────────────────────────
DO_WEBHOOK=true
DO_SUBPAGE=true
TOTAL_STEPS=6

if systemctl is-active --quiet hy-webhook 2>/dev/null && \
   docker ps --format '{{.Image}}' 2>/dev/null | grep -q 'remnawave-sub-hy:local'; then
    echo ""
    echo -e "  ${YELLOW}●${NC} ${BOLD}Интеграция уже установлена${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Переустановить полностью"
    echo -e "       ${GRAY}webhook + форк subscription-page${NC}"
    echo -e "  ${BOLD}2)${NC} Обновить форк subscription-page"
    echo -e "       ${GRAY}пересобрать Docker образ с новыми патчами${NC}"
    echo -e "  ${BOLD}3)${NC} Обновить hy-webhook"
    echo -e "       ${GRAY}заменить скрипт синхронизации${NC}"
    echo -e "  ${BOLD}0)${NC} ${GRAY}Отмена${NC}"
    echo ""
    read -rp "  Выбор: " reinstall_ch < /dev/tty
    case "$reinstall_ch" in
        1) info "Переустановка полностью..." ;;
        2) DO_WEBHOOK=false; TOTAL_STEPS=5 ;;
        3) DO_SUBPAGE=false; TOTAL_STEPS=4 ;;
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
    if [ "${hop_ch:-0}" != "0" ]; then
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

read -rp "  Название подключения [🇩🇪 Germany Hysteria2]: " HY_NAME < /dev/tty
HY_NAME="${HY_NAME:-🇩🇪 Germany Hysteria2}"

# ── Шаг 1: hy-webhook ────────────────────────────────────────────
if $DO_WEBHOOK; then

step "Установка hy-webhook"

mkdir -p /opt/hy-webhook /var/lib/hy-webhook

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/hy-webhook.py" ]; then
    cp "${SCRIPT_DIR}/hy-webhook.py" /opt/hy-webhook/hy-webhook.py
    info "Используется локальный hy-webhook.py"
elif [ -f /root/hy-webhook.py ]; then
    cp /root/hy-webhook.py /opt/hy-webhook/hy-webhook.py
    info "Используется /root/hy-webhook.py"
else
    info "Скачиваем hy-webhook.py с GitHub..."
    curl -fsSL "https://raw.githubusercontent.com/stump3/server-manager/main/hy-webhook.py" \
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

cat > "$SECRETS_FILE" << SECRETEOF
WEBHOOK_SECRET=${WEBHOOK_SECRET}
HYSTERIA_CONFIG=/etc/hysteria/config.yaml
USERS_DB=/var/lib/hy-webhook/users.json
LISTEN_PORT=8766
HYSTERIA_SVC=hysteria-server
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

for i in $(seq 1 10); do
    systemctl is-active --quiet hy-webhook && break || sleep 1
done
systemctl is-active --quiet hy-webhook \
    && ok "hy-webhook запущен на порту 8766" \
    || err "hy-webhook не запустился — journalctl -u hy-webhook -n 20"

# ── Шаг 2: Синхронизация пользователей ───────────────────────────
step "Синхронизация существующих пользователей Hysteria2"

# Python вынесен во временный файл чтобы избежать конфликта скобок с bash
cat > /tmp/hy_patch_sync.py << 'PYEOF'
import re, json, os, sys
HYSTERIA_CONFIG = "/etc/hysteria/config.yaml"
USERS_DB = "/var/lib/hy-webhook/users.json"
with open(HYSTERIA_CONFIG) as f:
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
    print("WARN: пользователи не найдены в конфиге")
    sys.exit(0)
os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
with open(USERS_DB, 'w') as f:
    json.dump(users, f, indent=2)
print(f"Синхронизировано: {len(users)}")
for u in users:
    print(f"  - {u}")
PYEOF
python3 /tmp/hy_patch_sync.py
ok "Пользователи синхронизированы"

# ── Шаг 3: Вебхуки в панели ──────────────────────────────────────
step "Настройка вебхуков Remnawave"

WEBHOOK_SECRET=$(grep '^WEBHOOK_SECRET=' /etc/hy-webhook.env | cut -d= -f2)
sed -i "s|^WEBHOOK_ENABLED=.*|WEBHOOK_ENABLED=true|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=http://127.0.0.1:8766/webhook|" /opt/remnawave/.env
sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=${WEBHOOK_SECRET}|" /opt/remnawave/.env

ok "Вебхуки включены в .env"
cd /opt/remnawave && docker compose restart remnawave >/dev/null 2>&1
ok "Remnawave перезапущена"

fi # DO_WEBHOOK

# ── Шаг 4: Форк subscription-page ───────────────────────────────
if $DO_SUBPAGE; then

step "Установка форка subscription-page"

command -v docker &>/dev/null || err "Docker не найден"

rm -rf /opt/hy-subpage
mkdir -p /opt/hy-subpage

info "Скачиваем исходники subscription-page..."
curl -fsSL "https://github.com/remnawave/subscription-page/archive/refs/heads/main.tar.gz" \
    -o /opt/hy-subpage/source.tar.gz \
    || err "Не удалось скачать исходники"
tar -xzf /opt/hy-subpage/source.tar.gz -C /opt/hy-subpage --strip-components=1
rm /opt/hy-subpage/source.tar.gz
ok "Исходники скачаны"

ROOTSVC="/opt/hy-subpage/backend/src/modules/root/root.service.ts"
AXSVC="/opt/hy-subpage/backend/src/common/axios/axios.service.ts"

[ -f "$ROOTSVC" ] || err "root.service.ts не найден — структура пакета изменилась"
[ -f "$AXSVC" ]   || err "axios.service.ts не найден — структура пакета изменилась"

# Патч 1: импорт fs
if grep -q "import \* as fs from 'node:fs'" "$ROOTSVC"; then
    info "Патч 1: импорт fs уже есть"
else
    sed -i "s|import { nanoid } from 'nanoid';|import { nanoid } from 'nanoid';\nimport * as fs from 'node:fs';|" "$ROOTSVC"
    ok "Патч 1: импорт fs"
fi

# Патч 2 и 3 — выносим Python во временные файлы
# Патч 2: инжекция URI + метод getHysteriaUriForUser
cat > /tmp/hy_patch_rootsvc.py << 'PYEOF'
import sys
rootsvc = "/opt/hy-subpage/backend/src/modules/root/root.service.ts"
with open(rootsvc) as f:
    content = f.read()

if 'getHysteriaUriForUser' in content:
    print("INFO: Патч 2 уже применён")
    sys.exit(0)

inject = """            // ── Hysteria2 URI injection ──────────────────────────
            try {
                const hyUri = await this.getHysteriaUriForUser(shortUuidLocal, clientIp);
                if (hyUri) {
                    const raw = subscriptionDataResponse.response as string;
                    let lines: string[] = [];
                    try {
                        lines = Buffer.from(raw, 'base64').toString('utf-8')
                            .split('\\n').filter(l => l.trim());
                    } catch {
                        lines = raw.split('\\n').filter(l => l.trim());
                    }
                    lines.push(hyUri);
                    subscriptionDataResponse = {
                        ...subscriptionDataResponse,
                        response: Buffer.from(lines.join('\\n')).toString('base64'),
                    };
                }
            } catch (e) {
                this.logger.warn('Hysteria2 inject error: ' + e);
            }
            // ─────────────────────────────────────────────────────"""

old = "            if (subscriptionDataResponse.headers) {"
if old not in content:
    print("ERROR: точка вставки не найдена")
    sys.exit(1)
content = content.replace(old, inject + "\n\n" + old, 1)
print("OK: inject добавлен")

method = """
    private async getHysteriaUriForUser(
        shortUuid: string,
        clientIp: string,
    ): Promise<string | null> {
        try {
            const usersDb = process.env.HY_USERS_DB || '/var/lib/hy-webhook/users.json';
            const hyDomain = process.env.HY_DOMAIN || '';
            const hyPort = process.env.HY_PORT || '8443';
            const hyName = process.env.HY_NAME || 'Hysteria2';
            if (!hyDomain) return null;
            let users: Record<string, string> = {};
            try {
                const raw = fs.readFileSync(usersDb, 'utf-8');
                users = JSON.parse(raw);
            } catch { return null; }
            const userInfo = await this.axiosService.getUserByShortUuid(clientIp, shortUuid);
            if (!userInfo.isOk || !userInfo.response) return null;
            const username = (userInfo.response as any).response?.username;
            if (!username) return null;
            const safeUsername = username.replace(/[^\\w\\-.]/g, '_');
            const password = users[safeUsername] || users[username];
            if (!password) return null;
            return 'hy2://' + encodeURIComponent(safeUsername) + ':' + password +
                '@' + hyDomain + ':' + hyPort +
                '?sni=' + hyDomain + '&alpn=h3&insecure=0#' + encodeURIComponent(hyName);
        } catch (e) {
            this.logger.warn('getHysteriaUriForUser error: ' + e);
            return null;
        }
    }
}
"""

content = content.rstrip()
if not content.endswith('}'):
    print("ERROR: конец класса не найден")
    sys.exit(1)
content = content[:-1].rstrip() + '\n' + method
print("OK: getHysteriaUriForUser добавлен")

with open(rootsvc, 'w') as f:
    f.write(content)
PYEOF
python3 /tmp/hy_patch_rootsvc.py || err "Патч 2 не применился"
ok "Патч 2: инжекция URI"

# Патч 3: getUserByShortUuid
cat > /tmp/hy_patch_axsvc.py << 'PYEOF'
import sys
axsvc = "/opt/hy-subpage/backend/src/common/axios/axios.service.ts"
with open(axsvc) as f:
    content = f.read()

if 'getUserByShortUuid' in content:
    print("INFO: Патч 3 уже применён")
    sys.exit(0)

method = """
    public async getUserByShortUuid(
        clientIp: string,
        shortUuid: string,
    ): Promise<any> {
        try {
            const { data } = await this.axiosInstance.request({
                method: 'GET',
                url: 'api/users/get-by/short-uuid/' + shortUuid,
                headers: { 'x-remnawave-real-ip': clientIp },
            });
            return { isOk: true, response: data };
        } catch (error: any) {
            this.logger.error('Error in GetUserByShortUuid: ' + error.message);
            return { isOk: false };
        }
    }
"""

insert_before = "    public async getSubscription("
if insert_before not in content:
    print("ERROR: место вставки не найдено")
    sys.exit(1)
content = content.replace(insert_before, method + "\n" + insert_before, 1)
print("OK: getUserByShortUuid добавлен")

with open(axsvc, 'w') as f:
    f.write(content)
PYEOF
python3 /tmp/hy_patch_axsvc.py || err "Патч 3 не применился"
ok "Патч 3: getUserByShortUuid"

# ── Сборка образа ─────────────────────────────────────────────────
info "Сборка Docker образа (2-5 минут)..."
cd /opt/hy-subpage

if [ ! -d "frontend/dist" ]; then
    info "Сборка frontend..."
    docker run --rm -v "$(pwd)/frontend:/app" -w /app node:24-alpine \
        sh -c "npm ci && npm run build" >/dev/null 2>&1 \
        && ok "Frontend собран" || warn "Ошибка сборки frontend — продолжаем"
fi

docker build --no-cache -t remnawave-sub-hy:local . 2>&1 | tail -5
docker inspect remnawave-sub-hy:local &>/dev/null \
    || err "Docker образ не собрался"
ok "Docker образ собран: remnawave-sub-hy:local"

# ── Шаг 5: docker-compose.yml ────────────────────────────────────
step "Обновление docker-compose.yml"

cat > /tmp/hy_patch_compose.py << PYEOF
import re, sys

with open("/opt/remnawave/docker-compose.yml") as f:
    content = f.read()

content = re.sub(
    r'(image:\s*)remnawave/subscription-page:[^\n]+',
    r'\1remnawave-sub-hy:local',
    content
)

hy_domain = "${HY_DOMAIN}"
hy_port   = "${HY_PORT}"
hy_name   = "${HY_NAME}"

env_block = (
    "    environment:\n"
    f"      - HY_DOMAIN={hy_domain}\n"
    f"      - HY_PORT={hy_port}\n"
    f"      - HY_NAME={hy_name}\n"
    "      - HY_USERS_DB=/var/lib/hy-webhook/users.json\n"
    "    volumes:\n"
    "      - /var/lib/hy-webhook:/var/lib/hy-webhook:ro\n"
)

marker = 'container_name: remnawave-subscription-page\n'
if marker not in content:
    print("ERROR: блок subscription-page не найден")
    sys.exit(1)

if 'HY_DOMAIN' not in content:
    # Удаляем ВСЕ существующие environment/volumes строки подписки
    # и добавляем наш блок
    result = []
    in_sub = False
    skip_block = False
    for ln in content.split('\n'):
        if 'container_name: remnawave-subscription-page' in ln:
            in_sub = True
            result.append(ln)
            continue
        if in_sub:
            stripped = ln.strip()
            # Пропускаем environment и volumes блоки
            if stripped in ('environment:', 'volumes:'):
                skip_block = True
                continue
            if skip_block:
                if stripped.startswith('- '):
                    continue  # строки внутри блока
                else:
                    skip_block = False
                    in_sub = False
        result.append(ln)
    content = '\n'.join(result)
    content = content.replace(marker, marker + env_block)
    print("OK: docker-compose обновлён")


else:
    content = re.sub(r'- HY_DOMAIN=.*', f'- HY_DOMAIN={hy_domain}', content)
    content = re.sub(r'- HY_PORT=.*',   f'- HY_PORT={hy_port}',     content)
    content = re.sub(r'- HY_NAME=.*',   f'- HY_NAME={hy_name}',     content)
    print("OK: docker-compose обновлён — существующие значения")

with open("/opt/remnawave/docker-compose.yml", "w") as f:
    f.write(content)
PYEOF
python3 /tmp/hy_patch_compose.py || err "Ошибка обновления docker-compose.yml"
ok "docker-compose.yml обновлён"

# ── Шаг 6: nginx ─────────────────────────────────────────────────
step "Настройка nginx"

if [ -f /opt/remnawave/nginx.conf ]; then
    if grep -q "location /merge/" /opt/remnawave/nginx.conf; then
        warn "location /merge/ уже существует — пропускаем"
    elif ! systemctl is-active --quiet hy-merger 2>/dev/null; then
        warn "hy-merger не запущен — location /merge/ не добавляем"
        info "Установите merger: server-manager.sh → Hysteria2 → Подписка → Объединить с Remnawave"
    else
        cat > /tmp/hy_patch_nginx.py << 'PYEOF'
import sys
with open('/opt/remnawave/nginx.conf') as f:
    cfg = f.read()
loc = (
    "    location /merge/ {\n"
    "        proxy_pass http://127.0.0.1:8765/;\n"
    "        proxy_set_header Host $host;\n"
    "        proxy_set_header X-Real-IP $proxy_protocol_addr;\n"
    "        proxy_set_header X-Forwarded-For $proxy_protocol_addr;\n"
    "        proxy_set_header X-Forwarded-Proto $scheme;\n"
    "    }\n"
    "    # NOTE: порт 8765 — hy-merger.service\n"
)
marker = '    location @redirect {'
if marker not in cfg:
    print("WARN: @redirect не найден — добавьте location /merge/ вручную")
    sys.exit(0)
cfg = cfg.replace(marker, loc + marker, 1)
print("OK: location /merge/ добавлен в sub домен")
with open('/opt/remnawave/nginx.conf', 'w') as f:
    f.write(cfg)
PYEOF
        python3 /tmp/hy_patch_nginx.py
        ok "nginx.conf обновлён"
    fi

    docker exec remnawave-nginx nginx -t >/dev/null 2>&1 \
        && ok "nginx конфиг валиден" \
        || warn "nginx конфиг невалиден — проверьте вручную"
fi

# ── Запуск ────────────────────────────────────────────────────────
cd /opt/remnawave
docker compose up -d remnawave-subscription-page 2>&1 | tail -3
docker compose restart remnawave-nginx >/dev/null 2>&1

info "Ждём запуска контейнера..."
for i in $(seq 1 15); do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-subscription-page" && break || sleep 1
done
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-subscription-page"; then
    ok "subscription-page запущен"
else
    warn "Контейнер не виден в docker ps — проверьте: docker logs remnawave-subscription-page"
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
SP_STATUS="${RED}○ не запущен${NC}"
docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-subscription-page"     && SP_STATUS="${GREEN}● запущен${NC}"
RW_STATUS="${RED}○ не запущен${NC}"
docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^remnawave$"     && RW_STATUS="${GREEN}● запущен${NC}"

echo ""
echo -e "${GREEN}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║   ✅  Установка завершена!                               ║${NC}"
echo -e "${GREEN}  ╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Статус сервисов
echo -e "  ${BOLD}Статус сервисов:${NC}"
echo -e "  hy-webhook             $(echo -e "$HW_STATUS")"
echo -e "  subscription-page      $(echo -e "$SP_STATUS")"
echo -e "  remnawave              $(echo -e "$RW_STATUS")"
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
echo -e "  ${DIM}Health:    ${NC}curl -s http://127.0.0.1:8766/health"
echo -e "  ${DIM}Логи:      ${NC}journalctl -u hy-webhook -f"
echo -e "  ${DIM}Контейнер: ${NC}docker logs remnawave-subscription-page"
echo ""

echo -e "${BOLD}${WHITE}  Что дальше${NC}"
echo -e "  ${DIM}────────────────────────────${NC}"
echo -e "  ${DIM}Подписка: ${NC}https://${SUB_DOMAIN}/ТОКЕН"
echo -e "  • Новые пользователи получат Hysteria2 URI автоматически"
echo -e "  • Существующим — попросите обновить подписку в клиенте"
echo ""
