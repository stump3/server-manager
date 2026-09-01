# shellcheck shell=bash
#
# lib/panel/nginx/variant_j.sh — Variant J nginx-топология.
#
# CREATED 2026-08-31 as part of the F/J carve-out: Variant J is its own,
# independent variant — it does NOT extend or migrate from Variant F, and
# nothing here is shared with lib/panel/nginx/variant_f.sh. See that file's
# header for the history of why they used to be folded together (commit
# 90411ca) and why they were split apart.
#
# Variant J's shape (per the F/J split spec):
#   - VLESS+Vision(+REALITY) inbound, loopback-only, on $J_XRAY_VISION_PORT
#     (18443) — reached from the public internet only via nginx's stream{}
#     SNI router on :443, exactly the way Variant F routes to its own
#     REALITY inbound. Vision needs the raw, untouched ClientHello to reach
#     Xray (REALITY's handshake inspection runs inside Xray, not nginx), so
#     this leg is a plain TCP passthrough, never TLS-terminated by nginx.
#   - VLESS+XHTTP(+REALITY, "套娃"/nested) inbound, loopback-only, on
#     $J_XRAY_XHTTP_PORT (18444) — this is a SECOND, independent REALITY
#     inbound (see lib/panel/api.sh's StealXHTTP inbound definition:
#     streamSettings.security = "reality", its own xver/shortIds/privateKey),
#     not a fallback hanging off the Vision inbound. Because it is its own
#     REALITY inbound, it needs the same "don't touch the TLS bytes"
#     treatment as Vision — hence its own public entry point rather than
#     being folded into the :443 SNI map.
#   - Public :$J_XHTTP_PUBLIC_PORT (8443) is that entry point: a dedicated
#     stream{} listener, separate from :443, plain TCP passthrough straight
#     to the loopback XHTTP inbound. No SNI map is needed here (unlike the
#     :443 leg) since there is exactly one destination behind this port —
#     but proxy_protocol is still applied for the same real-client-IP reason
#     as everywhere else in this file (see the note on the shared C2 defect
#     inherited from Variant F, below).
#   - Panel/Sub reuse the same "internal nginx HTTPS backend behind the
#     stream router" shape Variant F already uses, just on J's own loopback
#     port ($J_NGINX_HTTPS_PORT, 7444 — deliberately NOT F's 7443, so the
#     two variants never collide if anything ever runs them side by side
#     for testing) to keep this file fully self-contained.
#   - TeleMT is OPTIONAL: an additive third branch in the :443 SNI map,
#     modeled directly on the "Variant A — TCP-only extension of MODE=F"
#     design already researched and recommended in
#     docs/MULTI_PROTOCOL_L4_INGRESS.md (§ Candidate Topologies). That
#     document's reasoning applies unchanged here: TeleMT loses its own
#     public bind and moves to loopback-only, reached via a new SNI branch
#     keyed on its masquerade domain, exactly like the existing Panel/Sub
#     and REALITY branches. It is passed in as two extra, optional
#     parameters (TELEMT_DOMAIN / TELEMT_PORT); when TELEMT_DOMAIN is empty
#     the branch is omitted entirely and the generated config is
#     byte-for-byte what you'd get without TeleMT at all.
#
# NOT YET WIRED (explicitly out of scope for this carve-out step, tracked
# for later): lib/panel/install.sh doesn't recognize MODE=J yet (its regex
# is `^([12]|[Ff])$`), and lib/panel/api.sh's XHTTP/StealXHTTP logic is
# currently gated on `MODE = "F"`, not `MODE = "J"` — i.e. today, choosing
# Variant F is what actually produces the Vision+XHTTP dual-inbound profile
# this file's topology expects. Reconciling that (moving the XHTTP/StealXHTTP
# logic in api.sh to key off MODE=J instead of MODE=F, and teaching
# install.sh about the "J" choice) is the api.sh/install.sh migration task
# named in the original plan (lib/panel/xray/templates, render.sh, cli.sh) —
# deliberately NOT done as part of this nginx-only carve-out, and NOT
# something this file attempts to route around. Until that migration lands,
# panel_generate_nginx_config_j() below is correct in isolation (verified by
# generating and inspecting its own output) but is not yet reachable through
# the installer, and its ports do not yet line up with what api.sh currently
# generates under MODE=F. TeleMT's own co-located wiring (lib/telemt/install.sh
# proxy_protocol=true, loopback bind, network_mode: host — all itemized in
# docs/MULTI_PROTOCOL_L4_INGRESS.md) is equally not done here; only the nginx
# routing shape is provided, ready for that wiring to plug into.
J_XRAY_VISION_PORT=18443
J_XRAY_XHTTP_PORT=18444
J_NGINX_HTTPS_PORT=7444
J_XHTTP_PUBLIC_PORT=8443

