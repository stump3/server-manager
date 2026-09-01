#!/bin/bash
# SANDBOX-ONLY test driver, not part of the project. Feeds scripted
# answers to the real cli.sh prompts through a pty so `read ... </dev/tty`
# works in a non-interactive sandbox. Deleted after use.
set -o pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source lib/ui/output.sh
source lib/common.sh
source lib/panel.sh

MODE="" PANEL_DOMAIN="" SUB_DOMAIN="" SELFSTEAL_DOMAIN="" WEB_SERVER=""
CERT_METHOD="" PANEL_CF_EMAIL="" PANEL_CF_KEY="" PANEL_LE_EMAIL="" GCORE_TOKEN=""
TELEMT_ENABLED="" TELEMT_DOMAIN="" TELEMT_PORT=""

panel_cli_select_mode
panel_cli_collect_domains
panel_cli_select_webserver
panel_cli_select_cert
panel_cli_collect_j_options
panel_cli_show_summary "$MODE" "$WEB_SERVER" "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN" \
    "$CERT_METHOD" "$TELEMT_ENABLED" "$TELEMT_DOMAIN" "$TELEMT_PORT"

echo "===RESULT==="
echo "MODE=$MODE"
echo "PANEL_DOMAIN=$PANEL_DOMAIN"
echo "SUB_DOMAIN=$SUB_DOMAIN"
echo "SELFSTEAL_DOMAIN=$SELFSTEAL_DOMAIN"
echo "WEB_SERVER=$WEB_SERVER"
echo "CERT_METHOD=$CERT_METHOD"
echo "TELEMT_ENABLED=$TELEMT_ENABLED"
echo "TELEMT_DOMAIN=$TELEMT_DOMAIN"
echo "TELEMT_PORT=$TELEMT_PORT"
