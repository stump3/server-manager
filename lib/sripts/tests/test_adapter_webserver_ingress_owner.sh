#!/bin/bash
# lib/sripts/tests/test_adapter_webserver_ingress_owner.sh
#
# Adapter #8: panel_generate_nginx_config()'s (lib/panel/nginx/config.sh)
# and panel_generate_caddy_config()'s (lib/panel/caddy/config.sh) LISTEN_DIR
# / Caddyfile-shape decision moves from a raw `[ "$MODE" = "1" ]` to the
# existing Core query lib/core/topology.sh:core_topology_public_ingress_owner(),
# checked against its "xray" value.
#
# NOT the same guard as Adapter #6 (core_deployment_web_server_ok(), the
# WEB_SERVER=2+MODE compatibility check) or Adapter #7 (colocated.sh's
# MOUNT_TARGET decision via core_topology_requires_nginx_stream()) -- this
# is a third, independent call site consuming the SAME accessor
# core_topology_requires_nginx_stream() itself wraps
# (core_topology_public_ingress_owner()), not a new fact and not those
# adapters' decisions. This file does not touch either of them.
#
# Precondition note (re-verified independently here, not assumed carried
# over): both candidate functions are reached, in the real system, only
# via panel_core_generate_webserver_config() (lib/core/adapter_webserver.sh)
# -> panel_generate_webserver_config() (lib/panel/nginx/config.sh
# dispatcher), which install.sh calls AFTER core_resolve_deployment() has
# already validated MODE via core_topology_is_valid(). Both candidate
# functions are pure functions of their own $MODE positional argument
# (core_topology_public_ingress_owner() reads no globals) -- $MODE, the
# argument they already had, is the correct, byte-identical input either
# way; no DEPLOYMENT_TOPOLOGY global read is needed or added.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
assert() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $desc -- expected [$expected] got [$actual]"
    fi
}

echo "== A. bash -n =="
for f in lib/panel/nginx/config.sh lib/panel/caddy/config.sh lib/core/topology.sh; do
    bash -n "$f" 2>/tmp/synerr8 && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: bash -n $f"; cat /tmp/synerr8; }
done

# Real production module load, same pattern as test_adapter_webserver.sh.
load_and_generate() {
    # $1 = which generator (nginx|caddy), $2 = MODE
    local kind="$1" mode="$2"
    bash -c '
        source lib/core/config.sh
        source lib/core/deployment.sh
        source lib/ui/output.sh
        source lib/common.sh
        source lib/panel.sh
        mkdir -p /opt/remnawave
        rm -f /opt/remnawave/nginx.conf /opt/remnawave/Caddyfile
        if [ "'"$kind"'" = "nginx" ]; then
            panel_generate_nginx_config "'"$mode"'" "panel.example.com" "sub.example.com" "node.example.com" \
                "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null 2>&1
            cat /opt/remnawave/nginx.conf 2>/dev/null
        else
            panel_generate_caddy_config "'"$mode"'" "CK" "CV" >/dev/null 2>&1
            cat /opt/remnawave/Caddyfile 2>/dev/null
        fi
    '
}

echo ""
echo "== B. real production decision: MODE=1 -> xray-owned shape, MODE=2 -> direct shape =="
NGINX_1="$(load_and_generate nginx 1)"
NGINX_2="$(load_and_generate nginx 2)"
assert "MODE=1 nginx.conf uses the unix-socket LISTEN_DIR (xray owns ingress)" \
    "$(grep -c 'listen unix:/dev/shm/nginx.sock ssl proxy_protocol;' <<<"$NGINX_1")" "4"
assert "MODE=1 nginx.conf does NOT use the direct :443 LISTEN_DIR" \
    "$(grep -c '^    listen 443 ssl;$' <<<"$NGINX_1")" "0"
assert "MODE=2 nginx.conf uses the direct :443 LISTEN_DIR (nginx owns ingress)" \
    "$(grep -c '^    listen 443 ssl;$' <<<"$NGINX_2")" "4"
assert "MODE=2 nginx.conf does NOT use the unix-socket LISTEN_DIR" \
    "$(grep -c 'listen unix:/dev/shm/nginx.sock' <<<"$NGINX_2")" "0"

CADDY_1="$(load_and_generate caddy 1)"
CADDY_2="$(load_and_generate caddy 2)"
assert "MODE=1 Caddyfile binds the unix socket (xray owns ingress)" \
    "$(grep -c 'bind unix//dev/shm/nginx.sock' <<<"$CADDY_1")" "3"
