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

# panel_cli_collect_j_options — NEW, MODE=J only. Collects the optional
# TeleMT SNI branch that lib/panel/nginx/variant_j.sh already accepts as
# its 9th/10th positional args (TELEMT_DOMAIN/TELEMT_PORT — see that
# file's header) but that nothing upstream has ever collected or passed
# through until now. For MODE != J this function must not run at all
# (TeleMT is J-specific — see docs/ARCHITECTURE.md's Variant J section);
# panel_install() only calls it inside its own `if [ "$MODE" = "J" ]`
# branch, and this function defensively no-ops otherwise as a second
# guard against being called for the wrong MODE by mistake.
#
# TELEMT_PORT here is TeleMT's own co-located loopback listener port
# (nginx forwards decrypted SNI-matched traffic to
# 127.0.0.1:$TELEMT_PORT — variant_j.sh's $TELEMT_UPSTREAM), NOT a public
# port. It intentionally has no invented default: the co-located TeleMT
# container wiring itself (network_mode, actual listener bind) is a
# separate, not-yet-implemented stage (see docs/MULTI_PROTOCOL_L4_INGRESS.md
# and the project's own TeleMT co-location notes) — inventing a default
# here would silently paper over a port choice nobody has made yet, so
# the operator must supply one explicitly. The check below only rejects
# values that are provably wrong (colliding with J's own fixed ports,
# hardcoded identically to lib/panel/nginx/variant_j.sh's
# J_XRAY_VISION_PORT/J_XRAY_XHTTP_PORT/J_NGINX_HTTPS_PORT/
# J_XHTTP_PUBLIC_PORT, plus 443 itself) — it does not and cannot validate
# that the port is otherwise correct for whatever TeleMT deployment the
# operator has in mind.
panel_cli_collect_j_options() {
    TELEMT_ENABLED="false"
    TELEMT_DOMAIN=""
    TELEMT_PORT=""

    [ "$MODE" != "J" ] && return 0

    echo ""
    section "TeleMT (опционально, только Variant J)"
    if confirm "Включить TeleMT (MTProto через отдельный SNI на :443)?" "n"; then
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
            # Зарезервированные порты Variant J — см.
            # lib/panel/nginx/variant_j.sh (J_XRAY_VISION_PORT=18443,
            # J_XRAY_XHTTP_PORT=18444, J_NGINX_HTTPS_PORT=7444,
            # J_XHTTP_PUBLIC_PORT=8443), плюс публичный :443.
            case "$TELEMT_PORT" in
                18443|18444|7444|8443|443)
                    warn "Порт $TELEMT_PORT уже зарезервирован Variant J — выберите другой"
                    continue ;;
            esac
            break
        done
    fi
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
    if [ "$MODE" = "J" ]; then
        if [ "$TELEMT_ENABLED" = "true" ]; then
            echo "  TeleMT:        включен ($TELEMT_DOMAIN, loopback :$TELEMT_PORT)"
        else
            echo "  TeleMT:        выключен"
        fi
    fi
    echo ""
}
