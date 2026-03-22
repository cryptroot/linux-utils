#!/usr/bin/env bash
#
# Arch Linux mirror refresh and full system upgrade.
# Deployed to /usr/local/bin/arch-update by the installer and run via a systemd timer.
#
# This is a truly terrible idea but I like to live dangerously. Use at your own risk.
#
set -euo pipefail

LOG="/var/log/arch-update.log"
NOTIFY_USER="__NOTIFY_USER__"

# Load configuration overrides (edit /etc/arch-update.conf to customise)
CONF_FILE="/etc/arch-update.conf"
DEFAULT_CRITICAL_PKGS="linux|linux-lts|linux-zen|linux-hardened|glibc|systemd|systemd-libs"
if [[ -f "$CONF_FILE" ]]; then
    # Verify ownership and permissions before sourcing to prevent privilege escalation:
    # the update script runs as root, so a world-writable config would be exploitable.
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
# grep exits 1 for "no match" and 2 for "invalid pattern"; only exit code 2 is an error.
_rc=0
echo "test" | grep -Ew "$CRITICAL_PKGS" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" -eq 2 ]]; then
    echo "[WARNING] CRITICAL_PKGS is not a valid ERE pattern ('$CRITICAL_PKGS') — falling back to default" >&2
    CRITICAL_PKGS="$DEFAULT_CRITICAL_PKGS"
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