# panel_generate_nginx_config_j — Variant J. Writes a FULL top-level
# nginx.conf (see variant_f.sh's comment on why `stream{}` forces this to be
# a full nginx.conf rather than a conf.d/ snippet — the same constraint
# applies here unchanged).
#
# TELEMT_DOMAIN / TELEMT_PORT are optional (9th/10th positional args). Pass
# empty strings (or omit them) to generate J without the TeleMT SNI branch;
# TELEMT_PORT is expected to be TeleMT's own loopback listener port when
# TELEMT_DOMAIN is non-empty (co-located TeleMT itself is not started or
# configured by this function — see the file header's "NOT YET WIRED" note).
panel_generate_nginx_config_j() {
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

    # Built once, conditionally, so the no-TeleMT case renders exactly the
    # same two-way map Variant F uses (panel_and_sub / default) with no
    # trace of a third branch — same reasoning as
    # docs/MULTI_PROTOCOL_L4_INGRESS.md's "additive, not a modification"
    # requirement for the F-side version of this same extension.
    local TELEMT_MAP_LINE=""
    local TELEMT_UPSTREAM=""
    if [ -n "$TELEMT_DOMAIN" ]; then
        TELEMT_MAP_LINE="    ${TELEMT_DOMAIN}   telemt;"
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
    # bound to a public interface directly — same shape as Variant F, on
    # J's own loopback port so the two variants never collide.
    server {
        server_name ${PANEL_DOMAIN};
        listen 127.0.0.1:${J_NGINX_HTTPS_PORT} ssl proxy_protocol;
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
        listen 127.0.0.1:${J_NGINX_HTTPS_PORT} ssl proxy_protocol;
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

    # Selfsteal decoy + catch-all: this is Vision/REALITY's own fallback
    # destination inside Xray (realitySettings' fallback dest, same role as
    # Variant F's), unaffected by anything in this file — nothing here binds
    # or routes to it directly, Xray reaches it entirely on its own after
    # its own REALITY handshake inspection.
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

# Both public entry points live in ONE stream{} context below — nginx's
# "stream" directive is a single top-level context (like "http"/"events");
# it cannot be repeated as two separate blocks the way "server{}" can be
# repeated inside it. So :443 and :${J_XHTTP_PUBLIC_PORT} are two
# server{} blocks sharing this one stream{} context, not two stream{}
# contexts — unlike Variant F, which only ever needed one public port and
# so never had to make this distinction.
#
# :443 — SNI router for Panel/Sub vs. Vision/REALITY, same ssl_preread
# mechanism and same "raw bytes only, no TLS termination here" reasoning as
# Variant F (see variant_f.sh's stream{} comment for the full citation
# trail against nginx.org's ssl_preread docs and the nginx:1.28 image's
# --with-stream_ssl_preread_module build flag — unchanged here). The
# optional TeleMT branch, when present, is inserted as a third map case
# ahead of "default", per docs/MULTI_PROTOCOL_L4_INGRESS.md's "Variant A"
# recommendation — additive only, the panel_and_sub/default cases below are
# byte-identical to the no-TeleMT form either way.
#
# :${J_XHTTP_PUBLIC_PORT} — dedicated entry point for the XHTTP+REALITY
# ("套娃"/nested) inbound. This is a SEPARATE REALITY inbound from Vision
# (see lib/panel/api.sh's StealXHTTP definition: its own
# streamSettings.security = "reality", own privateKey/shortIds/serverNames),
# not a fallback hanging off Vision — so, like the :443/xray_vision leg,
# it needs raw TCP passthrough with no TLS termination in nginx, and gets
# its own public port rather than a third :443 SNI branch (XHTTP over
# REALITY doesn't carry a distinguishing SNI of its own to route on — it IS
# the REALITY handshake, same as Vision's). No map is needed for this
# server{} block since it has exactly one destination.
stream {
    map \$ssl_preread_server_name \$j_backend {
        ${PANEL_DOMAIN} panel_and_sub;
        ${SUB_DOMAIN}   panel_and_sub;
${TELEMT_MAP_LINE}
        default         xray_vision;
    }
    upstream panel_and_sub { server 127.0.0.1:${J_NGINX_HTTPS_PORT}; }
    upstream xray_vision   { server 127.0.0.1:${J_XRAY_VISION_PORT}; }
    upstream xray_xhttp    { server 127.0.0.1:${J_XRAY_XHTTP_PORT}; }
${TELEMT_UPSTREAM}

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$j_backend;
        # Same C2 defect inherited from Variant F: proxy_protocol is a
        # stream/server-scoped directive, not a per-upstream one, so it
        # applies identically to every branch reached through this single
        # server{} block (panel_and_sub, xray_vision, and telemt when
        # present) — see variant_f.sh's stream{} comment and
        # docs/MULTI_PROTOCOL_L4_INGRESS_REVIEW.md Correction C2 for the
        # original finding. For the xray_vision leg this is handled the
        # same way as Variant F: the Vision/REALITY inbound JSON sets
        # streamSettings.sockopt.acceptProxyProtocol=true
        # (lib/panel/api.sh: panel_reality_accept_proxy_protocol). For the
        # optional telemt leg, TeleMT must independently set
        # "proxy_protocol = true" in its own "[server]" config block to
        # consume this preamble instead of choking on it — this is a
        # process-wide, all-or-nothing switch for TeleMT (confirmed in
        # docs/MULTI_PROTOCOL_L4_INGRESS.md's TeleMT section against
        # upstream issue #777), which is exactly why TeleMT co-location
        # here is documented as a deploy-time choice, not a runtime toggle
        # that could coexist with a standalone/direct-connect TeleMT
        # instance.
        proxy_protocol on;
    }

    server {
        listen ${J_XHTTP_PUBLIC_PORT};
        proxy_pass xray_xhttp;
        # FIXED 2026-08-31: this server{} previously also set
        # "proxy_protocol on;", which was wrong — confirmed (Natalie):
        # StealXHTTP's Xray inbound does not set
        # sockopt.acceptProxyProtocol (see lib/panel/api.sh's
        # panel_reality_accept_proxy_protocol()/j.json, which never
        # applies that field to the StealXHTTP inbound), so a PROXY v1
        # preamble arriving here would not be parsed and would break the
        # REALITY handshake instead of fixing anything. Unlike the :443
        # server{} above, this block has exactly one destination — no
        # ssl_preread map forces it to share a directive across branches
        # (that C2 constraint is specific to the :443 leg), so it can
        # simply omit proxy_protocol entirely.
    }
}
NGINX_CONF_EOF
}
