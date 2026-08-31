# shellcheck shell=bash
#
# lib/panel/nginx/variant_f.sh — Variant F (и его расширение, Variant J)
# nginx-топология. Вынесено из lib/panel/nginx/config.sh, чтобы дальнейшее
# добавление ingress-вариантов расширяло этот файл (или создавало
# variant_<x>.sh рядом), а не разрастало центральный config.sh —
# см. docs/research/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md, раздел
# "NGINX REFACTOR ASSESSMENT". Механический перенос: тело
# panel_generate_nginx_config_f() не менялось при переносе, кроме правок,
# описанных ниже для Variant J. panel_generate_nginx_config() (MODE=1/2)
# остаётся в lib/panel/nginx/config.sh — не тронуто.

# Variant F (docs/ARCHITECTURE.md §4b): nginx stream module owns public
# :443 and routes by SNI (ssl_preread — reads ClientHello without
# terminating TLS, so REALITY still receives the genuine handshake) to
# one of two backends:
#   - PANEL_DOMAIN / SUB_DOMAIN → internal nginx HTTPS listener
#     (127.0.0.1:$F_NGINX_HTTPS_PORT), which terminates TLS normally —
#     Panel/sub don't care about REALITY, ordinary HTTP reverse-proxy
#     semantics apply exactly as MODE=2's http{} blocks already do.
#   - Everything else (SELFSTEAL_DOMAIN + no SNI match, matching what
#     REALITY itself already treats as "not my client" traffic) → raw
#     TCP passthrough, untouched, to Xray's REALITY inbound, moved from
#     public 0.0.0.0:443 to loopback-only 127.0.0.1:$F_XRAY_VISION_PORT.
# Xray's own REALITY fallback (dest = /dev/shm/nginx.sock, the decoy
# selfsteal site) is NOT touched by any of this — that mechanism lives
# entirely inside Xray and fires only after Xray's own REALITY handshake
# inspection, which still runs identically once nginx's stream block
# hands it the raw bytes.
#
# Variant J (docs/MULTI_PROTOCOL_L4_INGRESS.md, Variant A + XHTTP
# extension): two additions on top of the above, both additive —
# existing PANEL/SUB/default branches and their ports are unchanged in
# meaning, only the Vision port's NUMBER changes (freed for :8443, see
# below):
#   - A second, independent public TCP listener on :8443. This is a
#     direct proxy_pass, NOT ssl_preread/SNI routing — there is only one
#     possible backend (Xray's XHTTP+REALITY inbound), so there is
#     nothing to route by SNI. Kept as its own stream{} server block
#     rather than folded into the :443 map, since the two have no
#     shared routing logic.
#   - An optional third SNI branch on the existing :443 map, for
#     co-located TeleMT (docs/MULTI_PROTOCOL_L4_INGRESS.md, Variant A).
#     Gated on TELEMT_DOMAIN being non-empty specifically so that not
#     passing it (every call site today) reproduces today's exact 2-way
#     map byte-for-byte — this function does not itself decide whether
#     co-located TeleMT is installed; that remains an open
#     installer/deployment-flow question (flagged separately, not
#     decided here — see the implementation report).
#
# Port renumbering (Variant J): F_XRAY_PORT=8443 (the single Vision
# loopback port) is renamed and renumbered to F_XRAY_VISION_PORT=18443,
# and a new F_XRAY_XHTTP_PORT=18444 is added for the new XHTTP inbound.
# This is not a cosmetic rename: 8443 is now needed as nginx's *public*
# listener for XHTTP, and a public 0.0.0.0:8443 nginx bind cannot
# coexist with a process already holding 127.0.0.1:8443 (confirmed by
# local reproduction during planning — Linux rejects a wildcard bind
# against an already-bound specific address on the same port,
# EADDRINUSE, no SO_REUSEADDR trick applies here since these are two
# unrelated processes). Xray must NOT listen on 8443 in any form after
# this change — the public :8443 belongs to nginx exclusively. Both
# 18443 and 18444 were checked against the full repository (grep, no
# prior use anywhere) before being chosen.
F_NGINX_HTTPS_PORT=7443
F_XRAY_VISION_PORT=18443
F_XRAY_XHTTP_PORT=18444

