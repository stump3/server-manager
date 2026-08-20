# shellcheck shell=bash
# ███████████████████  PANEL SECTION  ██████████████████████████████
# ═══════════════════════════════════════════════════════════════════
#
# Этот файл — loader. Реализация панели разбита на подмодули в
# lib/panel/{core,cert,install,compose,nginx/config,caddy/config,node/compose,node/api,node/install,management,warp,subpage,template,migrate,menu}.sh
#
# Поддерживаются оба способа загрузки:
#   1. _sm_source_file / _load_module panel  (обычный путь из server-manager.sh,
#      SCRIPT_DIR уже выставлен, source идёт по абсолютному пути)
#   2. прямой `source lib/panel.sh` из lib/migrate.sh (относительный путь,
#      SCRIPT_DIR может быть не выставлен) — см. panel_migrate() в migrate.sh
#
# В обоих случаях путь к подмодулям вычисляется от BASH_SOURCE[0] этого
# файла, а не от SCRIPT_DIR, чтобы loader работал одинаково в обоих случаях.

_PANEL_MODULE_DIR="$(dirname "${BASH_SOURCE[0]}")/panel"

for _panel_module in core cert install compose nginx/config caddy/config node/compose node/api node/install management warp subpage template migrate menu; do
    # shellcheck source=/dev/null
    source "${_PANEL_MODULE_DIR}/${_panel_module}.sh"
done

unset _panel_module _PANEL_MODULE_DIR