assert "MODE=2 Caddyfile does NOT bind the unix socket (Caddy owns ingress directly)" \
    "$(grep -c 'bind unix//dev/shm/nginx.sock' <<<"$CADDY_2")" "0"

echo ""
echo "== C. legacy equivalence: old raw formula vs new accessor-driven boolean, for 1/2/F/J/invalid =="
old_formula() { [ "${1:-}" = "1" ] && echo "xray-shape" || echo "other-shape"; }
new_formula() {
    bash -c '
        source lib/core/config.sh
        source lib/core/deployment.sh
        if [ "$(core_topology_public_ingress_owner "'"${1:-}"'")" = "xray" ]; then
            echo "xray-shape"
        else
            echo "other-shape"
        fi
    '
}
for MODE in 1 2 F J X ""; do
    OLD="$(old_formula "$MODE")"
    NEW="$(new_formula "$MODE")"
    assert "legacy equivalence MODE='$MODE' (old=$OLD new=$NEW)" "$NEW" "$OLD"
done

echo ""
echo "== D. full output equivalence: OLD generator body (raw MODE=1 check restored in a temp copy) vs NEW (real, on-disk) byte-for-byte =="
# Reconstruct "OLD" by reverting ONLY the accessor call back to the raw
# comparison, in temp copies -- not a hand-written re-implementation, a
# mechanical one-line revert of the real file, so everything else
# (heredoc bodies, LISTEN_DIR assignments, all other MODE checks) stays
# real production code either side of the diff.
mkdir -p /tmp/_adapter8_old_lib/panel/nginx /tmp/_adapter8_old_lib/panel/caddy
sed 's/if \[ "\$(core_topology_public_ingress_owner "\$MODE")" = "xray" \]; then/if [ "$MODE" = "1" ]; then/' \
    lib/panel/nginx/config.sh > /tmp/_adapter8_old_nginx_config.sh
sed 's/if \[ "\$(core_topology_public_ingress_owner "\$MODE")" = "xray" \]; then/if [ "$MODE" = "1" ]; then/' \
    lib/panel/caddy/config.sh > /tmp/_adapter8_old_caddy_config.sh

REVERT_HIT_NGINX="$(grep -c '^        if \[ "\$MODE" = "1" \]; then$' /tmp/_adapter8_old_nginx_config.sh)"
REVERT_HIT_CADDY="$(grep -c '^        if \[ "\$MODE" = "1" \]; then$' /tmp/_adapter8_old_caddy_config.sh)"
assert "OLD-reconstruction precondition: nginx config.sh's accessor call was actually reverted (exactly once)" "$REVERT_HIT_NGINX" "1"
assert "OLD-reconstruction precondition: caddy config.sh's accessor call was actually reverted (exactly once)" "$REVERT_HIT_CADDY" "1"

generate_with_file() {
    # $1 = kind (nginx|caddy), $2 = path to config.sh to source instead of the real one, $3 = MODE
    local kind="$1" override="$2" mode="$3"
    bash -c '
        source lib/core/config.sh
        source lib/core/deployment.sh
        source lib/ui/output.sh
        source lib/common.sh
        # Load everything panel.sh normally loads EXCEPT nginx/config.sh
        # and caddy/config.sh, which come from the override path instead
        # -- same load order, same set of modules, one substituted file.
        PANEL_LIB_DIR="lib/panel"
        for _m in core cert cli install compose/common compose/colocated compose/remote compose mgmt_script api selfsteal nginx/variant_f nginx/variant_j xray/templates/render node/compose node/api node/install management warp subpage template migrate menu; do
            source "$PANEL_LIB_DIR/$_m.sh"
        done
        source "'"$override"'"
        if [ "'"$kind"'" = "nginx" ]; then
            source "$PANEL_LIB_DIR/caddy/config.sh"
        else
            source "$PANEL_LIB_DIR/nginx/config.sh"
        fi
        mkdir -p /opt/remnawave
        rm -f /opt/remnawave/nginx.conf /opt/remnawave/Caddyfile
        if [ "'"$kind"'" = "nginx" ]; then
            panel_generate_nginx_config "'"$mode"'" "panel.example.com" "sub.example.com" "node.example.com" \
                "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null 2>&1
            cat /opt/remnawave/nginx.conf 2>/dev/null
        else
            panel_generate_caddy_config "'"$mode"'" "CK" "CV" >/dev/null 2>&1
            cat /opt/remnawave/Caddyfile 2>/dev/null
        fi
    '
}

