# shellcheck shell=bash
# lib/cli/router.sh — transitional CLI boundary.
#
# Единая точка входа между bootstrap (server-manager.sh) и существующим UI.
# На этом этапе НЕ меняет поведение: просто делегирует в main_menu(),
# которая пока остаётся в lib/common.sh.
#
# Требует, чтобы к моменту вызова cli_run уже были загружены все модули,
# от которых зависит main_menu() (common, panel, telemt, hysteria, migrate).
# server-manager.sh должен загружать этот файл последним, после всех
# domain-модулей.

cli_run() {
    main_menu
}
