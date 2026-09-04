#!/bin/bash
# shellcheck shell=bash
#
# poc/network-inspect/network-inspect.sh
# =======================================
#
# EXPERIMENTAL / RESEARCH POC.
#
#   * NOT sourced by server-manager.sh
#   * NOT registered in lib/cli/router.sh
#   * Does not read, write, or touch any file under lib/
#   * Read-only: no config is written, no service is reloaded/restarted,
#     no firewall/docker/systemd mutation call is ever made (see
#     inventory_build.py's own docstring for the exact read-only-call
#     inventory).
#
# Deliberately kept outside lib/ so this can be deleted, moved, or
# rewritten without touching any file the SHA256-checked module loader
# in server-manager.sh (_load_module/_sm_source_file) cares about, and
# without implying this is a supported CLI subcommand yet.
#
# Per this repo's Contract 9 (docs/CONTRACTS.md §9): "Bash decides
# where/when, Python decides what." All of the actual discovery/
# correlation/normalization logic (parsing `ss` output, walking /proc,
# calling the Docker Engine API, calling systemd, deciding firewall
# authority, etc.) lives in inventory_build.py. This script's only
# jobs are: locate python3, decide whether to show interactive
# progress text, run the Python script, and pass its stdout through
# byte-for-byte.
#
# Per this repo's Contract 1 (docs/CONTRACTS.md §1): stdout carries the
# machine-readable Inventory JSON ONLY. Every diagnostic/progress
# message below goes to stderr — this script reuses lib/ui/output.sh's
# existing info/warn/ok/err helpers (read-only `source`, no
# modification) when that file is reachable, and falls back to
# minimal stderr-only equivalents otherwise, so this PoC still behaves
# correctly if someone copies just this directory out of the repo.

set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SELF_DIR}/../.." && pwd)"
_OUTPUT_SH="${_REPO_ROOT}/lib/ui/output.sh"

if [ -f "$_OUTPUT_SH" ]; then
    # shellcheck source=/dev/null
    source "$_OUTPUT_SH"
else
    # Standalone fallback — same shape as lib/ui/output.sh, stderr-only.
    info()  { echo "  · $*" >&2; }
    warn()  { echo "  ! $*" >&2; }
    ok()    { echo "  + $*" >&2; }
    die()   { echo "  x $*" >&2; exit 1; }
fi

PRETTY=0
CAPABILITIES=0
for arg in "$@"; do
    case "$arg" in
        --pretty) PRETTY=1 ;;
        --capabilities) CAPABILITIES=1 ;;
        -h|--help)
            echo "usage: $(basename "$0") [--pretty] [--capabilities]" >&2
            echo "Read-only network/ingress inventory PoC. Prints one JSON document to stdout." >&2
            echo "  --pretty        indent the JSON output" >&2
            echo "  --capabilities  print the Capability Registry (derived FROM the Inventory" >&2
            echo "                  this same run builds) instead of the Inventory itself — see" >&2
            echo "                  capabilities.py's module docstring for the FACT vs CAPABILITY" >&2
            echo "                  distinction. Default (no flag): prints the Inventory, unchanged" >&2
            echo "                  in schema from before this flag existed." >&2
            exit 0
            ;;
        *)
            die "unknown argument: $arg (see --help)"
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "python3 not found — required by this PoC (already a project-wide dependency, see lib/telemt/core.sh dependency check)"

if [ "$(id -u)" -ne 0 ]; then
    warn "not running as root — some listeners will show pid_unresolved_reason=permission_denied instead of a resolved PID/process (this is reported per-listener in the JSON, not silently dropped)"
fi

info "Building network inventory (read-only: ss/ip/docker-inspect/systemctl-show/firewall-status only, no mutation calls)..."

_PY_ARGS=()
[ "$PRETTY" -eq 1 ] && _PY_ARGS+=(--pretty)
[ "$CAPABILITIES" -eq 1 ] && _PY_ARGS+=(--capabilities)

# Exec, not `$(...)`+echo: keeps this a pure passthrough of Python's
# stdout (Contract 1) and its exit code (Contract 2), with zero
# transformation in between.
exec python3 "${_SELF_DIR}/inventory_build.py" "${_PY_ARGS[@]}"
