#!/usr/bin/env bash
#
# Arch Linux update manager — status display, automated upgrades, and
# systemd timer management in a single entry point.
#
# Consolidates the former update.sh (arch-update) and update-check.sh scripts.
#
# Usage:
#   update-manager <command> [options]
#
# Commands:
#   status [--verbose|--pending]   Pretty status display (for .bashrc)
#   run                            Execute update cycle — requires root
#   schedule enable                Write systemd units + enable timer — requires root
#   schedule disable               Stop + disable + remove units — requires root
#   schedule set <oncalendar>      Change timer schedule — requires root
#   schedule status                Show current timer state + next/last fire time
#
# Examples:
#   update-manager                          # show last update status
#   update-manager status                   # same as above
#   update-manager status --verbose         # status + pending updates
#   update-manager run                      # run full update cycle
#   update-manager schedule enable          # install and start timer
#   update-manager schedule set "04:00"     # change schedule to 4 AM
#   update-manager schedule status          # show timer info

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

LOG="/var/log/update-manager.log"
LOG_FALLBACK="/var/log/arch-update.log"
CONF_FILE="/etc/update-manager.conf"
NOTIFY_USER="__NOTIFY_USER__"

SERVICE_NAME="update-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

OLD_SERVICE_NAME="arch-update"
OLD_SERVICE_FILE="/etc/systemd/system/${OLD_SERVICE_NAME}.service"
OLD_TIMER_FILE="/etc/systemd/system/${OLD_SERVICE_NAME}.timer"

DEFAULT_CRITICAL_PKGS="linux|linux-lts|linux-zen|linux-hardened|glibc|systemd|systemd-libs"
DEFAULT_ONCALENDAR="daily"

LOG_START="=== Starting daily update ==="
LOG_COMPLETE="=== Update complete ==="
LOG_DEFERRED="=== Update deferred ==="
LOG_FAILED="=== Update failed ==="

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
SYM_DEFER="⏸"
SYM_PKG="📦"
SYM_UP="⬆"
SYM_TIME="🕐"

# ── Logging helpers ──────────────────────────────────────────────────────────

_log()  { echo -e "${GREEN}[+]${NC} $*"; }
_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
_die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
_step() { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

# Timestamped log (for cmd_run — appends to LOG)
_tlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ── Common checks ───────────────────────────────────────────────────────────

_require_root() {
    [[ "$EUID" -eq 0 ]] || _die "This operation must be run as root."
}

# ── Configuration ───────────────────────────────────────────────────────────

_load_config() {
    if [[ -f "$CONF_FILE" ]]; then
        local _conf_owner _conf_mode
        _conf_owner=$(stat -c '%U' "$CONF_FILE" 2>/dev/null || echo "unknown")
        _conf_mode=$(stat -c '%a' "$CONF_FILE" 2>/dev/null || echo "777")
        if [[ "$_conf_owner" != "root" || $(( 0${_conf_mode} & 0022 )) -ne 0 ]]; then
            echo "[WARNING] $CONF_FILE has unsafe ownership/permissions (owner=${_conf_owner}, mode=${_conf_mode}) — skipping" >&2
        else
            # shellcheck source=/dev/null
            source "$CONF_FILE"
        fi
    fi
    CRITICAL_PKGS="${CRITICAL_PKGS:-$DEFAULT_CRITICAL_PKGS}"
    REFLECTOR_COUNTRY="${REFLECTOR_COUNTRY:-}"

    # Validate CRITICAL_PKGS is a well-formed ERE — a malformed pattern would cause
    # grep to fail silently, making the script skip deferral and auto-upgrade
    # critical packages (kernel, glibc, systemd).
    local _rc=0
    echo "test" | grep -Ew "$CRITICAL_PKGS" >/dev/null 2>&1 || _rc=$?
    if [[ "$_rc" -eq 2 ]]; then
        echo "[WARNING] CRITICAL_PKGS is not a valid ERE pattern ('$CRITICAL_PKGS') — falling back to default" >&2
        CRITICAL_PKGS="$DEFAULT_CRITICAL_PKGS"
    fi
}

# ── Shared helpers ──────────────────────────────────────────────────────────

_relative_time() {
    local ts="$1"
    local epoch_ts epoch_now diff
    epoch_ts=$(date -d "$ts" '+%s' 2>/dev/null) || return
    epoch_now=$(date '+%s')
    diff=$(( epoch_now - epoch_ts ))

    if   (( diff < 60 ));     then echo "just now"
    elif (( diff < 3600 ));   then echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 ));  then echo "$(( diff / 3600 ))h ago"
    elif (( diff < 604800 )); then echo "$(( diff / 86400 ))d ago"
    else echo "$(( diff / 604800 ))w ago"
    fi
}

