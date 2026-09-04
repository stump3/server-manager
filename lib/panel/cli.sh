# shellcheck shell=bash
# lib/panel/cli.sh — interactive parameter collection for panel_install()
# (lib/panel/install.sh). Extracted 2026-08-31 from panel_install()'s own
# body, which used to prompt for everything inline.
#
# Scoping convention (matches the rest of this codebase — see
# lib/panel/cert.sh's panel_install_ssl() setting PC/SC/STC, and
# lib/panel/install.sh's own panel_generate_env() setting
# SUPERADMIN_USER/COOKIE_KEY/etc.): every function below assigns its
# output variables WITHOUT `local`, relying on panel_install() having
# already declared them `local` before calling in. This is bash dynamic
# scoping, not globals — nothing here is `export`ed, and callers other
# than panel_install() are expected to declare the same `local`s first.
# No `eval`, no `printf -v` needed beyond what ask() already does.

# panel_cli_select_mode — MODE prompt. Extended 2026-08-31 to accept "J"
# alongside the original "1"/"2"/"F" (previously ^([12]|[Ff])$, MODE=J was
# not selectable at all — panel_generate_webserver_config() and
# panel_generate_compose() already handled MODE=J correctly before this
# changed, but nothing upstream of them could ever produce it).
panel_cli_select_mode() {
    section "Режим"
    echo "  1) Панель + Нода (Reality selfsteal, всё на одном сервере)"
    echo "  2) Только панель (нода на отдельном сервере)"
    echo "  F) Панель + Нода, :443 у nginx (TCP passthrough к Xray/REALITY)"
    echo "  J) Панель + Нода, :443 у nginx (Vision) + :8443 (XHTTP/REALITY)"
    echo ""
    MODE=""
    while [[ ! "$MODE" =~ ^([12]|[FfJj])$ ]]; do
        read -p "  Выбор (1/2/F/J): " MODE < /dev/tty
    done
    [[ "$MODE" =~ ^[Ff]$ ]] && MODE="F"
    [[ "$MODE" =~ ^[Jj]$ ]] && MODE="J"
}

