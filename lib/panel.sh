# shellcheck shell=bash
# ███████████████████  PANEL SECTION  ██████████████████████████████
# ═══════════════════════════════════════════════════════════════════
#
# Этот файл — loader. Реализация панели разбита на подмодули в
# lib/panel/{core,cert,install,compose,compose/common,compose/colocated,compose/remote,mgmt_script,api,selfsteal,nginx/config,nginx/variant_f,nginx/variant_j,xray/templates/render,caddy/config,node/compose,node/api,node/install,management,warp,subpage,template,migrate,menu}.sh
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

# nginx/variant_f и nginx/variant_j добавлены 2026-08-31: до этого
# panel_generate_nginx_config_f() дублировалась (byte-for-byte идентичной
# копией) в nginx/config.sh, а lib/panel/nginx/variant_f.sh не был здесь
# подключён вообще — то есть определение из variant_f.sh было мёртвым
# кодом, а реально вызывалась копия из config.sh (см. отчёт о carve-out
# F/J). Порядок относительно nginx/config не важен — bash просто
# определяет функции при source, а panel_generate_webserver_config()
# (в config.sh) вызывает panel_generate_nginx_config_f/_j только во
# время установки, когда все модули уже загружены — но variant_f/variant_j
# перечислены сразу после nginx/config для наглядности (все три файла
# про nginx-топологию идут подряд).
#
# xray/templates/render добавлен 2026-08-31: panel_xray_render_inbounds()
# (lib/panel/xray/templates/render.sh) была написана и вручную протестирована
# раньше, но НЕ была подключена ни в этот loader, ни в один другой файл —
# grep по всему дереву (кроме самого render.sh) не находил ни одного вызова
# и ни одного `source`. То есть функция физически не существовала в рантайме
# ни при одной установке до этого коммита; api.sh продолжал использовать
# свои старые inline `jq -n` блоки. См. api.sh: panel_setup_api() теперь
# вызывает panel_xray_render_inbounds() напрямую вместо дублирования JSON.
for _panel_module in core cert install compose/common compose/colocated compose/remote compose mgmt_script api selfsteal nginx/config nginx/variant_f nginx/variant_j xray/templates/render caddy/config node/compose node/api node/install management warp subpage template migrate menu; do
    # shellcheck source=/dev/null
    source "${_PANEL_MODULE_DIR}/${_panel_module}.sh"
done

unset _panel_module _PANEL_MODULE_DIR
