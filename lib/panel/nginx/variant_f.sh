# shellcheck shell=bash
#
# lib/panel/nginx/variant_f.sh — Variant F nginx-топология.
#
# RESTORED 2026-08-31: this file previously (commit 90411ca) contained a
# version of panel_generate_nginx_config_f() with Variant J's additions
# folded into it — see the provenance report for the exact list of what
# was removed. F and J must be independent, and none of that belongs in
# F. The function body below is restored byte-for-byte from
# origin/variant-f (lib/panel/nginx/config.sh, the pre-J baseline) —
# confirmed by diffing this file's generated nginx.conf output against
# that baseline for identical inputs (see report). Variant J's own,
# separate topology will get its own lib/panel/nginx/variant_j.sh in a
# later step — not folded back in here.
#
# KNOWN OPEN ITEM (tracked for the next step, not fixed here): this file
# is not yet added to lib/panel.sh's module-loading loop, so
# panel_generate_nginx_config_f() as defined here is currently NOT the
# active definition — lib/panel/nginx/config.sh still carries its own,
# unmodified copy of the same function name (also matching baseline
# byte-for-byte, since it was never touched by the J work), and that is
# the one actually sourced and called by
# panel_generate_webserver_config(). Deciding how config.sh and this
# file divide responsibility (which one keeps the function, when this
# file gets added to the loader) is explicitly deferred to the
# "carve out J" step, per instruction not to do further refactoring in
# this restoration step.
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
F_NGINX_HTTPS_PORT=7443
F_XRAY_VISION_PORT=8443

# panel_generate_nginx_config_f — Variant F. Writes a FULL top-level
# nginx.conf (mounted at /etc/nginx/nginx.conf, NOT conf.d/default.conf
# — the `stream {}` directive is only valid at the top level, never
# nested inside `http {}`; this is a hard nginx constraint, not a style
# choice). Includes the standard boilerplate the base nginx:1.28 image's
# own main config normally provides, since this file replaces it
# entirely rather than extending conf.d.
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

    # TeleMT support added 2026-08-31 (Phase C, XHTTP_ENABLE/
    # TELEMT_COLOCATE architecture): TELEMT_DOMAIN/TELEMT_PORT are
    # OPTIONAL, added at the end of the original 8-arg signature —
    # exactly the same contract lib/panel/nginx/variant_j.sh already
    # uses for its own 9th/10th args, deliberately not reinvented here.
    # When TELEMT_DOMAIN is empty (the default for every existing
    # caller — nginx/config.sh's dispatcher did not pass a 9th/10th arg
    # to this function before Phase C, and still only does so when it
    # has a real value to pass), TELEMT_MAP_LINE/TELEMT_UPSTREAM below
    # are both empty strings, so the header comment's "restored
    # byte-for-byte from origin/variant-f" claim continues to hold —
    # confirmed by SHA256 comparison against the pre-Phase-C baseline
    # for identical PANEL_DOMAIN/SUB_DOMAIN/SELFSTEAL_DOMAIN/PC/SC/STC/
    # COOKIE_KEY/COOKIE_VAL inputs (see regression report). This does
    # NOT touch the Panel/Sub map entries, the default Vision branch, the
    # Vision port, or proxy_protocol — TeleMT rides the SAME `:443`
    # stream{} server{} block those already use, inheriting its existing
    # blanket `proxy_protocol on;` exactly the way variant_j.sh's own
    # telemt branch does (see that file's comment on why proxy_protocol
    # cannot be scoped per-branch in nginx stream{} — same nginx
    # limitation applies here unchanged).
    local TELEMT_MAP_LINE=""
    local TELEMT_UPSTREAM=""
    if [ -n "$TELEMT_DOMAIN" ]; then
        # Appended to the END of the preceding heredoc line (not placed
        # on a standalone line of its own) specifically so the DISABLED
        # case leaves no trace at all — a bare `${TELEMT_MAP_LINE}` on
        # its own heredoc source line still emits an empty output line
        # even when the variable is empty (the newline is baked into the
        # heredoc's literal source text, not contributed by the
        # variable's content), which silently broke byte-identity
        # against the pre-Phase-C baseline until caught by the required
        # regression check. variant_j.sh has this same latent artifact
        # (extra blank lines when TeleMT is disabled there too) — it was
        # never surfaced there because nothing required J's disabled-
        # TeleMT output to be byte-identical to a pre-existing baseline;
        # F does have that requirement, so F needs the fix and J is left
        # as-is (out of scope for this phase).
        TELEMT_MAP_LINE=$'\n'"        ${TELEMT_DOMAIN}   telemt;"
        TELEMT_UPSTREAM=$'\n'"    upstream telemt { server 127.0.0.1:${TELEMT_PORT}; }"
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
    # genuine proxy client. Nothing about Variant F touches this path.
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
        ${SUB_DOMAIN}   panel_and_sub;${TELEMT_MAP_LINE}
        default         xray_reality;
    }
    upstream panel_and_sub { server 127.0.0.1:${F_NGINX_HTTPS_PORT}; }
    upstream xray_reality  { server 127.0.0.1:${F_XRAY_VISION_PORT}; }${TELEMT_UPSTREAM}

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$f_backend;
        # proxy_protocol is a stream/server-scoped directive, not a
        # per-upstream one — nginx does not support conditioning it on
        # \$f_backend, so it applies identically to both branches reached
        # through this single server{} block: panel_and_sub AND
        # xray_reality both receive a PROXY v1 preamble ahead of the raw
        # TLS bytes (confirmed by local byte-level reproduction, see
        # docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md Correction C2 — do not
        # re-introduce the earlier assumption that this was scoped to
        # panel_and_sub only). To make the xray_reality leg actually
        # consume that preamble instead of choking on it, the REALITY
        # inbound JSON generated for MODE=F sets
        # streamSettings.sockopt.acceptProxyProtocol=true
        # (lib/panel/api.sh: panel_reality_accept_proxy_protocol). That field wraps
        # Xray's raw TCP listener before TLS/REALITY dispatch and is not
        # security-layer-specific (confirmed against Xray-core v26.3.27
        # source: transport/internet/tcp/hub.go,
        # transport/internet/system_listener.go), so it works the same
        # for a REALITY inbound as for a plain TLS one. Real client IPs
        # now propagate correctly on both legs.
        proxy_protocol on;
    }
}
NGINX_CONF_EOF
}