_format_size() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then awk "BEGIN{printf \"%.1f GB\", $bytes/1073741824}"
    elif (( bytes >= 1048576 ));    then awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
    elif (( bytes >= 1024 ));       then awk "BEGIN{printf \"%.1f KB\", $bytes/1024}"
    else printf "%d B" "$bytes"
    fi
}

_resolve_notify_user() {
    if command -v loginctl &>/dev/null; then
        local session_id _rest type username
        while read -r session_id _rest; do
            type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || true)
            if [[ "$type" =~ ^(x11|wayland|mir)$ ]]; then
                username=$(loginctl show-session "$session_id" -p Name --value 2>/dev/null || true)
                if [[ -n "$username" ]]; then
                    echo "$username"
                    return
                fi
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null)
    fi
    echo "$NOTIFY_USER"
}

_notify() {
    local urgency="$1" summary="$2" body="$3"
    local target_user
    target_user=$(_resolve_notify_user)
    if [[ -n "$target_user" ]] && command -v sudo &>/dev/null && command -v notify-send &>/dev/null; then
        local uid
        uid=$(id -u "$target_user" 2>/dev/null) || true
        if [[ -n "$uid" ]]; then
            local env_vars=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus")
            if [[ -S "/run/user/${uid}/wayland-0" ]]; then
                env_vars+=("WAYLAND_DISPLAY=wayland-0" "XDG_RUNTIME_DIR=/run/user/${uid}")
            else
                env_vars+=("DISPLAY=:0")
            fi
            sudo -u "$target_user" env "${env_vars[@]}" \
                notify-send --urgency="$urgency" "$summary" "$body" 2>/dev/null || true
        fi
    fi
    _tlog "NOTIFY [$urgency]: $summary — $body"
}

# ── Log session parsing ─────────────────────────────────────────────────────

_resolve_log() {
    # Use primary log; fall back to legacy log from arch-update
    if [[ -r "$LOG" ]]; then
        echo "$LOG"
    elif [[ -r "$LOG_FALLBACK" ]]; then
        echo "$LOG_FALLBACK"
    else
        return 1
    fi
}