_resolve_notify_user() {
    if command -v loginctl &>/dev/null; then
        local session_id _rest type username
        # Parse only the session ID from each line; query session properties via
        # loginctl show-session to avoid dependence on the tabular column order
        # (which changed across systemd versions and has UID in column 2, not USER).
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

notify() {
    local urgency="$1" summary="$2" body="$3"
    local target_user
    target_user=$(_resolve_notify_user)
    if [[ -n "$target_user" ]] && command -v sudo &>/dev/null && command -v notify-send &>/dev/null; then
        local uid
        uid=$(id -u "$target_user" 2>/dev/null) || true
        if [[ -n "$uid" ]]; then
            local env_vars=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus")
            # Detect display server: prefer Wayland, fall back to X11
            if [[ -S "/run/user/${uid}/wayland-0" ]]; then
                env_vars+=("WAYLAND_DISPLAY=wayland-0" "XDG_RUNTIME_DIR=/run/user/${uid}")
            else
                env_vars+=("DISPLAY=:0")
            fi
            sudo -u "$target_user" env "${env_vars[@]}" \
                notify-send --urgency="$urgency" "$summary" "$body" 2>/dev/null || true
        fi
    fi
    log "NOTIFY [$urgency]: $summary — $body"
}

log "=== Starting daily update ==="

# Refresh mirrors if reflector is available
if command -v reflector &>/dev/null; then
    log "Refreshing mirror list via reflector"
    reflector_args=(--latest 20 --sort rate --protocol https --age 48 --connection-timeout 5 --download-timeout 5 --save /etc/pacman.d/mirrorlist)
    [[ -n "$REFLECTOR_COUNTRY" ]] && reflector_args+=(--country "$REFLECTOR_COUNTRY")
    if ! reflector "${reflector_args[@]}" 2>&1 | tee -a "$LOG"; then
        log "WARNING: reflector failed (non-fatal) — continuing with existing mirror list"
    fi
fi

# Check what's pending before upgrading
if ! command -v checkupdates &>/dev/null; then
    log "checkupdates not found (install pacman-contrib); falling back to blind upgrade"
    notify "normal" "arch-update" "checkupdates not available — upgrading blindly"
    pacman -Syu --noconfirm --noprogressbar 2>&1 | tee -a "$LOG"
    log "=== Update complete ==="
    exit 0
fi

pending=$(checkupdates 2>/dev/null) || true

if [[ -z "$pending" ]]; then
    log "System is up to date — nothing to do"
    exit 0
fi

pkg_count=$(echo "$pending" | wc -l)
log "Pending updates ($pkg_count):"
echo "$pending" | tee -a "$LOG"

# Check for critical packages in the update set
critical_matches=$(echo "$pending" | grep -Ew "$CRITICAL_PKGS" || true)

if [[ -n "$critical_matches" ]]; then
    log "Critical package(s) detected in update set — deferring automatic upgrade"
    log "$critical_matches"
    critical_names=$(echo "$critical_matches" | awk '{print $1}' | paste -sd ', ')
    notify "critical" "arch-update: manual upgrade required" \
        "$pkg_count update(s) pending. Critical: $critical_names. Run 'pacman -Syu' manually."
    log "=== Update deferred ==="
    exit 0
fi

# Safe to auto-upgrade — no critical packages
log "No critical packages in update set — proceeding with upgrade"
notify "normal" "arch-update" "Upgrading $pkg_count package(s)"

# Take a snapper pre-upgrade snapshot if snapper is available and configured.
# Temporarily inhibit snap-pac so the subsequent pacman -Syu does not create a
# redundant pre/post pair (we manage the pair manually to bracket AUR updates too).
_snap_pre_num=""
_snap_pac_inhibited=false

# Ensure snap-pac hooks are restored on any exit (success, failure, or signal)
# to prevent leaving them permanently disabled after a failed upgrade.
_restore_snap_pac() {
    if [[ "$_snap_pac_inhibited" == true ]]; then
        rm -f /etc/pacman.d/hooks/00-snapper-pre.hook /etc/pacman.d/hooks/zz-snapper-post.hook
        _snap_pac_inhibited=false
    fi
}
# This replaces the entire EXIT trap (if any) — not ideal but the script doesn't set one otherwise and it's important to ensure the hooks are re-enabled after a failure.
trap '_restore_snap_pac' EXIT

if command -v snapper &>/dev/null && snapper -c root get-config &>/dev/null 2>&1; then
    if [[ -f /usr/share/libalpm/hooks/00-snapper-pre.hook ]]; then
        install -d /etc/pacman.d/hooks
        ln -sf /dev/null /etc/pacman.d/hooks/00-snapper-pre.hook
        ln -sf /dev/null /etc/pacman.d/hooks/zz-snapper-post.hook
        _snap_pac_inhibited=true
    fi
    _snap_pre_num=$(snapper -c root create --type pre --print-number --cleanup-algorithm number \
        --description "arch-update" 2>&1) || true
    if [[ -n "$_snap_pre_num" && "$_snap_pre_num" =~ ^[0-9]+$ ]]; then
        log "Pre-upgrade snapshot #${_snap_pre_num} created via snapper"
    else
        log "WARNING: Failed to create snapper pre-upgrade snapshot (non-fatal)"
        _snap_pre_num=""
    fi
elif command -v btrfs &>/dev/null && btrfs subvolume show / &>/dev/null; then
    # Fallback: manual btrfs snapshot if snapper is not configured
    snapshot_dir="/.snapshots"
    if [[ -d "$snapshot_dir" ]]; then
        snap_name="pre-update-$(date '+%Y%m%d-%H%M%S')"
        if btrfs subvolume snapshot -r / "${snapshot_dir}/${snap_name}" 2>&1 | tee -a "$LOG"; then
            log "Pre-upgrade snapshot created: ${snapshot_dir}/${snap_name}"
        else
            log "WARNING: Failed to create pre-upgrade snapshot (non-fatal)"
        fi

        # Prune old pre-update snapshots, keeping the 7 most recent.
        _prune_snaps=( "${snapshot_dir}"/pre-update-* )
        if [[ -e "${_prune_snaps[0]:-}" ]]; then
            IFS=$'\n' read -r -d '' -a _prune_snaps < <(printf '%s\n' "${_prune_snaps[@]}" | sort -r; printf '\0') || true
            for snap in "${_prune_snaps[@]:7}"; do
                btrfs subvolume delete "$snap" 2>&1 | tee -a "$LOG" || true
                log "Pruned old snapshot: $snap"
            done
        fi
    else
        log "Snapshot directory $snapshot_dir does not exist — skipping pre-upgrade snapshot"
    fi
fi

if ! pacman -Syu --noconfirm --noprogressbar 2>&1 | tee -a "$LOG"; then
    notify "critical" "arch-update: upgrade failed" \
        "pacman -Syu exited with an error. Check $LOG for details."
    log "ERROR: pacman -Syu failed"
    log "=== Update failed ==="
    exit 1
fi

# Create snapper post-upgrade snapshot (paired with the pre-upgrade snapshot)
if [[ -n "${_snap_pre_num:-}" ]] && command -v snapper &>/dev/null; then
    _snap_post_num=$(snapper -c root create --type post --pre-number "$_snap_pre_num" \
        --print-number --cleanup-algorithm number \
        --description "arch-update" 2>&1) || true
    if [[ -n "$_snap_post_num" && "$_snap_post_num" =~ ^[0-9]+$ ]]; then
        log "Post-upgrade snapshot #${_snap_post_num} created (pre: #${_snap_pre_num})"
    else
        log "WARNING: Failed to create snapper post-upgrade snapshot (non-fatal)"
    fi
fi

# Re-enable snap-pac hooks (also handled by the EXIT trap as a safety net)
if [[ "$_snap_pac_inhibited" == true ]]; then
    _restore_snap_pac
fi

# Update AUR packages if an AUR helper is installed and a non-root user is available
_aur_user=""
if [[ -n "$NOTIFY_USER" && "$NOTIFY_USER" != "__NOTIFY_USER__" ]]; then
    _aur_user="$NOTIFY_USER"
else
    _aur_user=$(_resolve_notify_user)
fi
if [[ -n "$_aur_user" && "$_aur_user" != "root" ]]; then
    _aur_helper_path=""
    _aur_helper_name=""
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
        log "Updating AUR packages via $_aur_helper_name (as $_aur_user) [$_aur_helper_path]"
        if sudo -n -u "$_aur_user" "$_aur_helper_path" -Sua --noconfirm --noprogressbar 2>&1 | tee -a "$LOG"; then
            log "AUR packages updated successfully"
        else
            log "WARNING: AUR update failed (non-fatal)"
            notify "normal" "arch-update" "AUR update via $_aur_helper_name failed (non-fatal)"
        fi
    fi
fi

notify "normal" "arch-update" "Upgrade complete ($pkg_count packages)"
log "=== Update complete ==="
