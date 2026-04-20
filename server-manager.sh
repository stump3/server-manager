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

_SOURCE_PATH="${BASH_SOURCE[0]:-$0}"
_SOURCE_PATH="${_SOURCE_PATH%$'\r'}"

# Если запущено через симлинк (/usr/local/bin/server-manager), разворачиваем
# до реального файла. Если не удалось — оставляем как есть.
_RESOLVED_PATH="$(readlink -f "$_SOURCE_PATH" 2>/dev/null || echo "")"
[ -n "$_RESOLVED_PATH" ] && _SOURCE_PATH="$_RESOLVED_PATH"

SCRIPT_DIR=""
if [ -f "$_SOURCE_PATH" ]; then
    _CANDIDATE_DIR="$(cd "$(dirname "$_SOURCE_PATH")" 2>/dev/null && pwd || echo "")"
    # Считаем путь валидным только если это корень репозитория server-manager.
    if [ -n "$_CANDIDATE_DIR" ] && \
       [ -f "$_CANDIDATE_DIR/server-manager.sh" ] && \
       [ -f "$_CANDIDATE_DIR/lib/common.sh" ]; then
        SCRIPT_DIR="$_CANDIDATE_DIR"
    fi
fi
export SCRIPT_DIR
REPO_RAW="https://raw.githubusercontent.com/stump3/server-manager/main"
REPO_URL="https://github.com/stump3/server-manager"
INSTALL_DIR="/root/server-manager"

# При запуске через curl | bash — SCRIPT_DIR обычно пустой.
# Если репозиторий уже есть локально, используем его как fallback,
# чтобы не уйти в цикл перезапуска.
if [ -z "$SCRIPT_DIR" ] && [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/server-manager.sh" ]; then
    SCRIPT_DIR="$INSTALL_DIR"
    export SCRIPT_DIR
fi

# Если путь скрипта все еще неизвестен — клонируем репозиторий и перезапускаемся из него.
if [ -z "$SCRIPT_DIR" ]; then
    if [ "${SM_BOOTSTRAP_REEXEC:-0}" = "1" ]; then
        echo "Ошибка: не удалось определить рабочий каталог server-manager после перезапуска."
        echo "Выполните: cd /root/server-manager && git reset --hard origin/main"
        exit 1
    fi
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
    exec env SM_BOOTSTRAP_REEXEC=1 bash "${INSTALL_DIR}/server-manager.sh"
fi

# Страхуемся: файл запуска должен быть исполняемым
chmod +x "${SCRIPT_DIR}/server-manager.sh" 2>/dev/null || true

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
    _sm_source_file "lib/$1.sh"
}

_sm_source_file() {
    local rel_path="$1"
    local mod_key="${rel_path#lib/}"
    mod_key="${mod_key%.sh}"
    local local_path="${SCRIPT_DIR}/${rel_path}"

    if [ -n "$SCRIPT_DIR" ] && [ -f "$local_path" ]; then
        # shellcheck source=/dev/null
        source "$local_path"
        return 0
    fi

    local tmp; tmp=$(mktemp)
    if ! curl -fsSL "${REPO_RAW}/${rel_path}" -o "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "Ошибка загрузки модуля: ${rel_path}"; exit 1
    fi
    # Проверяем SHA256 если задан
    local expected_sha="${_MODULE_SHA256[$mod_key]:-}"
    if [ -n "$expected_sha" ]; then
        local actual_sha; actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
        if [ "$actual_sha" != "$expected_sha" ]; then
            rm -f "$tmp"
            echo "ОШИБКА: SHA256 модуля ${rel_path} не совпадает!"
            echo "  Ожидалось: $expected_sha"
            echo "  Получено:  $actual_sha"
            echo "  Возможна компрометация репозитория. Выполнение прервано."
            exit 1
        fi
    fi
    # shellcheck source=/dev/null
    source "$tmp"
    rm -f "$tmp"
}

_load_module common
_load_module panel
_load_module telemt
_load_module hysteria
_load_module migrate

check_root
main_menu
