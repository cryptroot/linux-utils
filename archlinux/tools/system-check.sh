#!/usr/bin/env bash
#
# One-shot system health dashboard.
# Displays: disk usage per mount, SMART status, failed systemd units,
# recent high-priority journal errors (24h), and btrfs device stats.
#
# No arguments — just run and read.

set -uo pipefail

# ── Colours & symbols ────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

SYM_OK="✔"
SYM_WARN="⚠"
SYM_ERR="✘"

# ── Helpers ──────────────────────────────────────────────────────────────────

_header() {
    printf "\n  ${BOLD}${MAGENTA}%s${NC}\n" "$1"
}

_ok()   { printf "  ${GREEN}${SYM_OK} %s${NC}\n" "$1"; }
_warn() { printf "  ${YELLOW}${SYM_WARN} %s${NC}\n" "$1"; }
_err()  { printf "  ${RED}${SYM_ERR} %s${NC}\n" "$1"; }
_dim()  { printf "  ${DIM}%s${NC}\n" "$1"; }

_bar() {
    local pct=$1 width=20
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local colour="$GREEN"
    (( pct >= 80 )) && colour="$YELLOW"
    (( pct >= 95 )) && colour="$RED"
    printf "${colour}"
    printf '█%.0s' $(seq 1 "$filled" 2>/dev/null) || true
    printf "${DIM}"
    printf '░%.0s' $(seq 1 "$empty" 2>/dev/null) || true
    printf "${NC}"
}

# ── Disk Usage ───────────────────────────────────────────────────────────────

_disk_usage() {
    _header "Disk Usage"
    while IFS= read -r line; do
        local fs mount size used avail pct_raw pct
        read -r fs size used avail pct_raw mount <<< "$line"
        pct="${pct_raw%%%}"
        printf "    %-20s %6s / %6s  " "$mount" "$used" "$size"
        _bar "$pct"
        printf "  %3s%%\n" "$pct"
    done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x efivarfs 2>/dev/null | tail -n +2 | sort -k6)
}

# ── SMART Status ─────────────────────────────────────────────────────────────

_smart_status() {
    _header "SMART Status"

    if ! command -v smartctl &>/dev/null; then
        _warn "smartctl not installed"
        read -rp "    Install smartmontools? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo pacman -S --needed smartmontools
        else
            return
        fi
    fi

    local found=false
    while IFS= read -r dev; do
        found=true
        local name model status
        name=$(basename "$dev")
        model=$(lsblk -ndo MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//')
        [[ -z "$model" ]] && model="$dev"

        if smartctl -H "$dev" &>/dev/null; then
            local result
            result=$(smartctl -H "$dev" 2>/dev/null | grep -i "result\|status" | head -1)
            if echo "$result" | grep -qi "PASSED\|OK"; then
                printf "    ${GREEN}${SYM_OK}${NC} %-12s ${DIM}%s${NC}\n" "$name" "$model"
            else
                printf "    ${RED}${SYM_ERR}${NC} %-12s ${DIM}%s${NC}  %s\n" "$name" "$model" "$result"
            fi
        else
            printf "    ${YELLOW}${SYM_WARN}${NC} %-12s ${DIM}%s  (cannot read SMART — try with sudo)${NC}\n" "$name" "$model"
        fi
    done < <(lsblk -dnpo NAME -e 7,11 2>/dev/null)

    [[ "$found" == false ]] && _dim "No drives detected"
}

# ── Failed Systemd Units ────────────────────────────────────────────────────

_failed_units() {
    _header "Systemd Units"

    local failed
    failed=$(systemctl --no-legend --plain list-units --state=failed 2>/dev/null) || true

    if [[ -z "$failed" ]]; then
        _ok "No failed units"
        return
    fi

    local count
    count=$(echo "$failed" | wc -l)
    _err "$count failed unit(s)"

    while IFS= read -r line; do
        local unit
        unit=$(awk '{print $1}' <<< "$line")
        printf "    ${RED}●${NC} %s\n" "$unit"
    done <<< "$failed"
}

# ── Journal Errors (last 24h) ───────────────────────────────────────────────

_journal_errors() {
    _header "Journal Errors (24h)"

    local errors
    errors=$(journalctl --no-pager -p err --since "24 hours ago" -o short-monotonic --no-hostname 2>/dev/null | tail -n +1) || true

    if [[ -z "$errors" ]]; then
        _ok "No high-priority errors"
        return
    fi

    local count
    count=$(echo "$errors" | wc -l)
    _warn "$count error(s) in the last 24 hours"

    # Show the last 15 unique messages
    echo "$errors" | awk '{$1=$2=""; print substr($0,3)}' \
        | sort -u | tail -15 | while IFS= read -r msg; do
        printf "    ${DIM}%s${NC}\n" "$msg"
    done

    (( count > 15 )) && _dim "    … run 'journalctl -p err --since \"24 hours ago\"' for full output"
}

# ── Btrfs Device Stats ──────────────────────────────────────────────────────

_btrfs_stats() {
    # Deduplicate by device (strip [/@subvol] suffix), use --list to avoid tree chars
    local btrfs_mounts
    btrfs_mounts=$(findmnt -t btrfs -n --list -o SOURCE,TARGET 2>/dev/null \
        | awk '{dev=$1; sub(/\[.*/, "", dev); if (!seen[dev]++) print $2}') || true

    [[ -z "$btrfs_mounts" ]] && return

    _header "Btrfs Device Stats"

    while IFS= read -r mount; do
        local stats
        stats=$(btrfs device stats "$mount" 2>&1) || {
            printf "    ${YELLOW}${SYM_WARN}${NC} %-20s ${DIM}(%s)${NC}\n" "$mount" "$stats"
            continue
        }

        local nonzero
        nonzero=$(echo "$stats" | awk -F' ' '$NF != "0"') || true

        if [[ -z "$nonzero" ]]; then
            printf "    ${GREEN}${SYM_OK}${NC} %s\n" "$mount"
        else
            printf "    ${RED}${SYM_ERR}${NC} %s\n" "$mount"
            while IFS= read -r errline; do
                printf "      ${RED}%s${NC}\n" "$errline"
            done <<< "$nonzero"
        fi
    done <<< "$btrfs_mounts"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    printf "\n  ${BOLD}${WHITE}┌─────────────────────────────┐${NC}"
    printf "\n  ${BOLD}${WHITE}│     System Health Check     │${NC}"
    printf "\n  ${BOLD}${WHITE}└─────────────────────────────┘${NC}\n"

    _disk_usage
    _smart_status
    _failed_units
    _journal_errors
    _btrfs_stats

    printf "\n"
}

main
