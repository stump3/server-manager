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
# FIXED (this pass, 2026-09-01): f.json/j.json had been left in a broken
# intermediate state by an in-progress migration to genuine static JSON —
# both still contained bare, unbound `$vport`/`$dest`/`$sid`/etc. tokens,
# which are not valid JSON syntax at all (`jq empty` failed with "Invalid
# numeric literal" on both, confirmed empirically, not assumed from
# reading the header comments' claim that they already passed). Every
# actual call to panel_xray_render_inbounds() for every MODE (1/2/F/J)
# was silently returning an empty string as a result — confirmed by
# actually invoking the renderer before this fix, not inferred. Both
# templates are now genuine static JSON (jq empty passes) holding neutral
# placeholders (0 for ports, "" for strings) for every field this filter
# below fills in. Moving the fix here, into render.sh's own comments,
# because genuine JSON cannot contain `#` comments the way the old
# jq-filter-style templates could — the documentation that used to live
# at the top of f.json/j.json themselves (bound-variable list, the
# StealXHTTP/no-sockopt rule, j.json's once-missing-entirely history) is
# consolidated into this file's comments instead, not deleted:
#   - f.json: single "Steal" (Vision/REALITY) inbound. Used for MODE=1,
#     MODE=2, and MODE=F alike — all three only ever needed this one
#     inbound shape; only the $vport/$dest/$accept_pp *values* passed to
#     this function differ between them.
#   - j.json: "Steal" (Vision/REALITY) + "StealXHTTP" (REALITY-over-XHTTP,
#     Variant J's second public leg — nginx's :$J_XHTTP_PUBLIC_PORT in
#     lib/panel/nginx/variant_j.sh proxy_passes to this inbound's loopback
#     port). Both inbounds share privateKey/serverNames/shortIds (same
#     REALITY identity, reachable on two different public ports); only
#     tag/port/network/xhttpSettings differ. This file did not exist at
#     all until 2026-08-31 (93d9d2f) despite being referenced by name
#     elsewhere before that — see that commit if the history matters.
#
# REALITY dest/target naming (2026-09-01): Xray-core's own docs
# (https://xtls.github.io/en/config/transports/reality.html) confirm
# `dest` is the old name and `target` is now current, with the two kept
# as aliases — so this rename is not a functional change, either name
# works against a real Xray-core. The specific internal doc this was
# originally sourced from (09-lab-protocol-expansion.md) could not be
# found in this repository or in stump3/xray-lab when checked — flagging
# that honestly rather than presenting it as verified. The reference repo
# eGamesAPI/remnawave-reverse-proxy (commit 8486fc4) still uses `dest`,
# which doesn't contradict the above — both names work, that project
# simply hasn't adopted the newer one. `target` was chosen here for
# consistency with current upstream Xray-core documentation. The jq
# --arg binding is still named $dest below (and DEST_VAL/panel_reality_dest_val
# elsewhere in lib/panel/api.sh) — only the JSON key this filter assigns
# into changed, not the shell/jq variable name carrying the value,
# per explicit instruction not to rename that for its own sake.
#

# All parameter substitution goes through jq --arg/--argjson (never string
# interpolation into JSON text itself) — this was already the discipline
# the original inline blocks followed; this file does not relax it.
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
#     structure.
#
# Args: MODE PRIV_KEY SHORT_ID DEST_VAL SELFSTEAL_DOMAIN VISION_PORT
#       XHTTP_PORT XHTTP_PATH ACCEPT_PP
# ACCEPT_PP must be the literal string "true" or "false" (as returned by
# panel_reality_accept_proxy_protocol) — passed to jq via --argjson so it
# becomes a real JSON boolean. Applied ONLY to the "Steal" (Vision) tag,
# never to "StealXHTTP" — see lib/panel/nginx/variant_j.sh's
# :$J_XHTTP_PUBLIC_PORT server{} (no `proxy_protocol on;` there,
# deliberately) and lib/panel/api.sh's panel_reality_accept_proxy_protocol()
# doc comment: StealXHTTP does not receive a PROXY preamble from nginx, so
# its Xray inbound must not expect one either — a mismatch here would
# break every MODE=J REALITY handshake on the XHTTP leg, not just fail to
# help.
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
            | .streamSettings.realitySettings.target = $dest
            | (if .tag == "StealXHTTP" then .streamSettings.xhttpSettings.path = $xpath else . end)
            | (if (.tag == "Steal" and $accept_pp)
               then .streamSettings.sockopt = { "acceptProxyProtocol": true }
               else . end)
        )' \
        "$TEMPLATE" 2>/dev/null
}