# panel_cli_collect_domains — unchanged from the original inline prompt
# (PANEL_DOMAIN/SUB_DOMAIN/SELFSTEAL_DOMAIN + uniqueness check). MODE=J
# uses the same three domains as MODE=1/F/2; it needs no domain of its
# own beyond what variant_j.sh already derives from SELFSTEAL_DOMAIN.
panel_cli_collect_domains() {
    section "Домены"
    while true; do ask PANEL_DOMAIN "Домен панели (panel.example.com)"; validate_domain "$PANEL_DOMAIN" && break || warn "Неверный формат"; done
    while true; do ask SUB_DOMAIN   "Домен подписок (sub.example.com)";  validate_domain "$SUB_DOMAIN"   && break || warn "Неверный формат"; done
    while true; do ask SELFSTEAL_DOMAIN "Домен selfsteal (node.example.com)"; validate_domain "$SELFSTEAL_DOMAIN" && break || warn "Неверный формат"; done

    if [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || \
       [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ] || \
       [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
        err "Все три домена должны быть уникальными"
    fi
}

# panel_cli_select_webserver — WEB_SERVER prompt, plus the MODE=F guard
# that already existed (Caddy has no caddy-l4 in the official image) and
# an equivalent new MODE=J guard: J needs nginx stream{} SNI routing for
# BOTH its Vision and XHTTP legs (lib/panel/nginx/variant_j.sh), which
# Caddy cannot provide any more than it could for F — same underlying
# reason, so the same fatal-error treatment, not a silent fallback (this
# mirrors panel_generate_compose_colocated()'s own WEB_SERVER=2+MODE=J
# guard added in the compose stage; that guard is Compose's last line of
# defense, this one is the CLI's first — neither replaces the other).
panel_cli_select_webserver() {
    section "Веб-сервер"
    echo "  1) Nginx   (SSL через certbot — Cloudflare / Let's Encrypt / Gcore)"
    echo "  2) Caddy   (SSL автоматически — встроенный ACME, certbot не нужен)"
    echo ""
    WEB_SERVER=""
    while [[ ! "$WEB_SERVER" =~ ^[12]$ ]]; do
        read -p "  Выбор (1/2): " WEB_SERVER < /dev/tty
    done

    # Режим F (TCP passthrough к Xray через nginx stream) реализован пока
    # только для nginx. Для Caddy эквивалентный механизм — сторонний
    # плагин caddy-l4 (mholt/caddy-l4), который требует собственной сборки
    # бинарника (xcaddy build --with github.com/mholt/caddy-l4) — НЕ входит
    # в официальный образ caddy:2.11, уже используемый ниже для MODE=1/2.
    # Это не архитектурное решение "Caddy не поддерживается вообще" — это
    # явное ограничение объёма текущего изменения; см. docs/ARCHITECTURE.md
    # §4b (Variant F).
    if [ "$MODE" = "F" ] && [ "$WEB_SERVER" = "2" ]; then
        err "Режим F сейчас поддерживается только с Nginx (WEB_SERVER=1). Caddy для F требует отдельной сборки (caddy-l4, не входит в official caddy:2.11 image) — не реализовано в этом проходе."
    fi
    if [ "$MODE" = "J" ] && [ "$WEB_SERVER" = "2" ]; then
        err "Режим J сейчас поддерживается только с Nginx (WEB_SERVER=1). Caddy не поддерживает nginx stream{}-маршрутизацию, необходимую для Variant J (Vision + XHTTP)."
    fi
}

# panel_cli_select_cert — unchanged from the original inline prompt.
panel_cli_select_cert() {
    CERT_METHOD="" PANEL_CF_EMAIL="" PANEL_CF_KEY="" PANEL_LE_EMAIL="" GCORE_TOKEN=""
    if [ "$WEB_SERVER" = "1" ]; then
        echo ""
        section "SSL сертификаты"
        echo "  1) Cloudflare DNS-01 (wildcard, рекомендуется)"
        echo "  2) ACME HTTP-01 (Let's Encrypt)"
        echo "  3) Gcore DNS-01 (wildcard)"
        while [[ ! "$CERT_METHOD" =~ ^[123]$ ]]; do
            read -p "  Метод (1/2/3): " CERT_METHOD < /dev/tty
        done
        case $CERT_METHOD in
            1) ask PANEL_CF_KEY   "  Cloudflare API Token"
               ask PANEL_CF_EMAIL "  Email Cloudflare" ;;
            2) ask PANEL_LE_EMAIL "  Email для Let's Encrypt" ;;
            3) ask GCORE_TOKEN    "  Gcore API Token"
               ask PANEL_LE_EMAIL "  Email для Let's Encrypt" ;;
        esac
    else
        info "Caddy: SSL будет получен автоматически через ACME при первом запуске"
        [ "$MODE" = "2" ] && info "Для ACME нужны порты 80 и 443 — откроются автоматически"
    fi
}

