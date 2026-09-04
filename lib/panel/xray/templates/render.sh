# shellcheck shell=bash
# lib/panel/xray/templates/render.sh — dynamic Xray inbounds JSON
# generator for panel_setup_api()'s StealConfig config-profile.
#
# CHANGED 2026-08-31 (moved off file-based templates): f.json/j.json used
# to be the actual runtime source of truth -- this file selected one of
# them by MODE and fed it to `jq -n -f "$TEMPLATE"` (the template file's
# own content WAS the jq program). That worked, but meant the real Xray
# inbound shape lived in a separate file this function merely dispatched
# to, and (as found auditing a parallel attempt on origin at this same
# stage of the refactor) that kind of file/renderer split is exactly what
# breaks silently the moment someone edits one side without the other --
# origin's version currently returns an empty result for every MODE
# because its render.sh was rewritten to expect f.json/j.json as literal
# static JSON input while the template files themselves were never
# actually converted (confirmed empirically against origin's real
# checked-out files, not assumed from its commit message).
#
# f.json/j.json are KEPT on disk, unchanged, as golden regression
# fixtures only -- see the golden-equivalence test in this file's
# regression suite. Nothing in this function reads them at runtime
# anymore.
#
# All parameter substitution goes through jq --arg/--argjson (never shell
# string interpolation into JSON text) -- same discipline the file-based
# version already followed.
#
# CHANGED 2026-08-31 (F/J -> F + independent XHTTP_ENABLE capability):
# discriminator is now an explicit XHTTP_ENABLE parameter (11th,
# appended at the END of the argument list rather than inserted in the
# middle -- inserting it earlier would have silently shifted every
# existing positional argument for MODE=1/2 callers too). Backward
# compatible: if the caller doesn't pass it (empty string), XHTTP_ENABLE
# is derived from the legacy MODE="J" signal -- identical value to what
# this function computed internally before this change, so the one real
# call site (lib/panel/api.sh's panel_setup_api()) needs no update to
# keep working exactly as before; it can adopt the explicit parameter on
# its own schedule.
#
# Args: MODE PRIV_KEY SHORT_ID DEST_VAL SELFSTEAL_DOMAIN VISION_PORT
#       XHTTP_PORT XHTTP_PATH ACCEPT_PP [XHTTP_ENABLE]
# (MODE itself is still accepted -- kept for the legacy-fallback above
# and because callers that only know a MODE letter still exist -- but it
# no longer drives the actual Steal-vs-Steal+StealXHTTP structure below;
# XHTTP_ENABLE does.)
# ACCEPT_PP must be the literal string "true" or "false" (as returned by
# panel_reality_accept_proxy_protocol) -- passed via --argjson so it
# becomes a real JSON boolean. Applied ONLY to the "Steal" (Vision) tag,
# never to "StealXHTTP" -- lib/panel/nginx/variant_j.sh's
# :$J_XHTTP_PUBLIC_PORT server{} deliberately has no `proxy_protocol on;`
# (see that file's comment), so StealXHTTP's Xray inbound must not expect
# one either -- a mismatch here breaks every XHTTP REALITY handshake, not
# just fail to help. This is an ingress-topology question (does nginx sit
# in front and send a PROXY preamble?), not an XHTTP_ENABLE question --
# see lib/panel/api.sh's panel_reality_accept_proxy_protocol().
#
# Prints the rendered JSON array on stdout, or nothing (jq's stderr
# suppressed) on failure -- callers must check for an empty result
# themselves, same contract as before.
panel_xray_render_inbounds() {
    local MODE="$1"
    local PRIV_KEY="$2"
    local SHORT_ID="$3"
    local DEST_VAL="$4"
    local SELFSTEAL_DOMAIN="$5"
    local VISION_PORT="$6"
    local XHTTP_PORT="$7"
    local XHTTP_PATH="$8"
    local ACCEPT_PP="$9"
    local XHTTP_ENABLE="${10:-}"

    if [ -z "$XHTTP_ENABLE" ]; then
        XHTTP_ENABLE="0"
        [ "$MODE" = "J" ] && XHTTP_ENABLE="1"
    fi

    local DUAL="false"
    [ "$XHTTP_ENABLE" = "1" ] && DUAL="true"

    jq -n \
        --arg pk "$PRIV_KEY" \
        --arg sid "$SHORT_ID" \
        --arg dest "$DEST_VAL" \
        --arg domain "$SELFSTEAL_DOMAIN" \
        --argjson vport "$VISION_PORT" \
        --argjson xport "$XHTTP_PORT" \
        --arg xpath "$XHTTP_PATH" \
        --argjson accept_pp "$ACCEPT_PP" \
        --argjson dual "$DUAL" \
        '
        def reality:
            { show: false, xver: 1, dest: $dest, spiderX: "",
              shortIds: [$sid], privateKey: $pk, serverNames: [$domain] };

        def steal:
            { tag: "Steal", port: $vport, protocol: "vless",
              settings: { clients: [], decryption: "none" },
              sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
              streamSettings: (
                  { network: "tcp", security: "reality", realitySettings: reality }
                  + (if $accept_pp then { sockopt: { acceptProxyProtocol: true } } else {} end)
              ) };

        def stealxhttp:
            { tag: "StealXHTTP", port: $xport, protocol: "vless",
              settings: { clients: [], decryption: "none" },
              sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
              streamSettings: {
                  network: "xhttp", security: "reality",
                  realitySettings: reality,
                  xhttpSettings: { path: $xpath }
              } };

        if $dual then [steal, stealxhttp] else [steal] end
        ' 2>/dev/null
}
