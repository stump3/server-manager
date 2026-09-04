# shellcheck shell=bash
#
# lib/panel/xray/templates/render.sh — safe parameter substitution for the
# F/J Xray inbound JSON templates (lib/panel/xray/templates/{f,j}.json,
# same directory as this file).
#
# Extracted 2026-08-31: previously, lib/panel/api.sh's panel_setup_api()
# contained two full inline `jq -n ... '[...]'` blocks (one per MODE
# branch) building the Xray "inbounds" JSON array directly as a bash
# string. That worked but meant the actual Xray inbound shape was buried
# inside api.sh's control flow rather than being a reviewable artifact on
# its own — this file and its two templates are that extraction, with NO
# functional change to the JSON produced for MODE=1/2/F (see the F-vs-J
# MODE-gating fix described in lib/panel/api.sh's own comments for the one
# real behavior change, which is scoped to MODE=F/J only).
#
# FIXED (this pass): f.json/j.json were previously jq FILTER PROGRAMS
# (read via `jq -f`, containing unbound `$variable` references and `#`
# comments) rather than actual JSON documents — `jq empty
# lib/panel/xray/templates/f.json` failed, because the file's own content
# was never meant to be parsed as JSON, only as jq source that PRODUCES
# JSON when executed with bound variables. That is a real, working
# mechanism, but it doesn't satisfy "the template is a standalone,
# independently-inspectable JSON artifact" — a template a reviewer can't
# `jq empty`/diff/open in a JSON-aware editor without also reading
# render.sh isn't really standalone. Templates are now genuine, static,
# valid JSON (`jq empty` passes on both) holding neutral placeholder
# values (0 for ports, "" for strings) for every field this file fills
# in; all the substitution logic (including the conditional
# sockopt.acceptProxyProtocol addition, applied only to the "Steal" tag —
# see the ACCEPT_PP note below) now lives here, in render.sh, as a single
# `jq` filter applied ON TOP of the loaded template via `--slurpfile`,
# rather than being written into the template file itself. The rendered
# output is unchanged — verified by diffing this version's output against
# the previous jq-filter-file version's output for both MODE=F and MODE=J
# (accept_pp true and false), byte-for-byte identical after `jq -S`
# canonicalization.
#
# All parameter substitution goes through jq --arg/--argjson (never string
# interpolation into JSON text itself) — this was already the discipline
# the original inline blocks followed; this file does not relax it.
_PANEL_XRAY_TEMPLATE_DIR="$(dirname "${BASH_SOURCE[0]}")"

# panel_xray_render_inbounds — XHTTP_ENABLE-dispatching renderer for the
# Xray "inbounds" JSON array used by panel_setup_api()'s StealConfig
# config-profile.
#
#   XHTTP_ENABLE=1 → templates/j.json (Steal/Vision + StealXHTTP, both
#     REALITY)
#   XHTTP_ENABLE=0 (or a legacy literal MODE="J" without an explicit
#     XHTTP_ENABLE — see the fallback below) → templates/f.json (single
#     Steal/Vision REALITY inbound) — this is not new behavior: MODE=1/2's
#     single-inbound shape and MODE=F's single-inbound shape were always
#     identical JSON before this extraction (they only differed in the
#     $vport/$dest/$accept_pp *values* passed in, which is exactly what
#     the caller-supplied arguments below still control) — see f.json's
#     structure.
#
# CANONICAL STATE (this pass): dispatch used to key off a literal
# MODE="J" string. That conflated "which Xray inbound shape" with "which
# MODE letter was chosen", which is exactly the coupling the F/J ->
# MODE=F + XHTTP_ENABLE/TELEMT_COLOCATE split was meant to remove.
# XHTTP_ENABLE is now the real, explicit switch; MODE is only consulted
# as a defensive fallback for any caller that still passes MODE="J"
# without XHTTP_ENABLE — kept for backward compatibility, not because
# MODE is the canonical signal anymore.
#
# Args: MODE XHTTP_ENABLE PRIV_KEY SHORT_ID DEST_VAL SELFSTEAL_DOMAIN
#       VISION_PORT XHTTP_PORT XHTTP_PATH ACCEPT_PP
# ACCEPT_PP must be the literal string "true" or "false" (as returned by
# panel_reality_accept_proxy_protocol) — passed to jq via --argjson so it
# becomes a real JSON boolean. Applied ONLY to the "Steal" (Vision) tag,
# never to "StealXHTTP" — see lib/panel/nginx/variant_j.sh's
# :$J_XHTTP_PUBLIC_PORT server{} (no `proxy_protocol on;` there,
# deliberately) and lib/panel/api.sh's panel_reality_accept_proxy_protocol()
# doc comment: StealXHTTP does not receive a PROXY preamble from nginx, so
# its Xray inbound must not expect one either — a mismatch here would
# break every XHTTP-enabled REALITY handshake on the XHTTP leg, not just
# fail to help.
#
# Prints the rendered JSON array on stdout, or nothing (with jq's own
# stderr suppressed, matching the original inline blocks' `2>/dev/null`)
# if template rendering fails — callers must check for an empty result
# themselves, same as they already had to for the inline jq calls this
# replaces.
panel_xray_render_inbounds() {
    local MODE="$1"
    local XHTTP_ENABLE="${2:-0}"
    local PRIV_KEY="$3"
    local SHORT_ID="$4"
    local DEST_VAL="$5"
    local SELFSTEAL_DOMAIN="$6"
    local VISION_PORT="$7"
    local XHTTP_PORT="$8"
    local XHTTP_PATH="$9"
    local ACCEPT_PP="${10}"

    if [ "$MODE" = "J" ]; then XHTTP_ENABLE=1; fi

    local TEMPLATE="${_PANEL_XRAY_TEMPLATE_DIR}/f.json"
    [ "$XHTTP_ENABLE" = "1" ] && TEMPLATE="${_PANEL_XRAY_TEMPLATE_DIR}/j.json"

    jq \
        --arg pk "$PRIV_KEY" \
        --arg sid "$SHORT_ID" \
        --arg dest "$DEST_VAL" \
        --arg domain "$SELFSTEAL_DOMAIN" \
        --argjson vport "$VISION_PORT" \
        --argjson xport "$XHTTP_PORT" \
        --arg xpath "$XHTTP_PATH" \
        --argjson accept_pp "$ACCEPT_PP" \
        'map(
            (if .tag == "Steal" then .port = $vport
             elif .tag == "StealXHTTP" then .port = $xport
             else . end)
            | .streamSettings.realitySettings.privateKey = $pk
            | .streamSettings.realitySettings.shortIds = [$sid]
            | .streamSettings.realitySettings.serverNames = [$domain]
            | .streamSettings.realitySettings.dest = $dest
            | (if .tag == "StealXHTTP" then .streamSettings.xhttpSettings.path = $xpath else . end)
            | (if (.tag == "Steal" and $accept_pp)
               then .streamSettings.sockopt = { "acceptProxyProtocol": true }
               else . end)
        )' \
        "$TEMPLATE" 2>/dev/null
}
