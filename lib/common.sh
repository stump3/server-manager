# shellcheck shell=bash
# Common loader: подключает модули из lib/common/
#
# Реализация вынесена в подмодули lib/common/{core,generators,network,ssh,menu}.sh.
# core.sh загружается первым — там set -euo pipefail, DEBIAN_FRONTEND,
# SCRIPT_VERSION*/TELEMT_* глобальные переменные, используемые остальными
# подмодулями и остальными доменами приложения.
#
# Поддерживаются оба способа загрузки (см. lib/hysteria.sh, lib/telemt.sh):
#   1. _load_module common (обычный путь из server-manager.sh, есть _sm_source_file)
#   2. прямой source lib/common.sh (BASH_SOURCE fallback)

for _common_mod in core generators network ssh menu; do
    if declare -F _sm_source_file >/dev/null 2>&1; then
        _sm_source_file "lib/common/${_common_mod}.sh"
    else
        _COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/common" && pwd)"
        # shellcheck source=/dev/null
        source "${_COMMON_DIR}/${_common_mod}.sh"
    fi
done
unset _common_mod _COMMON_DIR
