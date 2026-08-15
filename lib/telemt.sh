# shellcheck shell=bash
# Telemt loader: подключает модули из lib/telemt/
#
# Реализация вынесена в подмодули lib/telemt/{core,install,api,users,menu,migrate}.sh.
# core.sh загружается первым — там объявлены глобальные TELEMT_* переменные,
# используемые остальными подмодулями.
#
# Поддерживаются оба способа загрузки (см. lib/hysteria.sh):
#   1. _load_module telemt (обычный путь из server-manager.sh, есть _sm_source_file)
#   2. прямой source lib/telemt.sh (BASH_SOURCE fallback)

for _telemt_mod in core install api users menu migrate; do
    if declare -F _sm_source_file >/dev/null 2>&1; then
        _sm_source_file "lib/telemt/${_telemt_mod}.sh"
    else
        _TELEMT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/telemt" && pwd)"
        # shellcheck source=/dev/null
        source "${_TELEMT_DIR}/${_telemt_mod}.sh"
    fi
done
unset _telemt_mod _TELEMT_DIR