# panel_cli_collect_j_options — MODE=F and MODE=J. Collects the optional
# TeleMT SNI branch that lib/panel/nginx/variant_f.sh AND
# lib/panel/nginx/variant_j.sh both already accept as their 9th/10th
# positional args (TELEMT_DOMAIN/TELEMT_PORT — see those files' headers,
# Phase C). Historically J-only (name kept for compatibility with the
# existing test driver — lib/sripts/tests/cli_test_driver.sh — and with
# panel_install()'s own call site); it is no longer J-specific.
#
# Extended (2026-09-05) to actually drive the TeleMT installer
# (lib/telemt/install.sh:telemt_install_noninteractive) instead of only
# collecting values that fed nginx.conf — see that function's own header
# for why it's a separate, additive function rather than a reuse of
# telemt_menu_install(). This function's job is narrower: figure out
# WHETHER and WITH WHAT PARAMETERS the installer should run, and detect
# pre-existing TeleMT state so a standalone install is never silently
# touched and a reinstall never silently mutates an existing integrated
# one — the actual installer call happens later, from panel_install()
# itself, gated on TELEMT_INSTALL_ACTION set here.
#
# TELEMT_INSTALL_ACTION values set by this function:
#   ""            — nothing to do (TeleMT disabled, or standalone found)
#   "new"         — no existing TeleMT at all; install fresh (mode=docker)
#   "reconfigure" — existing INTEGRATED TeleMT; operator explicitly chose
#                   a new domain/port; other settings (users/upstream/ME)
#                   are carried over unchanged from the existing config
#   "keep"        — existing INTEGRATED TeleMT; operator chose to leave
#                   it untouched — nginx wiring reuses its current
#                   domain/port, telemt_install_noninteractive is NOT
#                   called at all
#
# TELEMT_PORT here is TeleMT's own co-located loopback listener port
# (nginx forwards decrypted SNI-matched traffic to
# 127.0.0.1:$TELEMT_PORT), NOT a public port.
panel_cli_collect_j_options() {
    TELEMT_ENABLED="false"
    TELEMT_DOMAIN=""
    TELEMT_PORT=""
    TELEMT_INSTALL_ACTION=""
    TELEMT_INSTALL_MODE=""

    [ "$MODE" != "F" ] && [ "$MODE" != "J" ] && return 0

    # Зарезервированные порты — свои для F и для J (см.
    # lib/panel/nginx/variant_f.sh: F_NGINX_HTTPS_PORT=7443,
    # F_XRAY_VISION_PORT=8443; lib/panel/nginx/variant_j.sh:
    # J_XRAY_VISION_PORT=18443, J_XRAY_XHTTP_PORT=18444,
    # J_NGINX_HTTPS_PORT=7444, J_XHTTP_PUBLIC_PORT=8443), плюс
    # публичный :443 в обоих случаях.
    local -a _reserved_ports=(443)
    if [ "$MODE" = "J" ]; then
        _reserved_ports+=(18443 18444 7444 8443)
    else
        _reserved_ports+=(7443 8443)
    fi

    echo ""
    section "TeleMT (опционально, Variant $MODE)"

    local _telemt_state; _telemt_state=$(telemt_detect_state)
    local _telemt_mode; _telemt_mode=$(telemt_detect_installed_mode)

    if [ "$_telemt_state" = "standalone" ]; then
        warn "Обнаружена существующая standalone-установка TeleMT (${_telemt_mode}, конфиг: $(telemt_detect_config_path))."
        warn "Panel не меняет её bind/domain/port/пользователей автоматически."
        info "Чтобы интегрировать TeleMT в Nginx, сначала переустановите её через меню TeleMT (TeleMT → Удалить/Переустановить), затем запустите установку Panel заново."
        return 0
    fi

    if [ "$_telemt_state" = "integrated" ]; then
        local _cfg; _cfg=$(telemt_detect_config_path)
        local _cur_domain _cur_port
        _cur_domain=$(telemt_get_tls_domain "$_cfg")
        _cur_port=$(telemt_detect_port)
        info "Обнаружена существующая integrated-установка TeleMT (${_telemt_mode}): домен=${_cur_domain}, loopback-порт=${_cur_port}"
        if confirm "Оставить текущую интеграцию TeleMT без изменений?" "y"; then
            TELEMT_ENABLED="true"
            TELEMT_DOMAIN="$_cur_domain"
            TELEMT_PORT="$_cur_port"
            TELEMT_INSTALL_ACTION="keep"
            return 0
        fi
        if confirm "Полностью отключить интеграцию TeleMT в Nginx (сам процесс TeleMT останется запущен как есть)?" "n"; then
            TELEMT_ENABLED="false"
            TELEMT_INSTALL_ACTION=""
            return 0
        fi
        info "Изменятся только домен/порт — пользователи и upstream-настройки TeleMT будут сохранены."
        TELEMT_INSTALL_ACTION="reconfigure"
        TELEMT_INSTALL_MODE="$_telemt_mode"
    elif confirm "Интегрировать TeleMT в Nginx (MTProto через отдельный SNI на :443)?" "n"; then
        TELEMT_INSTALL_ACTION="new"
        TELEMT_INSTALL_MODE="docker"
    else
        return 0
    fi

    TELEMT_ENABLED="true"
    while true; do
        ask TELEMT_DOMAIN "Домен/SNI для TeleMT (mtproto.example.com)"
        validate_domain "$TELEMT_DOMAIN" || { warn "Неверный формат"; continue; }
        if [ "$TELEMT_DOMAIN" = "$PANEL_DOMAIN" ] || [ "$TELEMT_DOMAIN" = "$SUB_DOMAIN" ] || [ "$TELEMT_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
            warn "Домен TeleMT должен отличаться от доменов панели/подписок/selfsteal"
            continue
        fi
        break
    done
    while true; do
        read -p "  Loopback-порт TeleMT (куда nginx направляет TeleMT-трафик): " TELEMT_PORT < /dev/tty
        if [[ ! "$TELEMT_PORT" =~ ^[0-9]+$ ]] || [ "$TELEMT_PORT" -lt 1 ] || [ "$TELEMT_PORT" -gt 65535 ]; then
            warn "Порт должен быть числом 1-65535"
            continue
        fi
        local _collision=""
        for _p in "${_reserved_ports[@]}"; do
            [ "$TELEMT_PORT" = "$_p" ] && _collision="1"
        done
        if [ -n "$_collision" ]; then
            warn "Порт $TELEMT_PORT уже зарезервирован Variant $MODE — выберите другой"
            continue
        fi
        break
    done
}

# panel_cli_show_summary — pre-flight recap of everything collected
# above, shown once before panel_install_prerequisites() starts making
# real changes to the host (swap, sysctl, apt, docker, ufw). Purely
# informational — does not block or re-prompt; panel_pause_before_launch()
# (lib/panel/install.sh) already provides the "review generated files
# before launch" checkpoint later in the flow, this is not a duplicate of
# that, just an earlier "did I type all of this right" recap.
panel_cli_show_summary() {
    local MODE="$1" WEB_SERVER="$2" PANEL_DOMAIN="$3" SUB_DOMAIN="$4" SELFSTEAL_DOMAIN="$5"
    local CERT_METHOD="$6" TELEMT_ENABLED="$7" TELEMT_DOMAIN="$8" TELEMT_PORT="$9"

    local mode_label="1 (Панель+Нода)"
    [ "$MODE" = "2" ] && mode_label="2 (Только панель)"
    [ "$MODE" = "F" ] && mode_label="F (Панель+Нода, nginx TCP passthrough)"
    [ "$MODE" = "J" ] && mode_label="J (Панель+Нода, Vision + XHTTP)"
    local ws_label="Nginx"
    [ "$WEB_SERVER" = "2" ] && ws_label="Caddy"

    echo ""
    section "Проверьте параметры"
    echo "  Режим:         $mode_label"
    echo "  Веб-сервер:    $ws_label"
    echo "  Панель:        $PANEL_DOMAIN"
    echo "  Подписки:      $SUB_DOMAIN"
    echo "  Selfsteal:     $SELFSTEAL_DOMAIN"
    [ "$WEB_SERVER" = "1" ] && echo "  SSL метод:     $CERT_METHOD"
    if [ "$MODE" = "F" ] || [ "$MODE" = "J" ]; then
        if [ "$TELEMT_ENABLED" = "true" ]; then
            echo "  TeleMT:        включен ($TELEMT_DOMAIN, loopback :$TELEMT_PORT)"
        else
            echo "  TeleMT:        выключен"
        fi
    fi
    echo ""
}
