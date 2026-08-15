# shellcheck shell=bash

panel_migrate_env_for_remnawave_v2() {
    local env_file="/opt/remnawave/.env"
    [ -f "$env_file" ] || { warn ".env не найден: $env_file"; return 1; }

    if grep -q '^JWT_AUTH_SECRET=' "$env_file" && ! grep -q '^APP_SECRET=' "$env_file"; then
        sed -i 's/^JWT_AUTH_SECRET=/APP_SECRET=/' "$env_file"
        ok ".env: JWT_AUTH_SECRET переименован в APP_SECRET"
    elif grep -q '^JWT_AUTH_SECRET=' "$env_file" && grep -q '^APP_SECRET=' "$env_file"; then
        sed -i '/^JWT_AUTH_SECRET=/d' "$env_file"
        ok ".env: удалён дублирующий JWT_AUTH_SECRET"
    fi

    local removed=0
    for key in JWT_API_TOKENS_SECRET SWAGGER_PATH SCALAR_PATH IS_DOCS_ENABLED; do
        if grep -q "^${key}=" "$env_file"; then
            sed -i "/^${key}=/d" "$env_file"
            removed=1
        fi
    done
    [ "$removed" = "1" ] && ok ".env: удалены устаревшие переменные Remnawave"
}
