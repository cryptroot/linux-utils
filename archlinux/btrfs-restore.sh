#!/usr/bin/env bash
#
# Restore the root filesystem from a btrfs snapshot.
#
# Supports both snapper-managed snapshots (/.snapshots/<N>/snapshot with info.xml)
# and legacy manual snapshots (/.snapshots/<name>).
#
# This script replaces the active @ subvolume with a snapshot from /.snapshots/.
# It must be run from a live USB or rescue environment where the btrfs volume
# is NOT the running root filesystem.
#
# Usage:
#   bash btrfs-restore.sh <device>              # list available snapshots
#   bash btrfs-restore.sh <device> <snapshot>    # restore a specific snapshot
#
# Example:
#   bash btrfs-restore.sh /dev/sda3
#   bash btrfs-restore.sh /dev/sda3 5              # snapper snapshot #5
#   bash btrfs-restore.sh /dev/mapper/cryptroot 5
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

usage() {
    echo "Usage: $(basename "$0") <btrfs-device> [snapshot-id]"
    echo ""
    echo "  <btrfs-device>   Block device or dm-crypt mapper containing the btrfs volume"
    echo "                   e.g. /dev/sda3, /dev/mapper/cryptroot"
    echo "  [snapshot-id]    Snapper snapshot number or legacy snapshot name (omit to list)"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") /dev/sda3                  # list snapshots"
    echo "  $(basename "$0") /dev/sda3 5                # restore snapper snapshot #5"
    echo "  $(basename "$0") /dev/mapper/cryptroot 5    # restore from LUKS volume"
    exit 1
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

[[ "$#" -lt 1 ]] && usage

DEVICE="$1"
SNAPSHOT_NAME="${2:-}"

[[ "$EUID" -eq 0 ]] || die "This script must be run as root."
[[ -b "$DEVICE" ]] || die "Device '$DEVICE' does not exist or is not a block device."

# Verify the device contains a btrfs filesystem
if ! blkid -o value -s TYPE "$DEVICE" 2>/dev/null | grep -q '^btrfs$'; then
    die "'$DEVICE' does not contain a btrfs filesystem."
fi

# Refuse to operate if the device (or one of its subvolumes) is the running root filesystem.
# This must be run from a live USB or rescue environment.
_root_dev=$(findmnt -no SOURCE / 2>/dev/null || true)
if [[ -n "$_root_dev" ]]; then
    # Strip btrfs subvolume suffix (e.g. /dev/sda3[/@] → /dev/sda3) so the
    # comparison works on btrfs systems where findmnt appends [/subvol].
    _root_dev="${_root_dev%%\[*}"
    # Resolve to the underlying device for dm-crypt/LVM comparisons
    _root_real=$(realpath "$_root_dev" 2>/dev/null || echo "$_root_dev")
    _dev_real=$(realpath "$DEVICE" 2>/dev/null || echo "$DEVICE")
    if [[ "$_root_real" == "$_dev_real" ]]; then
        die "$DEVICE is currently mounted as the root filesystem. Run this script from a live USB or rescue environment."
    fi
fi

# ==============================================================================
# MOUNT THE TOP-LEVEL BTRFS VOLUME
# ==============================================================================

MNT="$(mktemp -d /tmp/btrfs-restore-XXXXXX)"

cleanup() {
    # If we were interrupted mid-restore, attempt rollback so the system remains bootable.
    if mountpoint -q "$MNT" 2>/dev/null; then
        if [[ -d "$MNT/@.broken" && ! -d "$MNT/@" ]]; then
            warn "Incomplete restore detected — rolling back @.broken to @"
            mv "$MNT/@.broken" "$MNT/@" 2>/dev/null || warn "Rollback failed — manually run: mv @.broken @"
        fi
        # Clean up temporary snapshot if it was left behind
        if [[ -d "$MNT/@.new" ]]; then
            btrfs subvolume delete "$MNT/@.new" 2>/dev/null || true
        fi
        umount "$MNT" 2>/dev/null || true
    fi
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

step "Mounting top-level btrfs volume from $DEVICE"
mount -t btrfs -o subvolid=5 "$DEVICE" "$MNT"
log "Mounted at $MNT"

# Verify expected subvolume layout
[[ -d "$MNT/@" ]] || die "Expected subvolume '@' not found — this does not appear to be our layout."
[[ -d "$MNT/@snapshots" ]] || die "Expected subvolume '@snapshots' not found — no snapshots directory."

# ==============================================================================
# LIST SNAPSHOTS
# ==============================================================================

SNAP_DIR="$MNT/@snapshots"

# Parse snapper info.xml to extract a field value.
# Usage: _snapper_field <info.xml path> <field>
_snapper_field() {
    local xml="$1" field="$2"
    sed -n "s|.*<${field}>\(.*\)</${field}>.*|\1|p" "$xml" 2>/dev/null | head -1
}

# Resolve a snapshot identifier to its btrfs subvolume path.
# Supports both snapper format (@snapshots/<N>/snapshot) and legacy (@snapshots/<name>).
_resolve_snapshot() {
    local id="$1"
    if [[ -d "$SNAP_DIR/$id/snapshot" ]]; then
        # Snapper format
        echo "$SNAP_DIR/$id/snapshot"
    elif [[ -d "$SNAP_DIR/$id" ]]; then
        # Legacy format (bare subvolume)
        echo "$SNAP_DIR/$id"
    else
        return 1
    fi
}

list_snapshots() {
    step "Available snapshots in @snapshots"
    local count=0
    local has_snapper=false

    # Detect if this is a snapper-managed layout
    while IFS= read -r snap_dir; do
        if [[ -f "$snap_dir/info.xml" && -d "$snap_dir/snapshot" ]]; then
            has_snapper=true
            break
        fi
    done < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)

    if [[ "$has_snapper" == "true" ]]; then
        # Snapper-managed snapshots
        printf "  %-6s %-20s %-8s %-14s %s\n" "ID" "DATE" "TYPE" "CLEANUP" "DESCRIPTION"
        printf "  %-6s %-20s %-8s %-14s %s\n" "------" "--------------------" "--------" "--------------" "-----------"
        while IFS= read -r snap_dir; do
            local num
            num="$(basename "$snap_dir")"
            local info_xml="$snap_dir/info.xml"

            [[ -f "$info_xml" && -d "$snap_dir/snapshot" ]] || continue

            local snap_type snap_date snap_desc snap_cleanup
            snap_type=$(_snapper_field "$info_xml" "type")
            snap_date=$(_snapper_field "$info_xml" "date")
            snap_desc=$(_snapper_field "$info_xml" "description")
            snap_cleanup=$(_snapper_field "$info_xml" "cleanup")
            [[ -z "$snap_type" ]] && snap_type="single"
            [[ -z "$snap_date" ]] && snap_date="unknown"
            [[ -z "$snap_desc" ]] && snap_desc=""
            [[ -z "$snap_cleanup" ]] && snap_cleanup=""

            printf "  %-6s %-20s %-8s %-14s %s\n" "$num" "$snap_date" "$snap_type" "$snap_cleanup" "$snap_desc"
            ((count++))
        done < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)
    else
        # Legacy manual snapshots
        while IFS= read -r snap_path; do
            local name
            name="$(basename "$snap_path")"
            # Skip entries that aren't btrfs subvolumes
            btrfs subvolume show "$snap_path" &>/dev/null || continue
            local created
            created=$(btrfs subvolume show "$snap_path" 2>/dev/null | grep -i 'creation time' | sed 's/.*:\s*//' || echo "unknown")
            local ro_flag
            ro_flag=$(btrfs property get "$snap_path" ro 2>/dev/null | grep -o 'true\|false' || echo "unknown")
            echo "  $name  (created: $created, readonly: $ro_flag)"
            ((count++))
        done < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    fi

    if [[ "$count" -eq 0 ]]; then
        warn "No snapshots found in @snapshots."
    else
        echo ""
        log "$count snapshot(s) found."
        echo "To restore, run: $(basename "$0") $DEVICE <snapshot-id>"
    fi
}

