#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  SERVER-MANAGER — VPN Server Management                         ║
# ║  https://github.com/stump3/server-manager                       ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Использование:
#   bash server-manager.sh
#   curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
REPO_RAW="https://raw.githubusercontent.com/stump3/server-manager/main"

_load_module() {
    local mod="$1"
    local local_path="${SCRIPT_DIR}/lib/${mod}.sh"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$local_path" ]; then
        # shellcheck source=/dev/null
        source "$local_path"
    else
        local tmp; tmp=$(mktemp)
        curl -fsSL "${REPO_RAW}/lib/${mod}.sh" -o "$tmp" 2>/dev/null \
            || { echo "Ошибка загрузки модуля: ${mod}.sh"; exit 1; }
        # shellcheck source=/dev/null
        source "$tmp"
        rm -f "$tmp"
    fi
}

_load_module common
_load_module panel
_load_module telemt
_load_module hysteria
_load_module migrate

check_root
main_menu
