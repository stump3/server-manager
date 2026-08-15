# shellcheck shell=bash

# ── Selfsteal шаблоны ─────────────────────────────────────────────
panel_template_menu() {
    while true; do
        clear
        header "Selfsteal — шаблон сайта"
        echo -e "  ${BOLD}1)${RESET} 🎲  Случайный шаблон"
        echo -e "  ${BOLD}2)${RESET} 🌐  Simple web templates"
        echo -e "  ${BOLD}3)${RESET} 🔷  SNI templates"
        echo -e "  ${BOLD}4)${RESET} ⬜  Nothing SNI"
        echo -e "  ${BOLD}0)${RESET} ◀️  Назад"
        echo ""
        local ch; read -rp "  Выбор: " ch < /dev/tty
        case "$ch" in
            1) panel_install_template "" || true ;;
            2) panel_install_template "simple" || true ;;
            3) panel_install_template "sni" || true ;;
            4) panel_install_template "nothing" || true ;;
            0) return ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

panel_install_template() {
    local src="$1"
    local urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )
    local selected_url
    case "$src" in
        "simple")  selected_url="${urls[0]}" ;;
        "sni")     selected_url="${urls[1]}" ;;
        "nothing") selected_url="${urls[2]}" ;;
        *)
            local idx; idx=$(python3 -c "import random; print(random.randrange(3))" 2>/dev/null || echo "$((RANDOM % 3))")
            selected_url="${urls[$idx]}"
            ;;
    esac
    info "Скачиваем шаблон..."
    cd /opt/ || return 1
    rm -f main.zip
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main
    wget -q --timeout=30 "$selected_url" -O main.zip || { err "Ошибка загрузки"; return 1; }
    unzip -o main.zip &>/dev/null || { err "Ошибка распаковки"; return 1; }
    rm -f main.zip
    local dir template
    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        dir="simple-web-templates-main"
        cd "$dir" && rm -rf assets .gitattributes README.md _config.yml 2>/dev/null
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path .)
        local _tidx; _tidx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#templates[@]}" 2>/dev/null || echo "0")
        template="${templates[$_tidx]}"
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        dir="nothing-sni-main"
        cd "$dir" && rm -rf .github README.md 2>/dev/null
        template="$((RANDOM % 8 + 1)).html"
    else
        dir="sni-templates-main"
        cd "$dir" && rm -rf assets README.md index.html 2>/dev/null
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path .)
        local _tidx; _tidx=$(python3 -c "import random,sys; print(random.randrange(int(sys.argv[1])))" "${#templates[@]}" 2>/dev/null || echo "0")
        template="${templates[$_tidx]}"
    fi
    # Рандомизация HTML
    local rand_id; rand_id=$(openssl rand -hex 8)
    local rand_title="Page_$(openssl rand -hex 4)"
    find "./$template" -type f -name "*.html" -exec sed -i         -e "s|<title>.*</title>|<title>${rand_title}</title>|"         -e "s/<\/head>/<meta name="page-id" content="${rand_id}">
<\/head>/"         {} \; 2>/dev/null || true
    # Копируем в /var/www/html
    mkdir -p /var/www/html
    rm -rf /var/www/html/*
    if [ -d "./$template" ]; then
        cp -a "./$template"/. /var/www/html/
    elif [ -f "./$template" ]; then
        cp "./$template" /var/www/html/index.html
    fi
    cd /opt/
    rm -rf simple-web-templates-main sni-templates-main nothing-sni-main
    ok "Шаблон установлен: $template"
    read -rp "Enter..." < /dev/tty
}