for MODE in 1 2 F J X; do
    OLD_NGINX="$(generate_with_file nginx /tmp/_adapter8_old_nginx_config.sh "$MODE")"
    NEW_NGINX="$(load_and_generate nginx "$MODE")"
    if [ "$OLD_NGINX" = "$NEW_NGINX" ]; then
        assert "nginx.conf byte-identical OLD vs NEW, MODE=$MODE" "IDENTICAL" "IDENTICAL"
    else
        assert "nginx.conf byte-identical OLD vs NEW, MODE=$MODE" "DIFFERS" "IDENTICAL"
    fi

    OLD_CADDY="$(generate_with_file caddy /tmp/_adapter8_old_caddy_config.sh "$MODE")"
    NEW_CADDY="$(load_and_generate caddy "$MODE")"
    if [ "$OLD_CADDY" = "$NEW_CADDY" ]; then
        assert "Caddyfile byte-identical OLD vs NEW, MODE=$MODE" "IDENTICAL" "IDENTICAL"
    else
        assert "Caddyfile byte-identical OLD vs NEW, MODE=$MODE" "DIFFERS" "IDENTICAL"
    fi
done
rm -f /tmp/_adapter8_old_nginx_config.sh /tmp/_adapter8_old_caddy_config.sh
rm -rf /tmp/_adapter8_old_lib

echo ""
echo "== E. production accessor usage: both candidate functions call the Core accessor; the raw MODE=1 comparison is gone from exactly these two functions =="
assert "panel_generate_nginx_config() calls core_topology_public_ingress_owner with \$MODE" \
    "$(grep -c 'core_topology_public_ingress_owner "\$MODE"' lib/panel/nginx/config.sh)" "1"
assert "panel_generate_caddy_config() calls core_topology_public_ingress_owner with \$MODE" \
    "$(grep -c 'core_topology_public_ingress_owner "\$MODE"' lib/panel/caddy/config.sh)" "1"
assert "no raw '[ \"\$MODE\" = \"1\" ]' comparison remains in lib/panel/nginx/config.sh" \
    "$(grep -c '\[ "\$MODE" = "1" \]' lib/panel/nginx/config.sh)" "0"
assert "no raw '[ \"\$MODE\" = \"1\" ]' comparison remains in lib/panel/caddy/config.sh" \
    "$(grep -c '\[ "\$MODE" = "1" \]' lib/panel/caddy/config.sh)" "0"
# Scoped deliberately to these two files only -- other MODE checks
# elsewhere in the repo (Adapter #6/#7's own guards, F/J-specific
# dispatch, CLI guards, etc.) are out of scope for Adapter #8 and are not
# asserted against here.

echo ""
echo "== F. negative mutation: neutralize core_topology_public_ingress_owner's xray case, confirm the REAL production code flips =="
cp lib/core/topology.sh /tmp/_topology8_backup.sh
awk '
    BEGIN{n=0}
    /1\) echo "xray" ;;/{
        n++
        if (n==1) { sub(/1\) echo "xray" ;;/, "1) echo \"NOT-xray\" ;;"); }
    }
    {print}
' lib/core/topology.sh > /tmp/_topology8_mutated.sh
MUTATION_HIT="$(grep -c '1) echo "NOT-xray" ;;' /tmp/_topology8_mutated.sh)"
assert "negative-mutation precondition: the xray case was actually found and mutated exactly once" "$MUTATION_HIT" "1"

if [ "$MUTATION_HIT" = "1" ]; then
    MUT_NGINX_1="$(bash -c '
        source lib/core/config.sh
        source /tmp/_topology8_mutated.sh
        source lib/ui/output.sh
        source lib/common.sh
        PANEL_LIB_DIR="lib/panel"
        for _m in core cert cli install compose/common compose/colocated compose/remote compose mgmt_script api selfsteal nginx/config nginx/variant_f nginx/variant_j xray/templates/render caddy/config node/compose node/api node/install management warp subpage template migrate menu; do
            source "$PANEL_LIB_DIR/$_m.sh"
        done
        mkdir -p /opt/remnawave
        rm -f /opt/remnawave/nginx.conf
        panel_generate_nginx_config "1" "panel.example.com" "sub.example.com" "node.example.com" \
            "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null 2>&1
        grep -c "listen unix:/dev/shm/nginx.sock" /opt/remnawave/nginx.conf 2>/dev/null
    ')"
else
    MUT_NGINX_1="MUTATION_NOT_APPLIED"
fi
DIFF_AFTER_MUTATION_CHECK="$(diff -q /tmp/_topology8_backup.sh lib/core/topology.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_topology8_backup.sh /tmp/_topology8_mutated.sh