_parse_last_session() {
    local log_file
    log_file=$(_resolve_log) || return 1

    local last_start last_ts outcome pkg_count critical_names
    local aur_status snapshot_info

    last_start=$(grep -n "$LOG_START" "$log_file" | tail -1 | cut -d: -f1)
    [[ -z "$last_start" ]] && return 1

    local session
    session=$(tail -n +"$last_start" "$log_file")

    last_ts=$(echo "$session" | head -1 | grep -oP '^\[\K[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')

    if echo "$session" | grep -q "$LOG_COMPLETE"; then
        outcome="complete"
    elif echo "$session" | grep -q "$LOG_DEFERRED"; then
        outcome="deferred"
    elif echo "$session" | grep -q "$LOG_FAILED"; then
        outcome="failed"
    elif echo "$session" | grep -q "System is up to date"; then
        outcome="up-to-date"
    else
        outcome="in-progress"
    fi

    pkg_count=$(echo "$session" | grep -oP 'Pending updates \(\K[0-9]+' | head -1) || true
    critical_names=$(echo "$session" | grep -oP 'Critical: \K[^.]+' | head -1) || true

    if echo "$session" | grep -q "AUR packages updated successfully"; then
        aur_status="ok"
    elif echo "$session" | grep -q "AUR update failed"; then
        aur_status="failed"
    else
        aur_status=""
    fi

    snapshot_info=$(echo "$session" | grep -oP 'Pre-upgrade snapshot #\K[0-9]+' | head -1) || true

    _LAST_TS="$last_ts"
    _LAST_OUTCOME="$outcome"
    _LAST_PKG_COUNT="${pkg_count:-0}"
    _LAST_CRITICAL="${critical_names:-}"
    _LAST_AUR="$aur_status"
    _LAST_SNAP="${snapshot_info:-}"
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: update-manager <command> [options]

Commands:
  status [--verbose|--pending]    Pretty status display (default)
  run                             Execute update cycle (requires root)
  schedule enable                 Write systemd units + enable timer (requires root)
  schedule disable                Stop + disable + remove units (requires root)
  schedule set <oncalendar>       Change timer schedule (requires root)
  schedule status                 Show current timer state + next/last fire time

Options:
  -h, --help                      Show this help message

Examples:
  update-manager                          # show last update status
  update-manager status --verbose         # status + pending updates
  update-manager run                      # run full update cycle
  update-manager schedule enable          # install and start timer
  update-manager schedule set "04:00"     # change schedule to 4 AM daily
  update-manager schedule status          # show timer info
EOF
    exit 0
}

# ── cmd_status ───────────────────────────────────────────────────────────────

_show_last_update() {
    if ! _parse_last_session; then
        printf "  ${DIM}No update history found${NC}\n"
        return
    fi

    local rel_time icon colour status_text
    rel_time=$(_relative_time "$_LAST_TS")

    case "$_LAST_OUTCOME" in
        complete)
            icon="$SYM_OK"    colour="$GREEN"  status_text="Upgrade complete"
            ;;
        deferred)
            icon="$SYM_DEFER" colour="$YELLOW" status_text="Deferred (manual upgrade required)"
            ;;
        failed)
            icon="$SYM_ERR"   colour="$RED"    status_text="Upgrade failed"
            ;;
        up-to-date)
            icon="$SYM_OK"    colour="$GREEN"  status_text="System was up to date"
            ;;
        in-progress)
            icon="$SYM_WARN"  colour="$YELLOW" status_text="Update may still be running"
            ;;
    esac

    printf "  ${colour}${icon} ${status_text}${NC}"
    [[ -n "$rel_time" ]] && printf "  ${DIM}${SYM_TIME} %s${NC}" "$rel_time"
    printf "\n"

    if [[ "$_LAST_PKG_COUNT" -gt 0 && "$_LAST_OUTCOME" != "up-to-date" ]]; then
        printf "    ${DIM}${SYM_PKG} %s package(s)${NC}" "$_LAST_PKG_COUNT"
        [[ -n "$_LAST_SNAP" ]] && printf "  ${DIM}snapshot #%s${NC}" "$_LAST_SNAP"
        printf "\n"
    fi

    if [[ -n "$_LAST_CRITICAL" ]]; then
        printf "    ${YELLOW}Critical: %s${NC}\n" "$_LAST_CRITICAL"
    fi

    if [[ "$_LAST_AUR" == "ok" ]]; then
        printf "    ${DIM}AUR ${GREEN}${SYM_OK}${NC}\n"
    elif [[ "$_LAST_AUR" == "failed" ]]; then
        printf "    ${DIM}AUR ${RED}${SYM_ERR} failed${NC}\n"
    fi

    # Log file size
    local log_file
    log_file=$(_resolve_log) || return 0
    local log_bytes log_size_fmt
    log_bytes=$(stat -c '%s' "$log_file" 2>/dev/null) || return
    log_size_fmt=$(_format_size "$log_bytes")
    local size_colour="$DIM"
    if (( log_bytes >= 10485760 )); then
        size_colour="$RED"
    elif (( log_bytes >= 1048576 )); then
        size_colour="$YELLOW"
    fi
    printf "    ${size_colour}Log: %s (%s)${NC}\n" "$log_file" "$log_size_fmt"
}

