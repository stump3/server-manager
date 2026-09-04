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

# panel_xray_render_inbounds — capability-dispatching renderer for the
# Xray "inbounds" JSON array used by panel_setup_api()'s StealConfig
# config-profile.
#
# XHTTP_ENABLE added 2026-08-31 (XHTTP_ENABLE/TELEMT_COLOCATE
# architecture, Phase A): the dual-inbound decision used to be made
# directly by `[ "$MODE" = "J" ]` inside this function — meaning "does
# this profile get a StealXHTTP inbound" and "is MODE literally the
# letter J" were the same question, with no way to ask for one without
# the other. Added as the 10th, OPTIONAL positional arg specifically so
# every existing 9-arg call site keeps working unchanged (backward
# compatible, not a breaking signature change): when omitted, it is
# normalized from MODE exactly the way callers already relied on —
# MODE=J implies XHTTP_ENABLE=1, anything else implies XHTTP_ENABLE=0 —
# so old callers see byte-identical behavior. New callers may pass
# XHTTP_ENABLE explicitly (e.g. MODE=F + XHTTP_ENABLE=1) to get the dual-
# inbound shape without MODE being "J" at all; this is the mechanism, MODE
# itself is no longer consulted for this decision once XHTTP_ENABLE is
# known — see the single `[ "$XHTTP_ENABLE" = "1" ]` template-selection
# line below, MODE does not appear in it.
#
#   XHTTP_ENABLE=1 → templates/j.json  (Steal/Vision + StealXHTTP, both REALITY)
#   XHTTP_ENABLE=0 (or MODE-normalized default for MODE=1/2/F) →
#     templates/f.json (single Steal/Vision REALITY inbound) — this is
#     not new behavior: MODE=1/2's single-inbound shape and MODE=F's
#     single-inbound shape were always identical JSON before this
#     extraction (they only differed in the $vport/$dest/$accept_pp
#     *values* passed in, which is exactly what the caller-supplied
#     arguments below still control) — see f.json's header comment.
#
# Args: MODE PRIV_KEY SHORT_ID DEST_VAL SELFSTEAL_DOMAIN VISION_PORT
#       XHTTP_PORT XHTTP_PATH ACCEPT_PP [XHTTP_ENABLE]
# ACCEPT_PP must be the literal string "true" or "false" (as returned by
# panel_reality_accept_proxy_protocol) — passed to jq via --argjson so it
# becomes a real JSON boolean, not a string, for the templates' `if
# $accept_pp then ... end` checks. XHTTP_ENABLE, if passed explicitly,
# must be the literal string "0" or "1" (not "true"/"false" — chosen to
# match TELEMT_COLOCATE's planned shape and to read unambiguously as a
# capability flag rather than a JSON-bound boolean, since it is consumed
# entirely in bash here and never reaches jq).
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
    local XHTTP_ENABLE="${10:-}"

    # Normalize only when the caller didn't say — an explicit "0" from a
    # MODE=J caller (or an explicit "1" from a MODE=F caller) is honored
    # as-is; this is the legacy-J-becomes-a-compatibility-alias mechanism
    # described in the file header, not a fallback that overrides real
    # input.
    if [ -z "$XHTTP_ENABLE" ]; then
        if [ "$MODE" = "J" ]; then
            XHTTP_ENABLE="1"
        else
            XHTTP_ENABLE="0"
        fi
    fi

    local TEMPLATE="${_PANEL_XRAY_TEMPLATE_DIR}/f.json"
    [ "$XHTTP_ENABLE" = "1" ] && TEMPLATE="${_PANEL_XRAY_TEMPLATE_DIR}/j.json"

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
