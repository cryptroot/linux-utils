#!/usr/bin/env bash
#
# WireGuard VPN manager — status display, interface control, and
# diagnostic info in a single entry point.
#
# Usage:
#   system-manager <command> [options]
#
# Commands:
#   status [interface]        Compact one-line status (designed for .bashrc)
#   up [interface]            Bring WireGuard interface up — requires root
#   down [interface]          Bring WireGuard interface down — requires root
#   restart [interface]       Restart WireGuard interface — requires root
#   info [interface]          Verbose connection details
#
# Interface auto-detection:
#   If /etc/wireguard/ contains exactly one .conf file, its name is used
#   automatically. Otherwise the interface must be specified.
#
# Examples:
#   system-manager                  # show WireGuard status
#   system-manager status           # same as above
#   system-manager status wg0       # status for specific interface
#   system-manager up               # bring up default interface
#   system-manager down wg0         # take down wg0
#   system-manager restart          # restart default interface
#   system-manager info             # verbose details for default interface

set -euo pipefail

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
SYM_ERR="✘"
SYM_WARN="⚠"
SYM_LOCK="🔒"
SYM_UNLOCK="🔓"

# ── Logging helpers ──────────────────────────────────────────────────────────

_log()  { echo -e "${GREEN}[+]${NC} $*"; }
_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
_die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
_step() { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

# ── Common checks ───────────────────────────────────────────────────────────

_require_root() {
    [[ "$EUID" -eq 0 ]] || _die "This operation must be run as root."
}

_require_wg() {
    command -v wg &>/dev/null || _die "wireguard-tools is not installed."
}

# ── Interface resolution ────────────────────────────────────────────────────

# Resolve the WireGuard interface name. If the caller supplied one, validate
# it against /etc/wireguard/<name>.conf. Otherwise auto-detect when exactly
# one config exists.
_resolve_iface() {
    local requested="${1:-}"

    if [[ -n "$requested" ]]; then
        if [[ -f "/etc/wireguard/${requested}.conf" ]]; then
            echo "$requested"
            return
        fi
        _die "No config found: /etc/wireguard/${requested}.conf"
    fi

    local -a configs=()
    if [[ -d /etc/wireguard ]]; then
        for f in /etc/wireguard/*.conf; do
            [[ -f "$f" ]] && configs+=("$f")
        done
    fi

    case "${#configs[@]}" in
        0) _die "No WireGuard configs found in /etc/wireguard/" ;;
        1) basename "${configs[0]}" .conf ;;
        *) _die "Multiple configs in /etc/wireguard/ — specify interface: $(printf '%s ' "${configs[@]##*/}")" ;;
    esac
}

# ── Relative-time helper ───────────────────────────────────────────────────

_relative_time() {
    local seconds="$1"
    if   (( seconds < 60 ));    then echo "${seconds}s ago"
    elif (( seconds < 3600 ));  then echo "$(( seconds / 60 ))m ago"
    elif (( seconds < 86400 )); then echo "$(( seconds / 3600 ))h ago"
    else                             echo "$(( seconds / 86400 ))d ago"
    fi
}

# ── Format transfer bytes ──────────────────────────────────────────────────

_format_bytes() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then awk "BEGIN { printf \"%.1f GiB\", $bytes / 1073741824 }"
    elif (( bytes >= 1048576 ));    then awk "BEGIN { printf \"%.1f MiB\", $bytes / 1048576 }"
    elif (( bytes >= 1024 ));       then awk "BEGIN { printf \"%.1f KiB\", $bytes / 1024 }"
    else                                 echo "${bytes} B"
    fi
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_status() {
    local iface="${1:-}"

    # Bail gracefully if wg is not installed (don't break bashrc)
    if ! command -v wg &>/dev/null; then
        return 0
    fi

    # Auto-detect interface silently; bail if none or ambiguous
    if [[ -z "$iface" ]]; then
        local iface_list
        iface_list="$(sudo wg show interfaces 2>/dev/null)" || true
        local -a ifaces
        read -ra ifaces <<< "$iface_list"
        case "${#ifaces[@]}" in
            0) return 0 ;;
            1) iface="${ifaces[0]}" ;;
            *) return 0 ;;  # ambiguous — skip in bashrc context
        esac
    fi

    # Query WireGuard status via sudo (NOPASSWD configured in sudoers)
    local wg_output
    if ! wg_output="$(sudo wg show "$iface" 2>/dev/null)"; then
        echo -e "  ${SYM_UNLOCK} ${BOLD}${iface}${NC}: ${RED}${SYM_ERR} disconnected${NC}"
        return 0
    fi

    if [[ -z "$wg_output" ]]; then
        echo -e "  ${SYM_UNLOCK} ${BOLD}${iface}${NC}: ${RED}${SYM_ERR} disconnected${NC}"
        return 0
    fi

    # Count peers
    local peer_count
    peer_count=$(echo "$wg_output" | grep -c '^peer:' || true)

    # Find most recent handshake across all peers
    local latest_hs=0
    local now
    now=$(date +%s)
    while IFS=$'\t' read -r _ ts; do
        if [[ -n "$ts" ]] && (( ts > latest_hs )); then
            latest_hs=$ts
        fi
    done < <(sudo wg show "$iface" latest-handshakes 2>/dev/null || true)

    local hs_text="no handshake"
    if (( latest_hs > 0 )); then
        local delta=$(( now - latest_hs ))
        hs_text="$(_relative_time $delta)"
    fi

    # Build one-liner
    local peer_label="peer"
    (( peer_count != 1 )) && peer_label="peers"

    echo -e "  ${SYM_LOCK} ${BOLD}${iface}${NC}: ${GREEN}${SYM_OK} connected${NC} (${peer_count} ${peer_label}, ${hs_text})"
}