# panel_generate_nginx_config_f — Variant F/J. Writes a FULL top-level
# nginx.conf (mounted at /etc/nginx/nginx.conf, NOT conf.d/default.conf
# — the `stream {}` directive is only valid at the top level, never
# nested inside `http {}`; this is a hard nginx constraint, not a style
# choice). Includes the standard boilerplate the base nginx:1.28 image's
# own main config normally provides, since this file replaces it
# entirely rather than extending conf.d.
#
# TELEMT_DOMAIN (new, optional, 10th positional arg): SNI for co-located
# TeleMT on the existing :443 map. Pass "" (or omit — `${10:-}` below
# defaults it) to reproduce the exact pre-Variant-J 2-way map; every
# current call site does this today, so MODE=F's generated config is
# unchanged in the TeleMT respect until a caller actually supplies a
# domain. TELEMT_PORT (11th, optional) is the loopback port TeleMT
# listens on when co-located — meaningless/unused when TELEMT_DOMAIN is
# empty.
panel_generate_nginx_config_f() {
    local PANEL_DOMAIN="$1"
    local SUB_DOMAIN="$2"
    local SELFSTEAL_DOMAIN="$3"
    local PC="$4"
    local SC="$5"
    local STC="$6"
    local COOKIE_KEY="$7"
    local COOKIE_VAL="$8"
    local TELEMT_DOMAIN="${9:-}"
    local TELEMT_PORT="${10:-}"

    # Built once, outside the heredoc: the TeleMT map line + upstream
    # block are either both present or both absent, keeping the
    # generated config internally consistent (a map branch referencing
    # a nonexistent upstream would be an nginx config error, not a
    # silent no-op). Indentation matches the surrounding heredoc by
    # hand since this is spliced into a `map {}` block, not re-indented
    # by any tool.
    local TELEMT_MAP_LINE="" TELEMT_UPSTREAM=""
    if [ -n "$TELEMT_DOMAIN" ]; then
        TELEMT_MAP_LINE="        ${TELEMT_DOMAIN} telemt;"
        TELEMT_UPSTREAM="    upstream telemt { server 127.0.0.1:${TELEMT_PORT}; }"
    fi

    cat > /opt/remnawave/nginx.conf << NGINX_CONF_EOF
user nginx;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    server_names_hash_bucket_size 64;

    upstream remnawave { server 127.0.0.1:3000; }
    upstream remnawave-sub { server 127.0.0.1:3010; }

    map \$http_upgrade \$connection_upgrade {
        default upgrade; "" close;
    }

    # Cookie-защита панели: доступ только с ?${COOKIE_KEY}=${COOKIE_VAL}
    map \$http_cookie \$auth_cookie {
        default 0; "~*${COOKIE_KEY}=${COOKIE_VAL}" 1;
    }
    map \$arg_${COOKIE_KEY} \$auth_query {
        default 0; "${COOKIE_VAL}" 1;
    }
    map "\$auth_cookie\$auth_query" \$authorized {
        "~1" 1; default 0;
    }
    map \$arg_${COOKIE_KEY} \$set_cookie_header {
        "${COOKIE_VAL}" "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
        default "";
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    # Panel и Sub: reached ONLY via the stream{} proxy_pass below, never
    # bound to a public interface directly. proxy_protocol picks up the
    # real client IP forwarded by the stream leg (same mechanism MODE=1
    # already uses for its unix-socket listener, just over loopback TCP
    # instead of a socket path).
    server {
        server_name ${PANEL_DOMAIN};
        listen 127.0.0.1:${F_NGINX_HTTPS_PORT} ssl proxy_protocol;
        http2 on;
        ssl_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
        ssl_certificate_key "/etc/letsencrypt/live/${PC}/privkey.pem";
        ssl_trusted_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
        add_header Set-Cookie \$set_cookie_header;

        location ^~ /oauth2/ {
            if (\$http_referer !~ "^https://oauth\\.telegram\\.org/") {
                return 444;
            }
            proxy_http_version 1.1;
            proxy_pass http://remnawave;
            proxy_set_header Host \$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header X-Real-IP \$proxy_protocol_addr;
            proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Port \$server_port;
            proxy_send_timeout 60s; proxy_read_timeout 60s;
        }
        location / {
            error_page 418 = @unauthorized;
            recursive_error_pages on;
            if (\$authorized = 0) { return 418; }
            proxy_http_version 1.1;
            proxy_pass http://remnawave;
            proxy_set_header Host \$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header X-Real-IP \$proxy_protocol_addr;
            proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Port \$server_port;
            proxy_send_timeout 60s; proxy_read_timeout 60s;
        }
        location @unauthorized {
            root /var/www/html; index index.html; try_files /index.html =444;
        }
    }

    server {
        server_name ${SUB_DOMAIN};
        listen 127.0.0.1:${F_NGINX_HTTPS_PORT} ssl proxy_protocol;
        http2 on;
        ssl_certificate "/etc/letsencrypt/live/${SC}/fullchain.pem";
        ssl_certificate_key "/etc/letsencrypt/live/${SC}/privkey.pem";
        ssl_trusted_certificate "/etc/letsencrypt/live/${SC}/fullchain.pem";

        location / {
            proxy_http_version 1.1;
            proxy_pass http://remnawave-sub;
            proxy_set_header Host \$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header X-Real-IP \$proxy_protocol_addr;
            proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Port \$server_port;
            proxy_send_timeout 60s; proxy_read_timeout 60s;
            proxy_intercept_errors on;
            error_page 400 404 500 502 @sub_error;
        }
        location @sub_error { return 444; }
    }

    # Selfsteal decoy + catch-all: UNCHANGED from MODE=1. This is
    # Xray's own REALITY fallback destination (realitySettings.dest =
    # /dev/shm/nginx.sock) — reached only from inside Xray, after Xray's
    # own REALITY handshake inspection decides a connection isn't a
    # genuine proxy client. Nothing about Variant F/J touches this path.
    server {
        server_name ${SELFSTEAL_DOMAIN};
        listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
        http2 on;
        ssl_certificate "/etc/letsencrypt/live/${STC}/fullchain.pem";
        ssl_certificate_key "/etc/letsencrypt/live/${STC}/privkey.pem";
        ssl_trusted_certificate "/etc/letsencrypt/live/${STC}/fullchain.pem";
        root /var/www/html; index index.html;
        add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    }

    server {
        listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
        server_name _;
        ssl_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
        ssl_certificate_key "/etc/letsencrypt/live/${PC}/privkey.pem";
        ssl_reject_handshake on;
        return 444;
    }
}

# Public :443 lives here. ssl_preread reads the ClientHello's SNI
# WITHOUT terminating TLS — proxy_pass in a stream{} server forwards
# the raw TCP bytes untouched, so whichever backend receives the
# connection still sees the genuine original TLS handshake. This is
# what makes REALITY possible through this topology at all: if nginx
# terminated TLS here first, Xray would never see a real ClientHello
# and REALITY's handshake inspection would have nothing genuine to
# inspect. [VERIFIED against nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html
# and the official nginxinc/docker-nginx build (nginx:1.28 already
# includes --with-stream_ssl_preread_module — confirmed in its
# Dockerfile's ./configure args), so no custom nginx image is needed.]
stream {
    map \$ssl_preread_server_name \$f_backend {
        ${PANEL_DOMAIN} panel_and_sub;
        ${SUB_DOMAIN}   panel_and_sub;
${TELEMT_MAP_LINE}
        default         xray_reality;
    }
    upstream panel_and_sub { server 127.0.0.1:${F_NGINX_HTTPS_PORT}; }
    upstream xray_reality  { server 127.0.0.1:${F_XRAY_VISION_PORT}; }
${TELEMT_UPSTREAM}

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$f_backend;
        # proxy_protocol is enabled toward panel_and_sub (matches the
        # proxy_protocol listener above) so Panel/sub keep real client
        # IPs. It is intentionally NOT enabled toward xray_reality: this
        # repo's REALITY inbound JSON (lib/panel/api.sh) has not been
        # verified to accept PROXY protocol on a REALITY-security
        # inbound (rawSettings.acceptProxyProtocol is documented for
        # security:"tls" inbounds, not confirmed for security:"reality"
        # ones) — enabling it without that confirmation risks silently
        # breaking every REALITY handshake. Real client IPs at the Xray
        # leg will show as 127.0.0.1 until this is verified. Documented
        # as a known limitation, not silently assumed away.
        #
        # PRE-EXISTING ISSUE, NOT TOUCHED BY VARIANT J (see
        # docs/research/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md, section
        # C2): this directive is scoped to the whole server{} block, not
        # per-map-branch — nginx has no mechanism to apply
        # proxy_protocol to panel_and_sub only within a single shared
        # server{}. The comment above describes the *intended* behavior,
        # not the confirmed actual behavior; a local byte-level
        # reproduction during that research showed the PROXY preamble
        # does reach the xray_reality branch too. Left exactly as found
        # — fixing it is out of scope for Variant J per explicit
        # instruction, and doing so here would conflate an unrelated
        # pre-existing fix with this change's diff.
        proxy_protocol on;
    }

    # Variant J: public :8443, XHTTP+REALITY only. Not an SNI router —
    # there is exactly one backend, so ssl_preread/map would add
    # complexity with no routing decision to make. proxy_protocol is
    # deliberately NOT set here: Xray's XHTTP transport binds via the
    # same generic internet.ListenSystem()/sockopt.acceptProxyProtocol
    # mechanism as the raw TCP/Vision inbound (confirmed by reading
    # Xray-core 26.3.27 source: transport/internet/splithttp/hub.go's
    # ListenXH() calls internet.ListenSystem() exactly like
    # transport/internet/tcp/hub.go does for Vision) — since the new
    # XHTTP inbound's JSON does not set sockopt.acceptProxyProtocol
    # (matching Vision's inbound, deliberately not changed per this
    # round's constraints), sending a PROXY preamble here would corrupt
    # the byte stream Xray expects, the same way it does for
    # xray_reality above. Because this is a brand-new, standalone
    # server{} block (not sharing a block with anything else), leaving
    # proxy_protocol off is both correct and simple — unlike the :443
    # case, there's no other branch forcing a shared, ambiguous setting.
    server {
        listen 8443;
        proxy_pass 127.0.0.1:${F_XRAY_XHTTP_PORT};
    }
}
NGINX_CONF_EOF
}
