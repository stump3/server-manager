#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  SERVER-MANAGER — VPN Server Management                         ║
# ║  https://github.com/stump3/server-manager                       ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Использование:
#   Рекомендуется (полная установка с integrations/ и sub-injector/):
#     git clone https://github.com/stump3/server-manager /root/server-manager
#     bash /root/server-manager/server-manager.sh
#
#   Быстрый запуск (только основные модули, без integrations/):
#     curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
REPO_RAW="https://raw.githubusercontent.com/stump3/server-manager/main"

# SHA256 контрольные суммы модулей — обновляйте при каждом релизе.
# Оставьте "" чтобы отключить проверку для конкретного модуля.
declare -A _MODULE_SHA256=(
    ["common"]=""
    ["panel"]=""
    ["telemt"]=""
    ["hysteria"]=""
    ["migrate"]=""
)

_load_module() {
    local mod="$1"
    local local_path="${SCRIPT_DIR}/lib/${mod}.sh"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$local_path" ]; then
        # shellcheck source=/dev/null
        source "$local_path"
    else
        local tmp; tmp=$(mktemp)
        if ! curl -fsSL "${REPO_RAW}/lib/${mod}.sh" -o "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            echo "Ошибка загрузки модуля: ${mod}.sh"; exit 1
        fi
        # Проверяем SHA256 если задан
        local expected_sha="${_MODULE_SHA256[$mod]:-}"
        if [ -n "$expected_sha" ]; then
            local actual_sha; actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
            if [ "$actual_sha" != "$expected_sha" ]; then
                rm -f "$tmp"
                echo "ОШИБКА: SHA256 модуля ${mod}.sh не совпадает!"
                echo "  Ожидалось: $expected_sha"
                echo "  Получено:  $actual_sha"
                echo "  Возможна компрометация репозитория. Выполнение прервано."
                exit 1
            fi
        fi
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
