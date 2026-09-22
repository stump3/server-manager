# shellcheck shell=bash
# lib/panel/compose.sh — panel_generate_compose() dispatcher.
#
# Replaced 2026-08-31: this file used to be a single 667-line
# panel_generate_compose() containing five nearly-identical inline
# docker-compose.yml heredocs (one per real WEB_SERVER×MODE combination:
# 1×1, 1×F, 1×2, 2×1, 2×2/else — MODE=J had no branch of its own and fell
# through the elif chain into the 2×2/else Caddy panel-only heredoc,
# silently dropping remnanode). lib/panel/compose/{common,colocated,remote}.sh
# already existed alongside this file (extracted the same day) but were
# dead code — panel_generate_compose_colocated()/_remote() were never
# actually called from here. This file now only dispatches to them.
#
# Public signature UNCHANGED (lib/panel/install.sh's only call site is
# untouched): panel_generate_compose WEB_SERVER MODE CERT_VOLUMES
# PANEL_DOMAIN SUB_DOMAIN SELFSTEAL_DOMAIN.
#
# Topology split confirmed from the original file's own structure, not
# assumed: MODE=2 was the only MODE with no remnanode block in any of its
# two original heredocs (1×2 and 2×2/else) — that's lib/panel/compose/
# remote.sh, which correspondingly takes no MODE argument at all (there's
# only one remote shape). Every other MODE (1, F, and now J) always
# included remnanode — that's colocated.sh, which does take MODE (it
# still branches internally on nginx-mount-target and on the
# WEB_SERVER=2+MODE=F/J guard — see colocated.sh's own comments).
# regression-tested: all 5 real legacy combinations produce
# byte-for-byte identical output through this dispatcher vs. the old
# monolith (SHA256 compared, not visual diff).
panel_generate_compose() {
    local WEB_SERVER="$1"
    local MODE="$2"
    local CERT_VOLUMES="$3"
    local PANEL_DOMAIN="$4"
    local SUB_DOMAIN="$5"
    local SELFSTEAL_DOMAIN="$6"

    if [ "$MODE" = "2" ]; then
        panel_generate_compose_remote \
            "$WEB_SERVER" "$CERT_VOLUMES" "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"
    else
        panel_generate_compose_colocated \
            "$WEB_SERVER" "$MODE" "$CERT_VOLUMES" "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"
    fi
}
