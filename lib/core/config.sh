# shellcheck shell=bash
# Shared immutable configuration for server-manager.
#
# Keep only values that are intentionally shared between modules here.
# Function-local state, generated .env keys, secrets and subprocess-only
# environment variables must stay close to their owner.

# Remnawave panel paths/API.
PANEL_DIR="/opt/remnawave"
PANEL_NGINX_DIR="/opt/nginx"
PANEL_TOKEN_FILE="${PANEL_DIR}/.panel_token"
PANEL_API="http://127.0.0.1:3000"
PANEL_MGMT_SCRIPT="/usr/local/bin/remnawave_panel"

# Hysteria2 paths/service.
HYSTERIA_DIR="/etc/hysteria"
HYSTERIA_CONFIG="${HYSTERIA_DIR}/config.yaml"
HYSTERIA_SVC="hysteria-server"

# Telemt paths/API.
TELEMT_BIN="/usr/local/bin/telemt"
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG_SYSTEMD="${TELEMT_CONFIG_DIR}/telemt.toml"
TELEMT_WORK_DIR_SYSTEMD="/opt/telemt"
TELEMT_TLSFRONT_DIR="${TELEMT_WORK_DIR_SYSTEMD}/tlsfront"
TELEMT_SERVICE_FILE="/etc/systemd/system/telemt.service"
TELEMT_WORK_DIR_DOCKER="${HOME}/mtproxy"
TELEMT_CONFIG_DOCKER="${TELEMT_WORK_DIR_DOCKER}/telemt.toml"
TELEMT_COMPOSE_FILE="${TELEMT_WORK_DIR_DOCKER}/docker-compose.yml"
TELEMT_GITHUB_REPO="telemt/telemt"
TELEMT_API_URL="http://127.0.0.1:9091/v1/users"
