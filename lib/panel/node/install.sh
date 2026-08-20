# shellcheck shell=bash
#
# lib/panel/node/install.sh — Remote Node: полный orchestration-flow
# (Stage 7, STEP 2 деплой + STEP 3 регистрация/health-check).
#
# Запускается С Panel-хоста, отдельным пунктом меню, ПОСЛЕ того как Panel
# уже установлена (нужны существующие SUPERADMIN_USER/PASS для входа в
# Panel API — они не хранятся server-manager'ом между сессиями, поэтому
# запрашиваются здесь заново).
#
# Переиспользует без изменений: ask_ssh_target, init_ssh_helpers,
# check_ssh_connection, RUN, PUT (lib/common/ssh.sh); remote_install_deps
# (вариант "node"); ask, validate_domain, confirm, get_public_ip
# (lib/common/*); panel_generate_node_compose (lib/panel/node/compose.sh,
# STEP 1, не изменялся); panel_generate_selfsteal_site (lib/panel/install.sh,
# параметризован опциональным output-dir); panel_node_fetch_secret,
# panel_node_register, panel_node_wait_connected (lib/panel/node/api.sh).
#
# Firewall-инвариант: 2222/tcp на ноде открыт ТОЛЬКО с адреса Panel
# (PANEL_IP) — никогда 0.0.0.0/0. get_public_ip() предлагается как
# редактируемый default, не как единственный источник (см. предыдущие
# раунды исследования — автоопределение не считается надёжным сам по себе).

panel_install_remote_node() {
    header "Remote Node — установка"
    echo ""
    warn "Panel должна быть уже установлена — потребуются её admin-credentials."
    warn "Повторный запуск создаст новую ноду/хост в Panel (операция не идемпотентна)."
    echo ""

    local _selfsteal_staging=""
    trap 'rm -rf /opt/remnanode "$_selfsteal_staging" 2>/dev/null' RETURN

    section "Вход в Panel API"
    local SUPERADMIN_USER SUPERADMIN_PASS
    ask SUPERADMIN_USER "Логин суперадмина Panel"
    stty -echo 2>/dev/null || true
    read -rp "  Пароль суперадмина Panel: " SUPERADMIN_PASS < /dev/tty
    stty echo 2>/dev/null || true
    echo ""

    info "Получение Node authentication secret..."
    local SECRET_KEY
    SECRET_KEY=$(panel_node_fetch_secret "$SUPERADMIN_USER" "$SUPERADMIN_PASS")
    if [ -z "$SECRET_KEY" ]; then
        warn "Не удалось авторизоваться / получить secret из Panel API. Проверьте логин/пароль."
        return 1
    fi
    ok "Secret получен"

    section "Данные ноды"
    ensure_sshpass
    ask_ssh_target || { warn "Ошибка ввода данных SSH"; return 1; }
    init_ssh_helpers full
    check_ssh_connection || return 1

    local SELFSTEAL_DOMAIN
    while true; do
        ask SELFSTEAL_DOMAIN "Selfsteal-домен этой ноды (node.example.com)"
        validate_domain "$SELFSTEAL_DOMAIN" && break || warn "Неверный формат"
    done

    local PANEL_IP _default_ip
    _default_ip="$(get_public_ip 2>/dev/null || echo "")"
    while true; do
        ask PANEL_IP "IP этой панели (для firewall-разрешения :2222 на ноде)" "$_default_ip"
        [[ "$PANEL_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        warn "Неверный формат IP"
    done

    echo ""
    remote_install_deps node || return 1

    # ── Locking down control port: только с PANEL_IP ────────────────
    if RUN "ufw allow from ${PANEL_IP} to any port 2222 proto tcp"; then
        ok "2222/tcp разрешён только с ${PANEL_IP}"
    else
        warn "Не удалось добавить firewall-правило для 2222/tcp — проверьте вручную на ${_SSH_IP}"
        return 1
    fi

    # ── Локальная генерация (staging на Panel-хосте) ───────────────
    info "Генерация docker-compose.yml и Caddyfile для ноды..."
    rm -rf /opt/remnanode 2>/dev/null
    panel_generate_node_compose "$SECRET_KEY" "$SELFSTEAL_DOMAIN"

    _selfsteal_staging="$(mktemp -d /tmp/sm_node_selfsteal_XXXXXX)"
    panel_generate_selfsteal_site "$_selfsteal_staging"

    # ── Перенос файлов на ноду ──────────────────────────────────────
    info "Копирование файлов на ${_SSH_IP}..."
    PUT /opt/remnanode/docker-compose.yml /opt/remnanode/Caddyfile \
        "${_SSH_USER}@${_SSH_IP}:/opt/remnanode/" || { warn "Не удалось скопировать compose/Caddyfile"; return 1; }
    RUN "mkdir -p /var/www/html" || true
    PUT "${_selfsteal_staging}/." \
        "${_SSH_USER}@${_SSH_IP}:/var/www/html/" || { warn "Не удалось скопировать selfsteal-контент"; return 1; }

    # ── Запуск ───────────────────────────────────────────────────────
    info "Запуск remnanode + Caddy на ${_SSH_IP}..."
    RUN "cd /opt/remnanode && docker compose up -d" || { warn "Не удалось запустить контейнеры на ноде"; return 1; }

    # ── Технические проверки ────────────────────────────────────────
    info "Проверка доступности control-порта 2222..."
    sleep 3
    if RUN "ss -tln 2>/dev/null | grep -q ':2222 '"; then
        ok "Нода слушает :2222"
    else
        warn "Не удалось подтвердить, что нода слушает :2222 — проверьте логи (docker compose logs) на ${_SSH_IP}"
    fi

    # ── Регистрация в Panel API ─────────────────────────────────────
    section "Регистрация в Panel"
    local _reg_out TOKEN NODE_UUID
    _reg_out=$(panel_node_register "$SUPERADMIN_USER" "$SUPERADMIN_PASS" "$SELFSTEAL_DOMAIN" "$_SSH_IP")
    if [ -z "$_reg_out" ]; then
        warn "Регистрация в Panel API не удалась. Нода развёрнута, но не зарегистрирована."
        warn "Повторите регистрацию вручную через Panel UI или запустите операцию снова."
        return 1
    fi
    TOKEN="${_reg_out%% *}"
    NODE_UUID="${_reg_out##* }"

    # ── Health-check ─────────────────────────────────────────────────
    echo ""
    section "Проверка подключения"
    if panel_node_wait_connected "$TOKEN" "$NODE_UUID"; then
        echo ""
        ok "Remote Node развёрнута, зарегистрирована и подключена: ${_SSH_IP} (${SELFSTEAL_DOMAIN})"
        echo -e "  ${GRAY}Node UUID: ${NODE_UUID}${NC}"
    else
        echo ""
        warn "Remote Node развёрнута и зарегистрирована в Panel (uuid=${NODE_UUID}),"
        warn "но Panel пока не подтвердил подключение (isConnected != true)."
        warn "Нода НЕ считается полностью готовой. Проверьте:"
        warn "  · docker compose logs remnanode на ${_SSH_IP}"
        warn "  · что порт 2222 на ноде открыт для IP этой панели (${PANEL_IP})"
        warn "  · при необходимости удалите/пересоздайте ноду через Panel UI (uuid=${NODE_UUID})"
    fi
    echo ""
    read -rp "  Нажмите Enter чтобы продолжить..." < /dev/tty
}