_show_pending() {
    if ! command -v checkupdates &>/dev/null; then
        printf "  ${DIM}checkupdates not available (install pacman-contrib)${NC}\n"
        return
    fi

    local pending
    pending=$(checkupdates 2>/dev/null) || true

    if [[ -z "$pending" ]]; then
        printf "  ${GREEN}${SYM_OK} No pending updates${NC}\n"
        return
    fi

    local count
    count=$(echo "$pending" | wc -l)
    printf "  ${CYAN}${SYM_UP} %s update(s) available${NC}\n" "$count"

    local shown=0
    while IFS= read -r line; do
        if (( shown >= 10 )); then
            printf "    ${DIM}… and %s more${NC}\n" "$(( count - shown ))"
            break
        fi
        local pkg old_ver _arrow new_ver
        read -r pkg old_ver _arrow new_ver <<< "$line"
        printf "    ${DIM}%-30s${NC} %s ${DIM}→${NC} ${WHITE}%s${NC}\n" "$pkg" "$old_ver" "$new_ver"
        (( shown++ ))
    done <<< "$pending"
}

_show_next_update() {
    # Query systemd timer for next fire time
    if ! systemctl list-unit-files "${SERVICE_NAME}.timer" &>/dev/null 2>&1; then
        return
    fi

    local next_raw
    next_raw=$(systemctl show "${SERVICE_NAME}.timer" -p NextElapseUSecRealtime --value 2>/dev/null) || return
    [[ -n "$next_raw" && "$next_raw" != "n/a" ]] || return

    # Compute forward time delta (can't use _relative_time for future dates)
    local epoch_next epoch_now diff_s
    epoch_next=$(date -d "$next_raw" '+%s' 2>/dev/null) || return
    epoch_now=$(date '+%s')
    diff_s=$(( epoch_next - epoch_now ))

    if (( diff_s <= 0 )); then
        printf "  ${DIM}${SYM_TIME} Next update: imminent${NC}\n"
    elif (( diff_s < 3600 )); then
        printf "  ${DIM}${SYM_TIME} Next update: in %sm${NC}\n" "$(( diff_s / 60 ))"
    elif (( diff_s < 86400 )); then
        printf "  ${DIM}${SYM_TIME} Next update: in %sh${NC}\n" "$(( diff_s / 3600 ))"
    else
        printf "  ${DIM}${SYM_TIME} Next update: in %sd${NC}\n" "$(( diff_s / 86400 ))"
    fi
}

cmd_status() {
    local show_last=true show_pending=false

    case "${1:-}" in
        --verbose|-v) show_pending=true  ;;
        --pending)    show_last=false; show_pending=true ;;
    esac

    printf "\n"

    if [[ "$show_last" == true ]]; then
        printf "  ${BOLD}${MAGENTA}Last Update${NC}\n"
        _show_last_update
        _show_next_update
    fi

    if [[ "$show_pending" == true ]]; then
        [[ "$show_last" == true ]] && printf "\n"
        printf "  ${BOLD}${MAGENTA}Pending Updates${NC}\n"
        _show_pending
    fi

    printf "\n"
}

# ── cmd_run ──────────────────────────────────────────────────────────────────

