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
        cv=$(grep "map \$http_cookie" "$nc" -A2 | grep -oP '=\K\w+(?= 1)' | head -1)
    else
        warn "Ни nginx.conf ни Caddyfile не найдены — панель не установлена?"
        return 1
    fi

    # Определение MODE: наличие remnanode отличает co-located (1/F/J) от
    # remote (2) — это было верно и раньше. Но раньше ЛЮБОЙ co-located
    # результат безусловно записывался как "1", хотя F и J тоже
    # co-located и тоже содержат remnanode в docker-compose.yml — то есть
    # переустановка management-скрипта для сервера с MODE=F или MODE=J
    # молча воспринимала его как MODE=1. Среди co-located вариантов
    # 1/F/J различаются по форме самого nginx.conf (подтверждено на
    # реально сгенерированных конфигах всех трёх вариантов):
    #   MODE=1 — обычный conf.d-стиль, нет top-level `stream {`, нет
    #            апстрима "xray_xhttp" (lib/panel/nginx/config.sh)
    #   MODE=F — top-level `stream {` (SNI-роутинг на REALITY), но без
    #            "xray_xhttp" — у F нет XHTTP inbound вообще
    #            (lib/panel/nginx/variant_f.sh)
    #   MODE=J — top-level `stream {` И апстрим "xray_xhttp"
    #            (lib/panel/nginx/variant_j.sh)
    # Только для Caddy (web_server=2, нет nginx.conf) фингерпринт не
    # нужен и не применяется — MODE=F/J сейчас не поддерживают Caddy
    # вообще (см. lib/panel/cli.sh / compose/colocated.sh), так что
    # Caddy-ветка остаётся 1/2-only, как и раньше.
    if [ -f /opt/remnawave/docker-compose.yml ] && grep -q "remnanode" /opt/remnawave/docker-compose.yml; then
        if [ "$web_server" = "1" ] && grep -q "^stream {" "$nc" 2>/dev/null; then
            if grep -q "xray_xhttp" "$nc" 2>/dev/null; then
                mode="J"
            else
                mode="F"
            fi
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
