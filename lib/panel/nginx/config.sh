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

# panel_generate_nginx_config_f() moved to lib/panel/nginx/variant_f.sh, and
# panel_generate_nginx_config_j() lives in lib/panel/nginx/variant_j.sh —
# see those files for Variant F/J's respective topologies and constants.
# Moved out 2026-08-31 so this file stays a thin dispatcher and each
# variant's nginx generator lives in its own file (variant_f.sh /
# variant_j.sh), per the module split decided for Variant F/J. lib/panel.sh
# sources nginx/variant_f and nginx/variant_j alongside this file, so both
# panel_generate_nginx_config_f() and panel_generate_nginx_config_j() are
# defined before panel_generate_webserver_config() below ever calls them.

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
    local TELEMT_DOMAIN="${11:-}"
    local TELEMT_PORT="${12:-}"

    if [ "$WEB_SERVER" = "1" ]; then
        # MODE=F/MODE=J each route to their own standalone generator
        # instead of panel_generate_nginx_config()'s MODE=1/2 heredoc —
        # dispatcher-level only, panel_generate_nginx_config()'s body is
        # untouched (guarantees MODE=1/2 stay byte-identical). WEB_SERVER=2
        # + MODE=F/MODE=J is already rejected upstream
        # (lib/panel/cli.sh:panel_cli_select_webserver(), before this
        # function is ever called). MODE=J is now selectable via
        # lib/panel/cli.sh:panel_cli_select_mode(), and
        # TELEMT_DOMAIN/TELEMT_PORT are now collected by
        # lib/panel/cli.sh:panel_cli_collect_j_options() (11th/12th
        # positional args here, empty for every MODE except J) — both
        # pass straight through to panel_generate_nginx_config_j()'s own
        # optional 9th/10th args unchanged.
        if [ "$MODE" = "F" ]; then
            panel_generate_nginx_config_f \
                "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" \
                "$PC" "$SC" "$STC" "$COOKIE_KEY" "$COOKIE_VAL"
        elif [ "$MODE" = "J" ]; then
            panel_generate_nginx_config_j \
                "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" \
                "$PC" "$SC" "$STC" "$COOKIE_KEY" "$COOKIE_VAL" \
                "$TELEMT_DOMAIN" "$TELEMT_PORT"
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