cmd_run() {
    _require_root
    _load_config

    _tlog "$LOG_START"

    # Refresh mirrors if reflector is available
    if command -v reflector &>/dev/null; then
        _tlog "Refreshing mirror list via reflector"
        local reflector_args=(--latest 20 --sort rate --protocol https --age 48 --connection-timeout 5 --download-timeout 5 --save /etc/pacman.d/mirrorlist)
        [[ -n "$REFLECTOR_COUNTRY" ]] && reflector_args+=(--country "$REFLECTOR_COUNTRY")
        if ! reflector "${reflector_args[@]}" 2>&1 | tee -a "$LOG"; then
            _tlog "WARNING: reflector failed (non-fatal) — continuing with existing mirror list"
        fi
    fi

    # Check what's pending before upgrading
    if ! command -v checkupdates &>/dev/null; then
        _tlog "checkupdates not found (install pacman-contrib); falling back to blind upgrade"
        _notify "normal" "update-manager" "checkupdates not available — upgrading blindly"
        pacman -Syu --noconfirm --noprogressbar 2>&1 | tee -a "$LOG"
        _tlog "$LOG_COMPLETE"
        return 0
    fi

    local pending
    pending=$(checkupdates 2>/dev/null) || true

    if [[ -z "$pending" ]]; then
        _tlog "System is up to date — nothing to do"
        return 0
    fi

    local pkg_count
    pkg_count=$(echo "$pending" | wc -l)
    _tlog "Pending updates ($pkg_count):"
    echo "$pending" | tee -a "$LOG"

    # Check for critical packages in the update set
    local critical_matches
    critical_matches=$(echo "$pending" | grep -Ew "$CRITICAL_PKGS" || true)

    if [[ -n "$critical_matches" ]]; then
        _tlog "Critical package(s) detected in update set — deferring automatic upgrade"
        _tlog "$critical_matches"
        local critical_names
        critical_names=$(echo "$critical_matches" | awk '{print $1}' | paste -sd ', ')
        _notify "critical" "update-manager: manual upgrade required" \
            "$pkg_count update(s) pending. Critical: $critical_names. Run 'pacman -Syu' manually."
        _tlog "$LOG_DEFERRED"
        return 0
    fi

    # Safe to auto-upgrade — no critical packages
    _tlog "No critical packages in update set — proceeding with upgrade"
    _notify "normal" "update-manager" "Upgrading $pkg_count package(s)"

    # ── Pre-upgrade snapshot ─────────────────────────────────────────────
    local _snap_pre_num=""
    local _snap_pac_inhibited=false

    _restore_snap_pac() {
        if [[ "$_snap_pac_inhibited" == true ]]; then
            rm -f /etc/pacman.d/hooks/00-snapper-pre.hook /etc/pacman.d/hooks/zz-snapper-post.hook
            _snap_pac_inhibited=false
        fi
    }
    trap '_restore_snap_pac' EXIT

    if command -v snapper &>/dev/null && snapper -c root get-config &>/dev/null 2>&1; then
        if [[ -f /usr/share/libalpm/hooks/00-snapper-pre.hook ]]; then
            install -d /etc/pacman.d/hooks
            ln -sf /dev/null /etc/pacman.d/hooks/00-snapper-pre.hook
            ln -sf /dev/null /etc/pacman.d/hooks/zz-snapper-post.hook
            _snap_pac_inhibited=true
        fi
        _snap_pre_num=$(snapper -c root create --type pre --print-number --cleanup-algorithm number \
            --description "update-manager" 2>&1) || true
        if [[ -n "$_snap_pre_num" && "$_snap_pre_num" =~ ^[0-9]+$ ]]; then
            _tlog "Pre-upgrade snapshot #${_snap_pre_num} created via snapper"
        else
            _tlog "WARNING: Failed to create snapper pre-upgrade snapshot (non-fatal)"
            _snap_pre_num=""
        fi
    elif command -v btrfs &>/dev/null && btrfs subvolume show / &>/dev/null; then
        local snapshot_dir="/.snapshots"
        if [[ -d "$snapshot_dir" ]]; then
            local snap_name
            snap_name="pre-update-$(date '+%Y%m%d-%H%M%S')"
            if btrfs subvolume snapshot -r / "${snapshot_dir}/${snap_name}" 2>&1 | tee -a "$LOG"; then
                _tlog "Pre-upgrade snapshot created: ${snapshot_dir}/${snap_name}"
            else
                _tlog "WARNING: Failed to create pre-upgrade snapshot (non-fatal)"
            fi

            local _prune_snaps=( "${snapshot_dir}"/pre-update-* )
            if [[ -e "${_prune_snaps[0]:-}" ]]; then
                IFS=$'\n' read -r -d '' -a _prune_snaps < <(printf '%s\n' "${_prune_snaps[@]}" | sort -r; printf '\0') || true
                for snap in "${_prune_snaps[@]:7}"; do
                    btrfs subvolume delete "$snap" 2>&1 | tee -a "$LOG" || true
                    _tlog "Pruned old snapshot: $snap"
                done
            fi
        else
            _tlog "Snapshot directory $snapshot_dir does not exist — skipping pre-upgrade snapshot"
        fi
    fi

    # ── Upgrade ──────────────────────────────────────────────────────────
    if ! pacman -Syu --noconfirm --noprogressbar 2>&1 | tee -a "$LOG"; then
        _notify "critical" "update-manager: upgrade failed" \
            "pacman -Syu exited with an error. Check $LOG for details."
        _tlog "ERROR: pacman -Syu failed"
        _tlog "$LOG_FAILED"
        return 1
    fi

    # Post-upgrade snapshot (paired with pre-upgrade)
    if [[ -n "${_snap_pre_num:-}" ]] && command -v snapper &>/dev/null; then
        local _snap_post_num
        _snap_post_num=$(snapper -c root create --type post --pre-number "$_snap_pre_num" \
            --print-number --cleanup-algorithm number \
            --description "update-manager" 2>&1) || true
        if [[ -n "$_snap_post_num" && "$_snap_post_num" =~ ^[0-9]+$ ]]; then
            _tlog "Post-upgrade snapshot #${_snap_post_num} created (pre: #${_snap_pre_num})"
        else
            _tlog "WARNING: Failed to create snapper post-upgrade snapshot (non-fatal)"
        fi
    fi

    # Re-enable snap-pac hooks (also handled by EXIT trap as safety net)
    if [[ "$_snap_pac_inhibited" == true ]]; then
        _restore_snap_pac
    fi

    # ── AUR updates ──────────────────────────────────────────────────────
    local _aur_user=""
    if [[ -n "$NOTIFY_USER" && "$NOTIFY_USER" != "__NOTIFY_USER__" ]]; then
        _aur_user="$NOTIFY_USER"
    else
        _aur_user=$(_resolve_notify_user)
    fi
    if [[ -n "$_aur_user" && "$_aur_user" != "root" ]]; then
        local _aur_helper_path="" _aur_helper_name=""
        local _paru_path _yay_path
        _paru_path=$(sudo -n -u "$_aur_user" bash -c 'command -v paru' 2>/dev/null) || true
        _yay_path=$(sudo -n -u "$_aur_user" bash -c 'command -v yay' 2>/dev/null) || true
        if [[ -n "$_paru_path" ]]; then
            _aur_helper_path="$_paru_path"
            _aur_helper_name="paru"
        elif [[ -n "$_yay_path" ]]; then
            _aur_helper_path="$_yay_path"
            _aur_helper_name="yay"
        fi
        if [[ -n "$_aur_helper_path" ]]; then
            _tlog "Updating AUR packages via $_aur_helper_name (as $_aur_user) [$_aur_helper_path]"
            if sudo -n -u "$_aur_user" "$_aur_helper_path" -Sua --noconfirm --noprogressbar 2>&1 | tee -a "$LOG"; then
                _tlog "AUR packages updated successfully"
            else
                _tlog "WARNING: AUR update failed (non-fatal)"
                _notify "normal" "update-manager" "AUR update via $_aur_helper_name failed (non-fatal)"
            fi
        fi
    fi

    _notify "normal" "update-manager" "Upgrade complete ($pkg_count packages)"
    _tlog "$LOG_COMPLETE"
}

