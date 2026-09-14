# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════
# ЦВЕТА И ОБЩИЕ УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
PURPLE='\033[0;35m'; GRAY='\033[0;90m'; BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'; RESET="$NC"


# Contract 1 (docs/CONTRACTS.md): stdout carries machine-readable return
# data only; stderr carries all UI text, diagnostics, warnings, and
# errors. All of ok/info/warn/die/step/detail write to stderr below.
# F4 (docs/ARCHITECTURE.md §8): err() vs die() — which fatal helper
# survives — resolved as die(); err() has been removed from this file
# and every former call site converted to die() (message text
# unchanged). die() is now the sole canonical fatal helper (exit 1,
# stderr).
ok()      { echo -e "${GREEN}  ✓ $*${NC}" >&2; }
info()    { echo -e "${BLUE}  · $*${NC}" >&2; }
warn()    { echo -e "${YELLOW}  ⚠  $*${NC}" >&2; }
die()     { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
detail()  { echo -e "${GRAY}    $*${NC}" >&2; }

# Шаг установки с прогресс-баром
# Использует STEP_NUM и TOTAL_STEPS если заданы
step() {
    echo "" >&2
    if [ -n "${TOTAL_STEPS:-}" ] && [ "${TOTAL_STEPS:-0}" -gt 0 ]; then
        local _done=$(( STEP_NUM ))
        local _left=$(( TOTAL_STEPS - STEP_NUM ))
        local _bar=""
        local i
        for (( i=0; i<_done; i++ )); do _bar+="●"; done
        for (( i=0; i<_left; i++ )); do _bar+="○"; done
        echo -e "${GRAY}  ${_bar}  ${BOLD}${CYAN}$*${NC}" >&2
    else
        echo -e "${BOLD}${CYAN}  ── $* ──${NC}" >&2
    fi
    echo "" >&2
}