cmd_up() {
    _require_root
    _require_wg
    local iface
    iface="$(_resolve_iface "${1:-}")"
    _log "Bringing up ${iface}..."
    wg-quick up "$iface"
    _log "${iface} is up"
}

cmd_down() {
    _require_root
    _require_wg
    local iface
    iface="$(_resolve_iface "${1:-}")"
    _log "Bringing down ${iface}..."
    wg-quick down "$iface"
    _log "${iface} is down"
}

cmd_restart() {
    _require_root
    _require_wg
    local iface
    iface="$(_resolve_iface "${1:-}")"
    _log "Restarting ${iface}..."
    wg-quick down "$iface" 2>/dev/null || true
    wg-quick up "$iface"
    _log "${iface} restarted"
}

cmd_info() {
    _require_wg
    local iface
    iface="$(_resolve_iface "${1:-}")"

    _step "WireGuard interface: ${iface}"

    # Full wg show output
    echo ""
    local wg_output
    if wg_output="$(sudo wg show "$iface" 2>/dev/null)" && [[ -n "$wg_output" ]]; then
        echo "$wg_output" | while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
    else
        echo -e "  ${RED}Interface ${iface} is not active${NC}"
        echo ""
        return 0
    fi

    # IP addresses
    echo ""
    _step "IP addresses"
    echo ""
    if ip addr show "$iface" &>/dev/null; then
        ip addr show "$iface" | grep -E '^\s+inet' | while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
    else
        echo -e "  ${DIM}(interface not found in ip addr)${NC}"
    fi

    # Transfer stats per peer
    echo ""
    _step "Transfer statistics"
    echo ""
    local dump
    if dump="$(sudo wg show "$iface" dump 2>/dev/null)"; then
        # Skip header line; fields: public-key preshared-key endpoint allowed-ips latest-handshake transfer-rx transfer-tx persistent-keepalive
        local line_num=0
        while IFS=$'\t' read -r _pubkey _psk endpoint _allowed_ips _hs rx tx _keepalive; do
            (( ++line_num ))
            (( line_num == 1 )) && continue  # skip interface line
            local rx_fmt tx_fmt
            rx_fmt="$(_format_bytes "$rx")"
            tx_fmt="$(_format_bytes "$tx")"
            printf "  ${BOLD}Peer${NC} %.8s…  ${DIM}endpoint${NC} %-21s  ↓ %-10s  ↑ %-10s\n" \
                "$_pubkey" "${endpoint:-(none)}" "$rx_fmt" "$tx_fmt"
        done <<< "$dump"
    fi
    echo ""
}

# ── Usage ───────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: system-manager <command> [interface]"
    echo ""
    echo "Commands:"
    echo "  status [iface]    Compact one-line status (for .bashrc)"
    echo "  up [iface]        Bring interface up (requires root)"
    echo "  down [iface]      Bring interface down (requires root)"
    echo "  restart [iface]   Restart interface (requires root)"
    echo "  info [iface]      Verbose connection details"
    echo ""
    echo "If only one .conf exists in /etc/wireguard/, the interface is"
    echo "detected automatically."
    exit 1
}

# ── Main dispatch ───────────────────────────────────────────────────────────

case "${1:-status}" in
    status)   cmd_status "${2:-}" ;;
    up)       cmd_up "${2:-}" ;;
    down)     cmd_down "${2:-}" ;;
    restart)  cmd_restart "${2:-}" ;;
    info)     cmd_info "${2:-}" ;;
    -h|--help|help) usage ;;
    *)        _die "Unknown command: $1 (try: system-manager --help)" ;;
esac
