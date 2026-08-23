# shellcheck shell=bash

# Keep this function's migration logic and its atomic-write pattern
# byte-for-byte in sync with the standalone copy embedded in
# lib/panel/mgmt_script.sh (_migrate_env_for_remnawave_v2). That copy
# is deployed standalone to /usr/local/bin/remnawave_panel and has no
# access to this file at runtime (see mgmt_script.sh's own header
# comment), so true code-sharing isn't reachable without restructuring
# how that script is generated — out of scope here. Contract 8: if you
# change the migration logic or the write pattern here, change it
# there too, or a future contract-8 fix silently only half-lands.
panel_migrate_env_for_remnawave_v2() {
    local env_file="/opt/remnawave/.env"
    [ -f "$env_file" ] || { warn ".env не найден: $env_file"; return 1; }

    local -a sed_args=()
    local secret_action=""
    if grep -q '^JWT_AUTH_SECRET=' "$env_file" && ! grep -q '^APP_SECRET=' "$env_file"; then
        sed_args+=(-e 's/^JWT_AUTH_SECRET=/APP_SECRET=/')
        secret_action="renamed"
    elif grep -q '^JWT_AUTH_SECRET=' "$env_file" && grep -q '^APP_SECRET=' "$env_file"; then
        sed_args+=(-e '/^JWT_AUTH_SECRET=/d')
        secret_action="deduped"
    fi

    local removed=0
    for key in JWT_API_TOKENS_SECRET SWAGGER_PATH SCALAR_PATH IS_DOCS_ENABLED; do
        if grep -q "^${key}=" "$env_file"; then
            sed_args+=(-e "/^${key}=/d")
            removed=1
        fi
    done

    if [ "${#sed_args[@]}" -eq 0 ]; then
        return 0
    fi

    # Atomic prepare -> commit (contract 8): one temp file, one mv, one
    # chmod — same shape as the existing $HYSTERIA_CONFIG precedent
    # (lib/hy2/users.sh), applied once for all pending edits instead of
    # multiple separate in-place sed -i passes.
    local _tmp; _tmp=$(mktemp)
    if sed "${sed_args[@]}" "$env_file" > "$_tmp" \
            && mv "$_tmp" "$env_file" && chmod 600 "$env_file"; then
        [ "$secret_action" = "renamed" ] && ok ".env: JWT_AUTH_SECRET переименован в APP_SECRET"
        [ "$secret_action" = "deduped" ] && ok ".env: удалён дублирующий JWT_AUTH_SECRET"
    else
        rm -f "$_tmp"
        warn ".env: не удалось применить миграцию атомарно"
        return 1
    fi
    [ "$removed" = "1" ] && ok ".env: удалены устаревшие переменные Remnawave"
}
