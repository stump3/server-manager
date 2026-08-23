# shellcheck shell=bash
# common/ssh.sh — SSH migration helpers (sshpass, target input, RUN/PUT, remote deps)


# Установка sshpass (нужна для migrate в обоих разделах)
ensure_sshpass() {
    command -v sshpass &>/dev/null && return 0
    info "Установка sshpass..."
    apt-get install -y -q sshpass 2>/dev/null || \
        yum install -y sshpass 2>/dev/null || \
        die "Не удалось установить sshpass. Установи вручную: apt install sshpass"
    ok "sshpass установлен"
}


# ── SSH-миграция: ввод данных ─────────────────────────────────────
# Результат записывается в переменные: _SSH_IP _SSH_PORT _SSH_USER _SSH_PASS
ask_ssh_target() {
    # Восстанавливаем эхо терминала при выходе (на случай прерывания после read -rsp)
    trap 'stty echo 2>/dev/null || true' RETURN
    while true; do
        read -rp "  IP нового сервера: " _SSH_IP < /dev/tty
        [[ "$_SSH_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        warn "Неверный формат IP"
    done
    read -rp "  SSH-порт [22]: "         _SSH_PORT < /dev/tty; _SSH_PORT="${_SSH_PORT:-22}"
    read -rp "  Пользователь [root]: "   _SSH_USER < /dev/tty; _SSH_USER="${_SSH_USER:-root}"
    while true; do
        stty -echo 2>/dev/null || true
        read -rp "  Пароль SSH: " _SSH_PASS < /dev/tty
        stty echo 2>/dev/null || true
        echo ""
        [ -n "$_SSH_PASS" ] && break
        warn "Пароль не может быть пустым"
    done
    export _SSH_IP _SSH_PORT _SSH_USER _SSH_PASS
}

# ── SSH-миграция: инициализация хелперов RUN/PUT ──────────────────
# init_ssh_helpers [panel|telemt|hysteria|full]
#   panel/full  — StrictHostKeyChecking=no, BatchMode=no  (RUN + PUT)
#   telemt      — StrictHostKeyChecking=accept-new        (RUN + PUT, те же RUN/PUT)
#   hysteria    — StrictHostKeyChecking=no, порт явно     (RUN + PUT)
# После вызова доступны: RUN "cmd", PUT src dst
init_ssh_helpers() {
    local mode="${1:-panel}"
    local strict_opt
    case "$mode" in
        telemt) strict_opt="StrictHostKeyChecking=accept-new" ;;
        *)      strict_opt="StrictHostKeyChecking=no" ;;
    esac
    _SSH_OPTS="-p $_SSH_PORT -o $strict_opt -o ConnectTimeout=10"
    [ "$mode" != "telemt" ] && _SSH_OPTS="$_SSH_OPTS -o BatchMode=no"

    # SSH-03 fix (docs/LEGACY_AUDIT.md §8): ssh's `-p PORT` and scp's
    # `-p` are different flags — scp's `-p` is a no-argument
    # preserve-attributes switch, not a port selector (that's scp's
    # `-P PORT`). PUT() previously reused $_SSH_OPTS verbatim, so
    # `$_SSH_PORT` landed as a bare positional argument to scp (a stray
    # source-file operand) instead of being consumed as a port number.
    # _SCP_OPTS mirrors _SSH_OPTS's StrictHostKeyChecking/ConnectTimeout/
    # BatchMode construction but with `-P` in place of `-p`. The
    # previously-hardcoded `-p` in `scp -rp` (preserve attributes) is
    # dropped, not reassigned: no calling code relies on it — the call
    # sites that copy executable scripts (mgmt_script.sh's
    # remnawave_panel/server-manager copy) already `RUN "chmod +x ..."`
    # immediately after PUT rather than depending on preserved mode
    # bits, and no contract, architecture doc, or call site references
    # preserved timestamps. If preservation is wanted later, add a bare
    # `-p` back into _SCP_OPTS alongside `-P $_SSH_PORT` — that
    # decision is not made here.
    _SCP_OPTS="-P $_SSH_PORT -o $strict_opt -o ConnectTimeout=10"
    [ "$mode" != "telemt" ] && _SCP_OPTS="$_SCP_OPTS -o BatchMode=no"

    # SSH-02 fix (docs/LEGACY_AUDIT.md §8) / contract 7 (docs/CONTRACTS.md):
    # secrets must never appear in argv. `sshpass -p "$_SSH_PASS"` put the
    # SSH migration password directly on the command line, visible via
    # `ps`/`/proc/<pid>/cmdline` for the process lifetime. `sshpass -f
    # <(...)` reads the password from a process-substitution file
    # descriptor instead — verified via live `/proc/<pid>/cmdline`
    # inspection during testing that the password is absent from the
    # running sshpass process's argv (shows `-f /dev/fd/N`, not the
    # password). This is the exact mechanism contract 7's own
    # Implementation note already names as one of the pre-approved
    # options ("sshpass -f <(...), SSHPASS env var, or another
    # approach") — no new decision made here, just picking the first of
    # the two already-named options.
    # shellcheck disable=SC2139
    RUN() { sshpass -f <(printf '%s\n' "$_SSH_PASS") ssh  $_SSH_OPTS "${_SSH_USER}@${_SSH_IP}" "$@"; }
    PUT() { sshpass -f <(printf '%s\n' "$_SSH_PASS") scp -r $_SCP_OPTS "$@"; }
    export -f RUN PUT 2>/dev/null || true
}