if [[ -z "$SNAPSHOT_NAME" ]]; then
    list_snapshots
    exit 0
fi

# ==============================================================================
# RESTORE SNAPSHOT
# ==============================================================================

SNAP_PATH=$(_resolve_snapshot "$SNAPSHOT_NAME") || die "Snapshot '$SNAPSHOT_NAME' not found in @snapshots."

# Verify it is actually a btrfs subvolume
if ! btrfs subvolume show "$SNAP_PATH" &>/dev/null; then
    die "'$SNAPSHOT_NAME' exists but is not a btrfs subvolume."
fi

# Display snapshot details
_snap_label="$SNAPSHOT_NAME"
_snap_info_xml="$SNAP_DIR/$SNAPSHOT_NAME/info.xml"
if [[ -f "$_snap_info_xml" ]]; then
    _snap_desc=$(_snapper_field "$_snap_info_xml" "description")
    _snap_date=$(_snapper_field "$_snap_info_xml" "date")
    _snap_type=$(_snapper_field "$_snap_info_xml" "type")
    [[ -n "$_snap_desc" ]] && _snap_label="#${SNAPSHOT_NAME} (${_snap_desc})"
    [[ -n "$_snap_date" ]] && log "Snapshot date: $_snap_date"
    [[ -n "$_snap_type" ]] && log "Snapshot type: $_snap_type"