assert "with core_topology_public_ingress_owner's xray case neutralized, MODE=1 nginx.conf NO LONGER gets the unix-socket LISTEN_DIR (proves production code is load-bearing on the accessor, not coincidentally matching)" \
    "$MUT_NGINX_1" "0"
assert "the real lib/core/topology.sh on disk was never touched by this mutation exercise" \
    "$DIFF_AFTER_MUTATION_CHECK" "identical"
assert "bash -n lib/core/topology.sh still passes after the mutation exercise" \
    "$(bash -n lib/core/topology.sh; echo $?)" "0"

echo ""
echo "== G. missing accessor: neutralize core_topology_public_ingress_owner entirely, confirm this test's own truth table would FAIL to match expected =="
cp lib/core/topology.sh /tmp/_topology8_backup2.sh
sed 's/^core_topology_public_ingress_owner() {/core_topology_public_ingress_owner_DISABLED() {/' \
    lib/core/topology.sh > /tmp/_topology8_disabled.sh
DISABLE_HIT="$(grep -c '^core_topology_public_ingress_owner() {' /tmp/_topology8_disabled.sh)"
assert "missing-accessor precondition: the function definition was actually renamed away (0 remaining)" "$DISABLE_HIT" "0"

if [ "$DISABLE_HIT" = "0" ]; then
    MISSING_NGINX_1="$(bash -c '
        source lib/core/config.sh
        source /tmp/_topology8_disabled.sh
        source lib/ui/output.sh
        source lib/common.sh
        PANEL_LIB_DIR="lib/panel"
        for _m in core cert cli install compose/common compose/colocated compose/remote compose mgmt_script api selfsteal nginx/config nginx/variant_f nginx/variant_j xray/templates/render caddy/config node/compose node/api node/install management warp subpage template migrate menu; do
            source "$PANEL_LIB_DIR/$_m.sh"
        done
        mkdir -p /opt/remnawave
        rm -f /opt/remnawave/nginx.conf
        panel_generate_nginx_config "1" "panel.example.com" "sub.example.com" "node.example.com" \
            "panel.example.com" "sub.example.com" "node.example.com" "CK" "CV" >/dev/null 2>&1
        grep -c "listen unix:/dev/shm/nginx.sock" /opt/remnawave/nginx.conf 2>/dev/null
    ')"
else
    MISSING_NGINX_1="ACCESSOR_STILL_PRESENT"
fi
DIFF_AFTER_DISABLE_CHECK="$(diff -q /tmp/_topology8_backup2.sh lib/core/topology.sh >/dev/null 2>&1 && echo identical || echo DIFFERS)"
rm -f /tmp/_topology8_backup2.sh /tmp/_topology8_disabled.sh

# With the accessor undefined, `$(core_topology_public_ingress_owner "$MODE")`
# hits "command not found" (exit 127) inside the command substitution;
# the substitution's stdout is empty, so `[ "" = "xray" ]` is false -- the
# `if` silently takes the else branch for EVERY mode, including MODE=1.
# This is exactly the silent-wrong-config failure mode this adapter series
# exists to prevent; this section proves that if the accessor were ever
# accidentally deleted or renamed, section B's own truth-table assertion
# (expecting the unix-socket LISTEN_DIR for MODE=1) would fail loudly
# rather than silently passing.
assert "with the accessor missing, MODE=1 wrongly falls through to the direct-listen shape (0 unix-socket occurrences instead of 4 -- proves this test would catch a missing accessor)" \
    "$MISSING_NGINX_1" "0"
assert "the real lib/core/topology.sh on disk was never touched by this missing-accessor exercise" \
    "$DIFF_AFTER_DISABLE_CHECK" "identical"
assert "bash -n lib/core/topology.sh still passes after the missing-accessor exercise" \
    "$(bash -n lib/core/topology.sh; echo $?)" "0"

echo ""
echo "== Adapter #7 sanity: untouched by this file's changes =="
assert "colocated.sh still calls core_topology_requires_nginx_stream (Adapter #7 untouched)" \
    "$(grep -c 'core_topology_requires_nginx_stream "\$MODE"' lib/panel/compose/colocated.sh)" "1"

echo ""
echo "== cleanup: no stray temp files left behind =="
assert "no leftover /tmp/_adapter8_* or /tmp/_topology8_* files" \
    "$(ls /tmp/_adapter8_* /tmp/_topology8_* 2>/dev/null | wc -l)" "0"

echo ""
echo "==================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==================================="
[ "$FAIL" -eq 0 ]