# ── SSH-миграция: проверка подключения ────────────────────────────
check_ssh_connection() {
    RUN "echo ok" >/dev/null 2>&1         || { warn "Не удалось подключиться к ${_SSH_IP}:${_SSH_PORT}"; return 1; }
    ok "SSH соединение установлено"
}

# ── Remote: установка зависимостей ───────────────────────────────
# remote_install_deps [panel|full] [nginx|caddy]
#   panel — base (без qrencode/unzip/cron, без /etc/hysteria)
#   full  — base + unzip cron qrencode + /etc/hysteria
#   nginx — ставит certbot-пакеты для nginx SSL
#   caddy — пропускает certbot, сертификатами управляет Caddy
remote_install_deps() {
    local variant="${1:-panel}" web_server="${2:-nginx}"
    local extra_pkgs="" extra_dirs="" ssl_pkgs="" base_dir="/opt/remnawave" extra_ufw=""
    [ "$web_server" != "caddy" ] && ssl_pkgs=" certbot python3-certbot-dns-cloudflare"
    if [ "$variant" = "full" ]; then
        extra_pkgs=" unzip cron qrencode"
        extra_dirs=" /etc/hysteria"
    fi
    if [ "$variant" = "node" ]; then
        base_dir="/opt/remnanode"
        extra_ufw="ufw allow 80/tcp >/dev/null 2>&1; "
    fi

    # ── Показываем что будет выполнено и просим подтверждение ─────
    echo ""
    warn "На сервере ${_SSH_IP} будут выполнены следующие действия:"
    echo ""
    echo "  · apt-get update && apt-get install (curl, docker-deps${ssl_pkgs:+, certbot}...)"
    echo "  · Установка Docker (если не установлен)"
    echo "  · Создание swap-файла 2 GB (если нет)"
    echo "  · Включение BBR (sysctl)"
    if [ "$variant" = "node" ]; then
        echo "  · Открытие портов 22/tcp, 80/tcp и 443/tcp в UFW"
    else
        echo "  · Открытие портов 22/tcp и 443/tcp в UFW"
    fi
    [ "$variant" = "full" ] && echo "  · Установка qrencode, unzip, cron"
    echo ""
    if ! confirm "Продолжить установку зависимостей на ${_SSH_IP}?" y; then
        warn "Отменено пользователем"
        return 1
    fi

    info "Устанавливаем зависимости на новом сервере..."
    if ! RUN bash -s << RDEPS
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q 2>/dev/null
apt-get install -y -q curl wget git jq openssl ca-certificates gnupg dnsutils \
    sshpass${ssl_pkgs}${extra_pkgs} 2>/dev/null${extra_pkgs} 2>/dev/null
command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; systemctl enable docker >/dev/null 2>&1; } # intentional: official Docker installer
[ ! -f /swapfile ] && { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }
grep -q "bbr" /etc/sysctl.conf 2>/dev/null || {
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}
ufw allow 22/tcp >/dev/null 2>&1; ${extra_ufw}ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
mkdir -p ${base_dir} /var/www/html /etc/letsencrypt /etc/ssl/certs/hysteria${extra_dirs}
RDEPS
    then
        warn "Установка зависимостей на ${_SSH_IP} завершилась с ошибкой"
        return 1
    fi
    ok "Зависимости установлены"
}
