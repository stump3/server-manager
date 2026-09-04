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
# templates were made genuine static JSON (jq empty passes) holding
# neutral placeholders (0 for ports, "" for strings).
#
# CHANGED AGAIN (this pass, 2026-09-04): f.json/j.json are no longer read
# at runtime at all. They are kept on disk, unchanged in content, as
# GOLDEN FIXTURES — a reviewable, `jq empty`-clean reference for exactly
# what shape each inbound array must have, and the regression baseline
# tests compare this file's generated output against. The actual
# generation now happens entirely inline below, driven by XHTTP_ENABLE
# instead of a MODE-to-filename dispatch. Reasoning: the file-loading
# indirection added a runtime file-I/O dependency (locate
# _PANEL_XRAY_TEMPLATE_DIR, open a file, handle "not found") for
# structure that is only ever one of two known shapes — inlining that
# structure into the same jq invocation that already does all the
# dynamic substitution removes that dependency without changing the
# substitution logic's size or shape at all. Semantic (not just visual)
# equivalence against both golden files is verified via `jq -S`
# canonicalized diff after filling in the same placeholder values the
# golden files hold — see the regression tests referenced in this
# session's report, not asserted here without proof.
#   - Steal (Vision/REALITY): used for MODE=1, MODE=2, and MODE=F/J
#     alike — all four only ever needed this one inbound shape; only the
#     $vport/$dest/$accept_pp *values* passed in differ between them.
#     Structurally identical to f.json's sole array element and to
#     j.json's first array element (confirmed 0-diff between those two
#     during this session's earlier audit).
#   - StealXHTTP (REALITY-over-XHTTP): only emitted when XHTTP_ENABLE=1
#     — nginx's public :$J_XHTTP_PUBLIC_PORT
#     (lib/panel/nginx/variant_j.sh) proxy_passes to this inbound's
#     loopback port. Shares privateKey/serverNames/shortIds with Steal
#     (same REALITY identity, reachable on two different public ports);
#     only tag/port/network/xhttpSettings differ. Structurally identical
#     to j.json's second array element.
#
# REALITY dest/target naming (2026-09-01, corrected 2026-09-01):
# Xray-core's own config-parsing source (infra/conf/transport_security.go,
# `type REALITYConfig struct`) declares BOTH `Target json.RawMessage
# \`json:"target"\`` and `Dest json.RawMessage \`json:"dest"\`` as separate
# JSON keys on the same struct, and REALITYConfig.Build() does
# `if c.Target != nil { c.Dest = c.Target }` before using c.Dest for
# everything downstream — confirmed by reading that source directly
# (github.com/XTLS/Xray-core, cloned and grepped, not inferred from
# docs). This proves the two keys are fully equivalent aliases at the
# code level; it does NOT prove `dest` is deprecated, broken, or wrong
# in any functional sense — both are first-class, actively-maintained
# JSON keys on the same struct. An earlier pass here renamed this to
# `target`, reasoning from Xray-core's own docs page describing `dest`
# as the "old name" — that phrasing is accurate but doesn't make `dest`
# incorrect, and the project's explicit decision (independent of what
# any origin commit or prior pass here did) is to keep `dest`. Reverted
# accordingly. The specific internal doc this was at one point sourced
# from (09-lab-protocol-expansion.md) still could not be found in this
# repository or in stump3/xray-lab — not used as a justification either
# way. The reference repo eGamesAPI/remnawave-reverse-proxy (commit
# 8486fc4) uses `dest`, consistent with keeping it here. The jq --arg
# binding is named $dest below (and DEST_VAL/panel_reality_dest_val
# elsewhere in lib/panel/api.sh) and the emitted JSON key is now also
# `dest` again — both match, nothing left renamed on only one side.
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
            | .streamSettings.realitySettings.dest = $dest
            | (if .tag == "StealXHTTP" then .streamSettings.xhttpSettings.path = $xpath else . end)
            | (if (.tag == "Steal" and $accept_pp)
               then .streamSettings.sockopt = { "acceptProxyProtocol": true }
               else . end)
        )' \
        "$TEMPLATE" 2>/dev/null
}
