# shellcheck shell=bash

panel_generate_nginx_config() {
    local MODE="$1"
    local PANEL_DOMAIN="$2"
    local SUB_DOMAIN="$3"
    local SELFSTEAL_DOMAIN="$4"
    local PC="$5"
    local SC="$6"
    local STC="$7"
    local COOKIE_KEY="$8"
    local COOKIE_VAL="$9"

        # ── nginx.conf ────────────────────────────────────────────
        local LISTEN_DIR REAL_IP_P REAL_IP_S
        if [ "$MODE" = "1" ]; then
            LISTEN_DIR="listen unix:/dev/shm/nginx.sock ssl proxy_protocol;"
            REAL_IP_P="\$proxy_protocol_addr"
            REAL_IP_S="\$proxy_protocol_addr"
        else
            LISTEN_DIR="listen 443 ssl;"
            REAL_IP_P="\$remote_addr"
            REAL_IP_S="\$remote_addr"
        fi

    cat > /opt/remnawave/nginx.conf << NGINX_CONF_EOF
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

server {
    server_name ${PANEL_DOMAIN};
    ${LISTEN_DIR}
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
        proxy_set_header X-Real-IP ${REAL_IP_P};
        proxy_set_header X-Forwarded-For ${REAL_IP_P};
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
        proxy_set_header X-Real-IP ${REAL_IP_P};
        proxy_set_header X-Forwarded-For ${REAL_IP_P};
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
    ${LISTEN_DIR}
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
        proxy_set_header X-Real-IP ${REAL_IP_S};
        proxy_set_header X-Forwarded-For ${REAL_IP_S};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s; proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @sub_error;
    }
    location @sub_error { return 444; }
}

server {
    server_name ${SELFSTEAL_DOMAIN};
    ${LISTEN_DIR}
    http2 on;
    ssl_certificate "/etc/letsencrypt/live/${STC}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${STC}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/${STC}/fullchain.pem";
    root /var/www/html; index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    ${LISTEN_DIR}
    server_name _;
    ssl_certificate "/etc/letsencrypt/live/${PC}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${PC}/privkey.pem";
    ssl_reject_handshake on;
    return 444;
}
NGINX_CONF_EOF
}

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
#     public 0.0.0.0:443 to loopback-only 127.0.0.1:$F_XRAY_PORT.
# Xray's own REALITY fallback (dest = /dev/shm/nginx.sock, the decoy
# selfsteal site) is NOT touched by any of this — that mechanism lives
# entirely inside Xray and fires only after Xray's own REALITY handshake
# inspection, which still runs identically once nginx's stream block
# hands it the raw bytes.
F_NGINX_HTTPS_PORT=7443
F_XRAY_PORT=8443

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
        ${SUB_DOMAIN}   panel_and_sub;
        default         xray_reality;
    }
    upstream panel_and_sub { server 127.0.0.1:${F_NGINX_HTTPS_PORT}; }
    upstream xray_reality  { server 127.0.0.1:${F_XRAY_PORT}; }

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
        proxy_protocol on;
    }
}
NGINX_CONF_EOF
}

# panel_generate_webserver_config — dispatcher, выбирает nginx/caddy backend
# по значению WEB_SERVER. Orchestration-level функция; отдельный третий
# файл для одного диспетчера не создаём (см. решение Stage 6h).
panel_generate_webserver_config() {
    local WEB_SERVER="$1"
    local MODE="$2"
    local PANEL_DOMAIN="$3"
    local SUB_DOMAIN="$4"
    local SELFSTEAL_DOMAIN="$5"
    local PC="$6"
    local SC="$7"
    local STC="$8"
    local COOKIE_KEY="$9"
    local COOKIE_VAL="${10}"

    if [ "$WEB_SERVER" = "1" ]; then
        # MODE=F routes to the standalone Variant F generator instead of
        # panel_generate_nginx_config()'s MODE=1/2 heredoc — dispatcher-
        # level only, panel_generate_nginx_config()'s body is untouched
        # (guarantees MODE=1/2 stay byte-identical). WEB_SERVER=2+MODE=F
        # is already rejected upstream (lib/panel/install.sh:208, before
        # this function is ever called), so no guard is needed here.
        if [ "$MODE" = "F" ]; then
            panel_generate_nginx_config_f \
                "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" \
                "$PC" "$SC" "$STC" "$COOKIE_KEY" "$COOKIE_VAL"
        else
            panel_generate_nginx_config \
                "$MODE" "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" \
                "$PC" "$SC" "$STC" "$COOKIE_KEY" "$COOKIE_VAL"
        fi
    else
        panel_generate_caddy_config \
            "$MODE" "$COOKIE_KEY" "$COOKIE_VAL"
    fi
}
