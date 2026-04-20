# shellcheck shell=bash
# Hysteria2 loader: подключает модули из lib/hy2/

for _hy2_mod in core install users integration menu; do
    if declare -F _sm_source_file >/dev/null 2>&1; then
        _sm_source_file "lib/hy2/${_hy2_mod}.sh"
    else
        _HY2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/hy2" && pwd)"
        # shellcheck source=/dev/null
        source "${_HY2_DIR}/${_hy2_mod}.sh"
    fi
done
unset _hy2_mod _HY2_DIR
