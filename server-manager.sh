#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  SERVER-MANAGER — VPN Server Management                         ║
# ║  https://github.com/stump3/server-manager                       ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/stump3/server-manager/main/server-manager.sh | bash
#
#   При первом запуске автоматически клонирует репозиторий в /root/server-manager/
#   и перезапускается оттуда. Повторный запуск: server-manager
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
export SCRIPT_DIR
REPO_RAW="https://raw.githubusercontent.com/stump3/server-manager/main"
REPO_URL="https://github.com/stump3/server-manager"
INSTALL_DIR="/root/server-manager"

# При запуске через curl | bash — SCRIPT_DIR пустой.
# Клонируем репозиторий и перезапускаемся из него.
if [ -z "$SCRIPT_DIR" ]; then
    echo "  Первый запуск — клонируем репозиторий в ${INSTALL_DIR}..."
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo "  Репозиторий уже существует, обновляем..."
        git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
    else
        git clone "$REPO_URL" "$INSTALL_DIR" 2>/dev/null \
            || { echo "Ошибка: не удалось клонировать репозиторий"; exit 1; }
    fi
    chmod +x "${INSTALL_DIR}/server-manager.sh" 2>/dev/null || true
    # Симлинк для запуска из любого места
    ln -sf "${INSTALL_DIR}/server-manager.sh" /usr/local/bin/server-manager 2>/dev/null || true
    echo "  Симлинк: /usr/local/bin/server-manager → ${INSTALL_DIR}/server-manager.sh"
    echo "  Запускаем из ${INSTALL_DIR}..."
    exec bash "${INSTALL_DIR}/server-manager.sh"
fi

# Страхуемся: файл запуска должен быть исполняемым
chmod +x "${SCRIPT_DIR}/server-manager.sh" 2>/dev/null || true

    # Симлинк для запуска из любого места
    ln -sf "${INSTALL_DIR}/server-manager.sh" /usr/local/bin/server-manager 2>/dev/null || true
    echo "  Симлинк: /usr/local/bin/server-manager → ${INSTALL_DIR}/server-manager.sh"
    echo "  Запускаем из ${INSTALL_DIR}..."
    exec bash "${INSTALL_DIR}/server-manager.sh"
fi

# При локальном запуске — тоже убедиться что симлинк актуален
if [ ! -L /usr/local/bin/server-manager ] || \
   [ "$(readlink /usr/local/bin/server-manager 2>/dev/null)" != "${SCRIPT_DIR}/server-manager.sh" ]; then
    ln -sf "${SCRIPT_DIR}/server-manager.sh" /usr/local/bin/server-manager 2>/dev/null || true
fi

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
