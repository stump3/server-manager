# shellcheck shell=bash

panel_generate_caddy_config() {
    local MODE="$1"
    local COOKIE_KEY="$2"
    local COOKIE_VAL="$3"

        # ── Caddyfile ─────────────────────────────────────────────
        if [ "$MODE" = "1" ]; then
            # MODE=1: Caddy слушает unix-сокет (Xray→Caddy, selfsteal)
            cat > /opt/remnawave/Caddyfile << CADDYEOF
{
    admin off
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
    auto_https disable_redirects
}

http://{\$PANEL_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$PANEL_DOMAIN}{uri} permanent
}

https://{\$PANEL_DOMAIN} {
    bind unix//dev/shm/nginx.sock

    @has_token_param {
        query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @has_token_param {
        header +Set-Cookie "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000"
    }

    @unauthorized {
        not path /oauth2/*
        not header Cookie *${COOKIE_KEY}=${COOKIE_VAL}*
        not query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @unauthorized {
        root * /var/www/html
        try_files {path} /index.html
        file_server
    }

    @oauth2_bad {
        path /oauth2/*
        not header Referer https://oauth.telegram.org/*
    }
    handle @oauth2_bad {
        abort
    }

    @oauth2 {
        path /oauth2/*
        header Referer https://oauth.telegram.org/*
    }
    handle @oauth2 {
        reverse_proxy {\$BACKEND_URL} {
            header_up Host {host}
        }
    }

    reverse_proxy {\$BACKEND_URL} {
        header_up X-Real-IP {http.request.header.X-Forwarded-For}
        header_up Host {host}
    }
}

http://{\$SUB_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$SUB_DOMAIN}{uri} permanent
}

https://{\$SUB_DOMAIN} {
    bind unix//dev/shm/nginx.sock
    reverse_proxy {\$SUB_BACKEND_URL} {
        header_up X-Real-IP {http.request.header.X-Forwarded-For}
        header_up Host {host}
    }
}

http://{\$SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{\$SELF_STEAL_DOMAIN} {
    bind unix//dev/shm/nginx.sock
    root * /var/www/html
    try_files {path} /index.html
    file_server
}
CADDYEOF
        else
            # MODE=2: Caddy слушает напрямую, ACME автоматически
            cat > /opt/remnawave/Caddyfile << CADDYEOF
{
    admin off
}

http://{\$PANEL_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$PANEL_DOMAIN}{uri} permanent
}

https://{\$PANEL_DOMAIN} {
    @has_token_param {
        query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @has_token_param {
        header +Set-Cookie "${COOKIE_KEY}=${COOKIE_VAL}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000"
    }

    @unauthorized {
        not path /oauth2/*
        not header Cookie *${COOKIE_KEY}=${COOKIE_VAL}*
        not query ${COOKIE_KEY}=${COOKIE_VAL}
    }
    handle @unauthorized {
        abort
    }

    @oauth2_bad {
        path /oauth2/*
        not header Referer https://oauth.telegram.org/*
    }
    handle @oauth2_bad {
        abort
    }

    @oauth2 {
        path /oauth2/*
        header Referer https://oauth.telegram.org/*
    }
    handle @oauth2 {
        reverse_proxy {\$BACKEND_URL} {
            header_up Host {host}
        }
    }

    reverse_proxy {\$BACKEND_URL} {
        header_up X-Real-IP {remote_host}
        header_up Host {host}
    }
}

http://{\$SUB_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$SUB_DOMAIN}{uri} permanent
}

https://{\$SUB_DOMAIN} {
    reverse_proxy {\$SUB_BACKEND_URL} {
        header_up X-Real-IP {remote_host}
        header_up Host {host}
    }
}

https://{\$SELF_STEAL_DOMAIN} {
    root * /var/www/html
    try_files {path} /index.html
    file_server
    header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"
}

:80 {
    bind 0.0.0.0
    respond 204
}
CADDYEOF
        fi
}