# ── cmd_schedule ─────────────────────────────────────────────────────────────

_cleanup_old_units() {
    # Remove legacy arch-update units if they exist
    if [[ -f "$OLD_SERVICE_FILE" ]] || [[ -f "$OLD_TIMER_FILE" ]]; then
        _warn "Found legacy ${OLD_SERVICE_NAME} units — cleaning up"
        systemctl disable --now "${OLD_SERVICE_NAME}.timer" 2>/dev/null || true
        rm -f "$OLD_SERVICE_FILE" "$OLD_TIMER_FILE"
        systemctl daemon-reload
        _log "Removed legacy ${OLD_SERVICE_NAME} units"
    fi
}

_write_units() {
    local oncalendar="${1:-$DEFAULT_ONCALENDAR}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Update Manager — automated system upgrade
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-manager run
Nice=19
IOSchedulingClass=idle
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Update Manager timer

[Timer]
OnCalendar=$oncalendar
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF
}

cmd_schedule_enable() {
    _require_root
    _cleanup_old_units

    local oncalendar="$DEFAULT_ONCALENDAR"
    _write_units "$oncalendar"

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer"

    _log "Timer enabled (OnCalendar=$oncalendar)"
    _log "Check with: update-manager schedule status"
}

cmd_schedule_disable() {
    _require_root

    systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload

    _cleanup_old_units

    _log "Timer disabled and unit files removed"
}