fi

step "Restore plan"
log "Source snapshot: ${_snap_label}"
log "Target:         @ (current root subvolume)"
echo ""
warn "This will:"
echo "  1. Rename the current '@' subvolume to '@.broken' (as a backup)"
echo "  2. Create a new '@' as a writable snapshot of '@snapshots/$SNAPSHOT_NAME'"
echo "  3. The system will boot into the restored state on next reboot"
echo ""
warn "The old root will be preserved as '@.broken'. You can delete it later"
warn "once you've confirmed the restored system works correctly."
echo ""

read -rp "Type 'YES' to proceed with the restore: " confirm
[[ "$confirm" == "YES" ]] || die "Restore aborted by user."

# Remove any previous @.broken to avoid conflicts
if [[ -d "$MNT/@.broken" ]]; then
    warn "Previous @.broken found from a prior restore session."
    warn "It must be deleted before proceeding (the current @ will be renamed to @.broken)."
    read -rp "Type 'YES' to delete the existing @.broken: " confirm_broken
    [[ "$confirm_broken" == "YES" ]] || die "Cannot proceed without deleting @.broken. Aborting."
    if ! btrfs subvolume delete "$MNT/@.broken"; then
        die "Failed to delete previous @.broken — it may contain nested subvolumes. Remove it manually before retrying."
    fi
    log "Old @.broken deleted"
fi

step "Creating writable snapshot from @snapshots/$SNAPSHOT_NAME"
btrfs subvolume snapshot "$SNAP_PATH" "$MNT/@.new"
log "Snapshot created as @.new — verifying"

# Verify the new snapshot is a valid subvolume before swapping
if ! btrfs subvolume show "$MNT/@.new" &>/dev/null; then
    die "Snapshot verification failed — @.new is not a valid subvolume. Aborting."
fi

step "Swapping subvolumes: @ → @.broken, @.new → @"
mv "$MNT/@" "$MNT/@.broken"
mv "$MNT/@.new" "$MNT/@"
log "Subvolume swap complete"

step "Restore complete!"
echo ""
log "The root subvolume has been restored from: $SNAPSHOT_NAME"
log "The previous root is preserved as @.broken"
log ""
log "Next steps:"
log "  1. Unmount and reboot into the restored system"
log "  2. Verify everything works correctly"
log "  3. (Optional) Delete the old root backup:"
log "     mount -o subvolid=5 $DEVICE /mnt"
log "     btrfs subvolume delete /mnt/@.broken"
log "     umount /mnt"
