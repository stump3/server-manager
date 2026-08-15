# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════
# ЦВЕТА И ОБЩИЕ УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
PURPLE='\033[0;35m'; GRAY='\033[0;90m'; BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'; RESET="$NC"


ok()      { echo -e "${GREEN}  ✓ $*${NC}"; }
info()    { echo -e "${BLUE}  · $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()     { echo -e "\n${RED}  ✗  $*${NC}\n"; exit 1; }
die()     { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
detail()  { echo -e "${GRAY}    $*${NC}"; }

# Шаг установки с прогресс-баром
# Использует STEP_NUM и TOTAL_STEPS если заданы
step() {
    echo ""
    if [ -n "${TOTAL_STEPS:-}" ] && [ "${TOTAL_STEPS:-0}" -gt 0 ]; then
        local _done=$(( STEP_NUM ))
        local _left=$(( TOTAL_STEPS - STEP_NUM ))
        local _bar=""
        local i
        for (( i=0; i<_done; i++ )); do _bar+="●"; done
        for (( i=0; i<_left; i++ )); do _bar+="○"; done
        echo -e "${GRAY}  ${_bar}  ${BOLD}${CYAN}$*${NC}"
    else
        echo -e "${BOLD}${CYAN}  ── $* ──${NC}"
    fi
    echo ""
}
