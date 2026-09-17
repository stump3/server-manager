# shellcheck shell=bash

# ── Автообновление скрипта ────────────────────────────────────────
panel_update_script() {
    header "Обновление скрипта"
    local repo_url="https://raw.githubusercontent.com/stump3/server-manager/main"
    local archive_url="https://github.com/stump3/server-manager/archive/refs/heads/main.tar.gz"
    info "Проверяем обновления..."

    # Получаем версию с GitHub (только loader для проверки версии)
    local tmp_ver; tmp_ver=$(mktemp)
    if ! curl -fsSL "${repo_url}/lib/common.sh" -o "$tmp_ver" 2>/dev/null || [ ! -s "$tmp_ver" ]; then
        rm -f "$tmp_ver"
        warn "Не удалось получить версию с GitHub"
        return 1
    fi

    local remote_ver; remote_ver=$(grep "^SCRIPT_VERSION_STATIC=" "$tmp_ver" | head -1         | sed 's/SCRIPT_VERSION_STATIC=//;s/[^a-zA-Z0-9._-]//g' | tr -d " ")
    rm -f "$tmp_ver"
    local local_ver; local_ver="$SCRIPT_VERSION"

    info "Локальная версия: $local_ver"
    info "Версия на GitHub: ${remote_ver:-неизвестна}"
    echo ""

    if [ -n "$remote_ver" ] && [ "$remote_ver" = "$local_ver" ]; then
        ok "Установлена актуальная версия."
        echo ""
        if ! confirm "Переустановить всё равно?" n; then return; fi
    elif [ -n "$remote_ver" ] && [[ "$local_ver" > "$remote_ver" ]]; then
        warn "Локальная версия новее GitHub."
        echo ""
        if ! confirm "Перезаписать локальную версию версией с GitHub?" n; then return; fi
    else
        if ! confirm "Обновить до ${remote_ver:-последней версии}?" y; then return; fi
    fi

    # SCRIPT_DIR экспортируется из server-manager.sh и всегда указывает на корень репо.
    # Не используем BASH_SOURCE[0] — внутри sourced модуля он указывает на
    # lib/panel/management.sh (после разбиения panel.sh на подмодули).
    local script_path script_dir
    if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR" ]; then
        script_dir="$SCRIPT_DIR"
    else
        # Fallback: идём на три уровня вверх от lib/panel/management.sh
        # (management.sh → lib/panel/ → lib/ → корень репозитория),
        # чтобы script_dir указывал на то же место, что и раньше,
        # когда эта функция жила прямо в lib/panel.sh (там было /lib/../).
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    fi
    script_path="${script_dir}/server-manager.sh"

    info "Скачиваем обновление..."
    local tmp_dir; tmp_dir=$(mktemp -d)

    # Скачиваем полный архив репозитория
    if curl -fsSL "$archive_url" -o "${tmp_dir}/archive.tar.gz" 2>/dev/null; then
        tar -xzf "${tmp_dir}/archive.tar.gz" -C "$tmp_dir" 2>/dev/null
        local extracted; extracted=$(find "$tmp_dir" -maxdepth 1 -type d -name "server-manager-*" | head -1)
        if [ -n "$extracted" ]; then
            # Обновляем loader
            cp "${extracted}/server-manager.sh" "$script_path" && chmod +x "$script_path"

            # Синхронизируем все папки из репозитория кроме служебных
            # Пропускаем: .git, docs (документация не нужна на сервере)
            # Данные и конфиги пользователя (*.toml, *.env, *.json) не трогаем
            local updated_dirs=()
            local dir_name dst_dir src_file rel_path dst_file
            for src_dir in "${extracted}"/*/; do
                dir_name=$(basename "$src_dir")
                # Пропускаем служебные директории
                case "$dir_name" in
                    .git|docs) continue ;;
                esac
                dst_dir="${script_dir}/${dir_name}"
                mkdir -p "$dst_dir"
                # Используем process substitution вместо pipe чтобы избежать subshell
                # find ... | while создаёт subshell — updated_dirs не обновляется
                while IFS= read -r src_file; do
                    rel_path="${src_file#${src_dir}}"
                    dst_file="${dst_dir}/${rel_path}"
                    mkdir -p "$(dirname "$dst_file")"
                    cp "$src_file" "$dst_file"
                done < <(find "$src_dir" -type f)
                updated_dirs+=("$dir_name/")
            done

            [ ${#updated_dirs[@]} -gt 0 ] && ok "Обновлены: ${updated_dirs[*]}"

            # Применяем обновлённые интеграции к установленным сервисам
            local hy_webhook_src="${script_dir}/integrations/hy-webhook.py"
            if [ -f "$hy_webhook_src" ] && [ -f "/opt/hy-webhook/hy-webhook.py" ]; then
                cp "$hy_webhook_src" /opt/hy-webhook/hy-webhook.py
                systemctl restart hy-webhook 2>/dev/null || true
                ok "hy-webhook обновлён и перезапущен"
            fi

            rm -rf "$tmp_dir"

            # Синхронизируем git чтобы версия обновилась
            if [ -d "${script_dir}/.git" ]; then
                git -C "$script_dir" fetch origin --quiet 2>/dev/null || true
                git -C "$script_dir" reset --hard origin/main --quiet 2>/dev/null || true
            fi

            ok "Скрипт обновлён → $script_path"
            warn "Перезапустите: bash $script_path"
            return 0
        fi
    fi

    rm -rf "$tmp_dir"
    warn "Не удалось скачать архив. Попробуйте вручную:"
    info "curl -fsSL $archive_url | tar -xz"
    return 1
}

# ── Переустановка скрипта управления ─────────────────────────────
panel_reinstall_mgmt() {
    header "Переустановить скрипт управления (rp)"

    local pd ck cv mode web_server
    local nc="/opt/remnawave/nginx.conf"
    local cf="/opt/remnawave/Caddyfile"

    if [ -f "$cf" ]; then
        # ── Caddy: извлекаем домен и cookie из Caddyfile ──────────
        web_server="2"
        pd=$(grep -m1 "^https://" "$cf" | sed 's|https://||;s|{.*||;s|{||' | tr -d ' ' | head -1)
        ck=$(grep -oP 'query \K\w+(?==)' "$cf" | head -1)
        cv=$(grep -oP 'query [^=]+=\K\w+' "$cf" | head -1)
    elif [ -f "$nc" ]; then
        # ── Nginx: извлекаем домен и cookie из nginx.conf ─────────
        web_server="1"
        pd=$(grep "server_name " "$nc" | grep -v "hash_bucket\|server_name _" \
            | head -1 | awk '{print $2}' | tr -d ';')
        ck=$(grep "map \$http_cookie" "$nc" -A2 | grep -oP '~\*\K\w+(?==)' | head -1)
        cv=$(grep "map \$http_cookie" "$nc" -A2 | grep -oP '=\K\w+(?=" 1)' | head -1)
    else
        warn "Ни nginx.conf ни Caddyfile не найдены — панель не установлена?"
        return 1
    fi

    # FIXED 2026-08-31: previously a single binary check
    # (`grep -q remnanode` -> "1" else "2"), which cannot tell MODE=1
    # apart from MODE=F/J -- all three are co-located (remnanode always
    # present), so F/J installs silently got mode="1" here. That
    # mattered as of 453973e: do_open_port/do_close_port's MODE=F/J
    # guard in the DEPLOYED script only fires if MODE was baked in
    # correctly by panel_install_mgmt_script -- getting "1" here would
    # silently regenerate the script back into the old, unguarded
    # behavior for an F/J box. Caddy (web_server=2) is untouched: F/J
    # never reaches Caddy at all (rejected upstream by
    # lib/panel/cli.sh:panel_cli_select_webserver() and
    # lib/panel/compose/colocated.sh's own guard), so the plain 1-vs-2
    # check there was never wrong and needs no fingerprinting.
    # For nginx (web_server=1), fingerprint variant_f.sh's/variant_j.sh's
    # own generated markers instead of guessing: F/J's nginx.conf is a
    # full top-level config with its own `stream {` block (MODE=1's
    # nginx.conf -- lib/panel/nginx/config.sh's panel_generate_nginx_config()
    # -- has no stream{} at all, Xray binds public 443 directly).
    #
    # FIXED 2026-09-05 (F+XHTTP audit, Commit 2.G): the old heuristic
    # ("has an `xray_xhttp` upstream" => J) broke the moment F itself
    # could also carry an XHTTP leg (F+XHTTP) -- F's own generator uses a
    # deliberately different upstream name (xray_xhttp_f, see
    # variant_f.sh) specifically to avoid colliding with this grep, but
    # relying on upstream-naming-as-a-contract is fragile by construction,
    # not a real fix. variant_f.sh/variant_j.sh now both emit explicit,
    # stable machine-readable markers
    # ("# SERVER_MANAGER_TOPOLOGY=F|J", "# SERVER_MANAGER_XHTTP=0|1") at
    # the very top of the generated nginx.conf specifically so detection
    # here never again has to infer topology from an incidental upstream
    # name. Markers are checked FIRST; any nginx.conf generated before
    # 2026-09-05 (this fix) has no such marker line and falls through to
    # the original legacy heuristic unchanged, so already-deployed F/J
    # installs remain correctly detected without redeploying anything.
    local _topology_marker
    _topology_marker=$(grep -m1 "^# SERVER_MANAGER_TOPOLOGY=" "$nc" 2>/dev/null | cut -d= -f2)

    if [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnanode" /opt/remnawave/docker-compose.yml; then
        if [ "$web_server" = "1" ] && [ -n "$_topology_marker" ]; then
            mode="$_topology_marker"
        elif [ "$web_server" = "1" ] && grep -q "xray_xhttp" "$nc" 2>/dev/null; then
            # Legacy heuristic (pre-marker configs only, see FIXED above):
            # F+XHTTP could not have existed before this fix, so an
            # unmarked config with an `xray_xhttp` upstream can only be J.
            mode="J"
        elif [ "$web_server" = "1" ] && grep -q "^stream {" "$nc" 2>/dev/null; then
            mode="F"
        else
            mode="1"
        fi
    else
        mode="2"
    fi

    if [ -z "$pd" ] || [ -z "$ck" ] || [ -z "$cv" ]; then
        warn "Не удалось извлечь параметры из конфига веб-сервера"
        info "Домен: '${pd:-не найден}'  Ключ: '${ck:-не найден}'  Значение: '${cv:-не найдено}'"
        return 1
    fi

    info "Домен: $pd  |  Cookie: $ck=$cv  |  Режим: $mode  |  Веб-сервер: $([ "$web_server" = "2" ] && echo Caddy || echo Nginx)"
    echo ""
    if ! confirm "Переустановить /usr/local/bin/remnawave_panel?" y; then
        return
    fi

    panel_install_mgmt_script "$pd" "$ck" "$cv" "$mode" "$web_server"
    ok "Скрипт управления переустановлен. Изменения применены."
    info "Перезапустите терминал или выполните: source /etc/bash.bashrc"
}

# panel_cleanup_xhttp_ufw_rules — removes the F/J XHTTP public-port UFW
# rules this tool may have opened for a PREVIOUS install
# (lib/panel/install.sh's `ufw allow "${_xhttp_ufw_port_desc}/tcp"`,
# gated on core_deployment_has_capability("XHTTP")).
#
# CONFIRMED GAP (this session's UFW lifecycle audit): that rule's own
# add-condition is per-deployment (which topology, whether XHTTP is
# turned on) — unlike 22/tcp, 443/tcp, or Remote Node's 2222/tcp, which
# are unconditional/host-baseline and deliberately left untouched here.
# Neither panel_reinstall() nor panel_remove() previously removed it, so
# switching topology via reinstall (e.g. F+XHTTP -> plain F, or F+XHTTP
# -> J) left a firewall rule open for a port with no listener behind it
# — confirmed by direct reading of both functions (no `ufw` call
# anywhere in this file before this fix).
#
# Both callers wipe /opt/remnawave's .env/docker-compose.yml/nginx.conf
# in the same operation, so by the time this runs, the OLD deployment's
# MODE/XHTTP state can no longer be read back out of them (unlike, say,
# TeleMT's own removal flow in lib/telemt/menu.sh, which greps its port
# out of its config file before deleting it — there is no equivalent
# already-resolved Deployment/MODE lying around here to ask). Since
# lib/core/port_allocation.sh's table only has two possible XHTTP public
# ports at all (F=9443, J=8443 — core_port_allocation_public()), checking
# both unconditionally covers every case without needing to know which
# (if either) applied to the install being torn down.
#
# OWNERSHIP FIX (follow-up UFW-lifecycle audit, same session): the first
# version of this function issued a bare `ufw delete allow "${_p}/tcp"`
# for each candidate port. That is a plain port/proto specification with
# no comment filter, so against a real ufw it deletes *any* existing
# `ALLOW IN <port>/tcp Anywhere` rule regardless of who added it or what
# comment (if any) it carries — it is not scoped to a rule this tool
# itself created. J's own public XHTTP port (8443) is also the literal
# port lib/panel/mgmt_script.sh's do_open_port()/do_close_port() open
# and close for MODE=1/2 emergency admin access
# (`ufw allow 8443/tcp`/`ufw delete allow 8443/tcp`, no comment at all —
# confirmed by direct reading of that file). do_open_port() itself
# refuses to run for MODE=F/J, so that rule can only exist while the
# *current* generated management script's baked-in $MODE is 1 or 2, but
# a firewall rule an admin opened under an earlier MODE=1/2 install
# outlives that script and is still just "ALLOW IN 8443/tcp Anywhere" at
# the ufw level when this function's blind port-only delete runs during
# a later panel_remove()/panel_reinstall() — indistinguishable, by that
# bare spec, from this tool's own XHTTP rule. install.sh already tags
# its own rule for exactly this reason
# (`ufw allow "${_xhttp_ufw_port_desc}/tcp" comment "Variant $MODE
# XHTTP"`); the fix here is to make the delete side actually use that
# existing tag — via `ufw status numbered`'s (read-only) listing — instead
# of introducing any new ownership-tracking mechanism, so an unrelated,
# uncommented same-port rule (mgmt_script.sh's admin rule, or any other
# co-located service's own `allow <port>/tcp`) is left untouched. Safe
# and idempotent either way: no matching numbered line means nothing is
# deleted, the same no-op-on-absent-rule guarantee the original bare
# `ufw delete allow` relied on.
panel_cleanup_xhttp_ufw_rules() {
    command -v ufw &>/dev/null || return 0
    local _p _mode _status _nums _num
    for _mode in F J; do
        # `|| _p=""`, not a bare `&&`/failing assignment: same `set -euo
        # pipefail` (server-manager.sh) hazard as below — a failing
        # command substitution assigned to a local must not abort this
        # function (or, unguarded by either caller, the whole
        # panel_reinstall()/panel_remove() invocation).
        _p="$(core_port_allocation_public "$_mode" "xhttp" 2>/dev/null)" || _p=""
        [ -n "$_p" ] || continue
        _status="$(ufw status numbered 2>/dev/null)" || continue
        # Only rule numbers whose line has BOTH this exact port/tcp AND
        # the exact comment install.sh stamps its own XHTTP rule with
        # ("Variant F XHTTP" / "Variant J XHTTP") — never a bare port
        # match — so a same-port rule with no comment or a different
        # comment (not this tool's own) is never selected. The comment
        # match is anchored ("# Variant $_mode XHTTP", end-of-line, only
        # trailing whitespace allowed after it) rather than a plain
        # substring test: ufw always renders a rule's comment as the
        # last field on its numbered-status line, so this is the actual
        # shape of "this exact comment, nothing else" for that field —
        # a bare substring test would also fire on an unrelated rule
        # whose comment merely happens to contain this text as part of
        # something longer (e.g. "Not Variant J XHTTP", "Variant J
        # XHTTP something"), which is a real, if contrived, adversarial
        # rule this ownership check must not treat as its own. Deleted
        # in descending numeric order so an earlier deletion in the same
        # pass never shifts a still-pending rule number out from under
        # this loop.
        _nums="$(printf '%s\n' "$_status" \
            | grep -F "${_p}/tcp" \
            | grep -E "# Variant ${_mode} XHTTP[[:space:]]*\$" \
            | grep -oE '^\[ *[0-9]+' \
            | grep -oE '[0-9]+' \
            | sort -rn)" || _nums=""
        for _num in $_nums; do
            ufw --force delete "$_num" >/dev/null 2>&1 || true
        done
    done
    return 0
}

# UFW LIFECYCLE FOLLOW-UP (same session as panel_cleanup_xhttp_ufw_rules,
# found while re-auditing this file for other install/reinstall-created
# rules with the same "conditional add, no cleanup" shape): tears down
# the UFW rule lib/panel/api.sh:panel_setup_api() may have opened for a
# co-located deployment's remnanode-to-Panel-API access
# (`ufw allow from 172.30.0.0/16 to any port 2222 proto tcp comment
# "Colocated Node API"`, gated on
# panel_core_reality_needs_2222_ufw_rule() -- true only for MODE=1/F/J,
# never MODE=2). Same shape as the XHTTP gap: neither panel_reinstall()
# nor panel_remove() removed it before this fix -- confirmed by grepping
# this whole repo for "2222" and finding no delete/cleanup call at all.
# Narrower blast radius than XHTTP (scoped to the Docker bridge subnet,
# not a public port), but not zero: Docker's own subnet allocation can
# later reuse 172.30.0.0/16 for an unrelated network, and a stale rule
# would silently grant that network's containers reach to this host's
# :2222 without ever having been the real co-located remnanode.
#
# Same ownership-safe technique as panel_cleanup_xhttp_ufw_rules: reads
# `ufw status numbered` (read-only) and deletes only a rule matching BOTH
# the exact port and the exact comment this tool's own rule carries --
# never a bare port-only spec, so an unrelated/uncommented 2222/tcp rule
# (or one with a different comment) is left untouched. Comment match is
# end-anchored for the same reason the XHTTP cleanup's is: ufw always
# renders a rule's comment as the last field on its numbered-status line.
panel_cleanup_colocated_api_ufw_rule() {
    command -v ufw &>/dev/null || return 0
    local _status _nums _num
    _status="$(ufw status numbered 2>/dev/null)" || return 0
    _nums="$(printf '%s\n' "$_status" \
        | grep -F "2222/tcp" \
        | grep -E "# Colocated Node API[[:space:]]*\$" \
        | grep -oE '^\[ *[0-9]+' \
        | grep -oE '[0-9]+' \
        | sort -rn)" || _nums=""
    for _num in $_nums; do
        ufw --force delete "$_num" >/dev/null 2>&1 || true
    done
    return 0
}

# ── Удаление панели ───────────────────────────────────────────────
panel_remove() {
    header "Удалить панель"
    echo -e "  ${BOLD}1)${RESET} 🗑️   Только скрипт (setup.sh)"
    echo -e "  ${BOLD}2)${RESET} 💣  Скрипт + все данные панели (необратимо!)"
    echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
    echo ""
    local ch; read -rp "  Выбор: " ch < /dev/tty
    case "$ch" in
        1)
            read -rp "  Удалить setup.sh? (y/n): " c < /dev/tty
            [[ "$c" =~ ^[yY]$ ]] || return
            rm -f "$0"
            ok "Скрипт удалён"
            exit 0
            ;;
        2)
            echo ""
            warn "ЭТО УДАЛИТ ВСЕ ДАННЫЕ ПАНЕЛИ, БД, КОНФИГИ!"
            warn "Действие необратимо!"
            echo ""
            read -rp "  Введите 'DELETE' для подтверждения: " c < /dev/tty
            [ "$c" != "DELETE" ] && { info "Отменено"; return; }
            info "Останавливаем контейнеры..."
            cd /opt/remnawave 2>/dev/null && docker compose down -v --rmi all --remove-orphans 2>/dev/null || true
            docker system prune -a --volumes -f >/dev/null 2>&1 || true
            panel_cleanup_xhttp_ufw_rules
            panel_cleanup_colocated_api_ufw_rule
            rm -rf /opt/remnawave
            rm -f "$0"
            ok "Панель и скрипт удалены"
            exit 0
            ;;
        0) return ;;
    esac
}

# ── Переустановка панели ──────────────────────────────────────────
panel_reinstall() {
    header "Переустановить панель"
    echo ""
    warn "ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ: БД, пользователи, конфиги!"
    warn "После переустановки потребуется заново настроить панель."
    echo ""
    read -rp "  Продолжить? Введите 'YES': " c < /dev/tty
    [ "$c" != "YES" ] && { info "Отменено"; return; }
    info "Удаляем старую установку..."
    cd /opt/remnawave 2>/dev/null && docker compose down -v --rmi all --remove-orphans >/dev/null 2>&1 || true
    docker system prune -a --volumes -f >/dev/null 2>&1 || true
    panel_cleanup_xhttp_ufw_rules
    panel_cleanup_colocated_api_ufw_rule
    rm -rf /opt/remnawave
    # server-manager хранится в /root/server-manager — он НЕ в /opt/remnawave,
    # поэтому удалять его не нужно. Симлинк /usr/local/bin/server-manager
    # и alias 'rp' восстанавливаются вызовом panel_install.
    ok "Старая установка удалена"
    info "Запускаем установку заново..."
    panel_install
}

panel_update_installed() {
    header "Remnawave Panel — Обновить"
    [ -x "$PANEL_MGMT_SCRIPT" ] || { warn "Панель не установлена."; return 1; }

    warn "Если панель уже стоит на 2.8.1 или ниже, перед обновлением нужен бэкап и миграция .env."
    "$PANEL_MGMT_SCRIPT" backup || warn "Бэкап через rp завершился с предупреждениями — проверьте вывод выше"
    panel_migrate_env_for_remnawave_v2 || return 1
    "$PANEL_MGMT_SCRIPT" update
}
