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
# MODE-gating fix below for the one real behavior change, which is scoped
# to MODE=F/J only and described in lib/panel/api.sh's own comments).
#
# All parameter substitution goes through jq --arg/--argjson (never string
# interpolation into the JSON/JS text itself) — this is the same
# discipline the original inline blocks already followed; moving them to
# template files does not relax it. Do NOT sed/printf values into the
# .json template files; always pass them as jq variables here.
_PANEL_XRAY_TEMPLATE_DIR="$(dirname "${BASH_SOURCE[0]}")"

# panel_xray_render_inbounds — MODE-dispatching renderer for the Xray
# "inbounds" JSON array used by panel_setup_api()'s StealConfig
# config-profile.
#
#   MODE=J → templates/j.json  (Steal/Vision + StealXHTTP, both REALITY)
#   anything else (1, 2, F) → templates/f.json (single Steal/Vision
#     REALITY inbound) — this is not new behavior: MODE=1/2's
#     single-inbound shape and MODE=F's single-inbound shape were always
#     identical JSON before this extraction (they only differed in the
#     $vport/$dest/$accept_pp *values* passed in, which is exactly what
#     the caller-supplied arguments below still control) — see f.json's
#     header comment.
#
# Args: MODE PRIV_KEY SHORT_ID DEST_VAL SELFSTEAL_DOMAIN VISION_PORT
#       XHTTP_PORT XHTTP_PATH ACCEPT_PP
# ACCEPT_PP must be the literal string "true" or "false" (as returned by
# panel_reality_accept_proxy_protocol) — passed to jq via --argjson so it
# becomes a real JSON boolean, not a string, for the templates' `if
# $accept_pp then ... end` checks.
#
# Prints the rendered JSON array on stdout, or nothing (with jq's own
# stderr suppressed, matching the original inline blocks' `2>/dev/null`)
# if template rendering fails — callers must check for an empty result
# themselves, same as they already had to for the inline jq calls this
# replaces.
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

    local TEMPLATE="${_PANEL_XRAY_TEMPLATE_DIR}/f.json"
    [ "$MODE" = "J" ] && TEMPLATE="${_PANEL_XRAY_TEMPLATE_DIR}/j.json"

    jq -n \
        --arg pk "$PRIV_KEY" \
        --arg sid "$SHORT_ID" \
        --arg dest "$DEST_VAL" \
        --arg domain "$SELFSTEAL_DOMAIN" \
        --argjson vport "$VISION_PORT" \
        --argjson xport "$XHTTP_PORT" \
        --arg xpath "$XHTTP_PATH" \
        --argjson accept_pp "$ACCEPT_PP" \
        -f "$TEMPLATE" 2>/dev/null
}