cmd_schedule_set() {
    _require_root
    [[ $# -ge 1 ]] || _die "Usage: update-manager schedule set <oncalendar>"

    local spec="$1"

    # Validate the OnCalendar spec via systemd-analyze
    if ! systemd-analyze calendar "$spec" &>/dev/null; then
        _die "Invalid OnCalendar spec: '$spec'\n  Run 'systemd-analyze calendar \"$spec\"' for details."
    fi

    _write_units "$spec"
    systemctl daemon-reload

    if systemctl is-enabled "${SERVICE_NAME}.timer" &>/dev/null; then
        systemctl restart "${SERVICE_NAME}.timer"
    else
        systemctl enable --now "${SERVICE_NAME}.timer"
    fi

    _log "Timer schedule updated (OnCalendar=$spec)"
    echo ""
    systemd-analyze calendar "$spec"
}

cmd_schedule_status() {
    local is_active is_enabled oncalendar next_fire last_trigger

    if ! systemctl list-unit-files "${SERVICE_NAME}.timer" &>/dev/null 2>&1; then
        printf "  ${DIM}Timer not installed${NC}\n"
        return
    fi

    is_active=$(systemctl is-active "${SERVICE_NAME}.timer" 2>/dev/null || echo "inactive")
    is_enabled=$(systemctl is-enabled "${SERVICE_NAME}.timer" 2>/dev/null || echo "disabled")
    oncalendar=$(systemctl show "${SERVICE_NAME}.timer" -p TimersCalendar --value 2>/dev/null || true)
    next_fire=$(systemctl show "${SERVICE_NAME}.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)
    last_trigger=$(systemctl show "${SERVICE_NAME}.timer" -p LastTriggerUSecRealtime --value 2>/dev/null || true)

    local state_colour="$GREEN"
    [[ "$is_active" == "active" ]] || state_colour="$RED"

    printf "\n"
    printf "  ${BOLD}${MAGENTA}Update Timer${NC}\n"
    printf "  State:        ${state_colour}%s${NC} (%s)\n" "$is_active" "$is_enabled"
    [[ -n "$oncalendar" ]] && printf "  Schedule:     %s\n" "$oncalendar"
    [[ -n "$next_fire" && "$next_fire" != "n/a" ]] && printf "  Next fire:    %s\n" "$next_fire"
    [[ -n "$last_trigger" && "$last_trigger" != "n/a" ]] && printf "  Last trigger: %s\n" "$last_trigger"
    printf "\n"
}

cmd_schedule() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        enable)  cmd_schedule_enable "$@" ;;
        disable) cmd_schedule_disable "$@" ;;
        set)     cmd_schedule_set "$@" ;;
        status)  cmd_schedule_status "$@" ;;
        "")      _die "Missing schedule subcommand. Run 'update-manager --help' for usage." ;;
        *)       _die "Unknown schedule subcommand: $subcmd. Use enable|disable|set|status." ;;
    esac
}

# ── Main dispatch ────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-status}"

    case "$cmd" in
        -h|--help) usage ;;
    esac

    shift 2>/dev/null || true

    case "$cmd" in
        status)   cmd_status "$@" ;;
        run)      cmd_run "$@" ;;
        schedule) cmd_schedule "$@" ;;
        *)        _die "Unknown command: $cmd. Run 'update-manager --help' for usage." ;;
    esac
}

main "$@"
