#!/usr/bin/env bash
#
# Interactive snapper wrapper — list, create, delete, diff, and restore
# btrfs snapshots from a single entry point.
#
# Usage:
#   snapshot-manager <command> [options]
#
# Commands:
#   list                      List all snapshots (default)
#   create [-d "description"] Create a manual snapshot
#   delete <id> [id...]       Delete snapshot(s) by ID
#   diff <id1> <id2>          Show changes between two snapshots
#   restore [id] [-D device]  Restore system to a snapshot
#
# The restore command can run standalone from a Live ISO:
#   snapshot-manager restore                          # detect device, list & pick
#   snapshot-manager restore 5                        # auto-detect device
#   snapshot-manager restore -D /dev/sda3 5           # explicit device
#   snapshot-manager restore -D /dev/mapper/cryptroot # LUKS volume
#
# Examples:
#   snapshot-manager                        # list all snapshots
#   snapshot-manager list                   # same as above
#   snapshot-manager create -d "before cleanup"
#   snapshot-manager delete 42 43
#   snapshot-manager diff 10 11
#   snapshot-manager restore 5
#   snapshot-manager restore -D /dev/sda3

set -euo pipefail

# ── Colours & symbols ────────────────────────────────────────────────────────
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Logging helpers ──────────────────────────────────────────────────────────

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

# ── Common checks ───────────────────────────────────────────────────────────

_require_root() {
    [[ "$EUID" -eq 0 ]] || die "This operation must be run as root."
}

_require_snapper() {
    command -v snapper &>/dev/null || die "snapper is not installed. Install it with: pacman -S snapper"
    snapper -c root get-config &>/dev/null 2>&1 || die "snapper 'root' config not found. Run: snapper -c root create-config /"
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: snapshot-manager <command> [options]

Commands:
  list                            List all snapshots (default)
  create [-d "description"]       Create a manual snapshot
  delete <id> [id...]             Delete snapshot(s) by ID
  diff <id1> <id2>                Show changes between two snapshots
  restore [id] [-D <device>]      Restore system to a snapshot

Options:
  -h, --help                      Show this help message

Restore options:
  -D, --device <device>           Btrfs device or dm-crypt mapper to restore
                                  (auto-detected if omitted)

Live ISO standalone restore:
  Boot from Arch install media, clone the repo, and run:
    snapshot-manager restore                          # detect, list, pick
    snapshot-manager restore -D /dev/sda3             # explicit device
    snapshot-manager restore -D /dev/mapper/cryptroot # LUKS volume
EOF
    exit 0
}

# ── Helpers (absorbed from btrfs-restore.sh) ─────────────────────────────────

# Parse snapper info.xml to extract a field value.
_snapper_field() {
    local xml="$1" field="$2"
    sed -n "s|.*<${field}>\(.*\)</${field}>.*|\1|p" "$xml" 2>/dev/null | head -1
}

# Resolve a snapshot identifier to its btrfs subvolume path under a mount point.
# Supports snapper format (@snapshots/<N>/snapshot) and legacy (@snapshots/<name>).
_resolve_snapshot() {
    local snap_dir="$1" id="$2"
    if [[ -d "$snap_dir/$id/snapshot" ]]; then
        echo "$snap_dir/$id/snapshot"
    elif [[ -d "$snap_dir/$id" ]]; then
        echo "$snap_dir/$id"
    else
        return 1
    fi
}

# ── list ─────────────────────────────────────────────────────────────────────

cmd_list() {
    _require_snapper

    step "Snapshots (snapper -c root)"

    local output
    output=$(snapper -c root list --columns number,type,pre-number,date,cleanup,description 2>&1) \
        || die "Failed to list snapshots: $output"

    # Print the snapper output directly — it already provides a tabular format
    echo "$output"
}

# ── create ───────────────────────────────────────────────────────────────────

cmd_create() {
    _require_root
    _require_snapper

    local description="manual snapshot"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--description)
                [[ -n "${2:-}" ]] || die "Missing argument for $1"
                description="$2"
                shift 2
                ;;
            *)
                die "Unknown option for create: $1"
                ;;
        esac
    done

    local snap_num
    snap_num=$(snapper -c root create --type single --description "$description" --print-number 2>&1) \
        || die "Failed to create snapshot: $snap_num"

    log "Created snapshot #${snap_num} — ${description}"
}

# ── delete ───────────────────────────────────────────────────────────────────

cmd_delete() {
    _require_root
    _require_snapper
    [[ $# -ge 1 ]] || die "Usage: snapshot-manager delete <id> [id...]"

    # Validate all IDs first
    for id in "$@"; do
        [[ "$id" =~ ^[0-9]+$ ]] || die "Invalid snapshot ID: $id (must be a number)"
        [[ "$id" -ne 0 ]] || die "Cannot delete snapshot 0 (current system)."
    done

    # Show details for each snapshot and confirm
    step "Snapshots to delete"
    for id in "$@"; do
        local info
        info=$(snapper -c root list --columns number,type,date,description 2>/dev/null \
            | awk -v id="$id" '$1 == id') || true
        if [[ -n "$info" ]]; then
            echo "  $info"
        else
            warn "Snapshot #$id not found"
        fi
    done

    echo ""
    read -rp "Delete these snapshot(s)? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

    for id in "$@"; do
        if snapper -c root delete "$id" 2>&1; then
            log "Deleted snapshot #$id"
        else
            warn "Failed to delete snapshot #$id"
        fi
    done
}

# ── diff ─────────────────────────────────────────────────────────────────────

cmd_diff() {
    _require_snapper
    [[ $# -eq 2 ]] || die "Usage: snapshot-manager diff <id1> <id2>"

    local id1="$1" id2="$2"
    [[ "$id1" =~ ^[0-9]+$ ]] || die "Invalid snapshot ID: $id1"
    [[ "$id2" =~ ^[0-9]+$ ]] || die "Invalid snapshot ID: $id2"

    # ── Changed files ────────────────────────────────────────────────────
    step "Changed files between #$id1 and #$id2"
    local status_output
    status_output=$(snapper -c root status "$id1".."$id2" 2>&1) \
        || die "Failed to get status: $status_output"

    if [[ -z "$status_output" ]]; then
        log "No file changes detected."
    else
        while IFS= read -r line; do
            local indicator="${line:0:1}"
            local filepath="${line:2}"
            case "$indicator" in
                +) printf "  ${GREEN}+ %s${NC}\n" "$filepath" ;;
                -) printf "  ${RED}- %s${NC}\n" "$filepath" ;;
                c) printf "  ${YELLOW}c %s${NC}\n" "$filepath" ;;
                *) echo "  $line" ;;
            esac
        done <<< "$status_output"
    fi

    # ── Changed packages ─────────────────────────────────────────────────
    _diff_packages "$id1" "$id2"
}

# Extract pacman transactions between two snapshot timestamps.
_diff_packages() {
    local id1="$1" id2="$2"
    local pacman_log="/var/log/pacman.log"

    [[ -r "$pacman_log" ]] || return 0

    # Get snapshot dates from snapper
    local date1 date2
    date1=$(snapper -c root list --columns number,date 2>/dev/null \
        | awk -v id="$id1" '$1 == id { for(i=2;i<=NF;i++) printf "%s ", $i; print "" }' \
        | sed 's/[[:space:]]*$//') || true
    date2=$(snapper -c root list --columns number,date 2>/dev/null \
        | awk -v id="$id2" '$1 == id { for(i=2;i<=NF;i++) printf "%s ", $i; print "" }' \
        | sed 's/[[:space:]]*$//') || true

    [[ -n "$date1" && -n "$date2" ]] || return 0

    step "Package changes between #$id1 and #$id2"

    # Extract installed/removed/upgraded packages from pacman.log between the two dates
    local in_range=false
    local installed=() removed=() upgraded=()

    while IFS= read -r line; do
        # pacman.log lines: [YYYY-MM-DDTHH:MM:SS+ZZZZ] [ALPM] ...
        if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
            local log_ts="${BASH_REMATCH[1]}"
            if [[ "$log_ts" > "$date1" || "$log_ts" == "$date1" ]] 2>/dev/null; then
                in_range=true
            fi
            if [[ "$log_ts" > "$date2" ]] 2>/dev/null; then
                break
            fi
        fi

        [[ "$in_range" == true ]] || continue

        if [[ "$line" =~ \[ALPM\]\ installed\ ([^ ]+)\ \((.+)\) ]]; then
            installed+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
        elif [[ "$line" =~ \[ALPM\]\ removed\ ([^ ]+)\ \((.+)\) ]]; then
            removed+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
        elif [[ "$line" =~ \[ALPM\]\ upgraded\ ([^ ]+)\ \((.+)\) ]]; then
            upgraded+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
        fi
    done < "$pacman_log"

    if [[ ${#installed[@]} -eq 0 && ${#removed[@]} -eq 0 && ${#upgraded[@]} -eq 0 ]]; then
        log "No package changes found in pacman.log for this period."
        return 0
    fi

    if [[ ${#installed[@]} -gt 0 ]]; then
        printf "\n  ${GREEN}${BOLD}Installed (%d):${NC}\n" "${#installed[@]}"
        for pkg in "${installed[@]}"; do
            printf "    ${GREEN}+ %s${NC}\n" "$pkg"
        done
    fi

    if [[ ${#removed[@]} -gt 0 ]]; then
        printf "\n  ${RED}${BOLD}Removed (%d):${NC}\n" "${#removed[@]}"
        for pkg in "${removed[@]}"; do
            printf "    ${RED}- %s${NC}\n" "$pkg"
        done
    fi

    if [[ ${#upgraded[@]} -gt 0 ]]; then
        printf "\n  ${YELLOW}${BOLD}Upgraded (%d):${NC}\n" "${#upgraded[@]}"
        for pkg in "${upgraded[@]}"; do
            printf "    ${YELLOW}~ %s${NC}\n" "$pkg"
        done
    fi
}

# ── restore ──────────────────────────────────────────────────────────────────

# List snapshots from a mounted btrfs volume (offline — no snapper required).
# Used when restoring from a Live ISO where snapper is not available.
_list_snapshots_offline() {
    local snap_dir="$1"
    local count=0
    local has_snapper=false

    # Detect snapper-managed layout
    while IFS= read -r d; do
        if [[ -f "$d/info.xml" && -d "$d/snapshot" ]]; then
            has_snapper=true
            break
        fi
    done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)

    if [[ "$has_snapper" == "true" ]]; then
        printf "  %-6s %-20s %-8s %-14s %s\n" "ID" "DATE" "TYPE" "CLEANUP" "DESCRIPTION"
        printf "  %-6s %-20s %-8s %-14s %s\n" "------" "--------------------" "--------" "--------------" "-----------"
        while IFS= read -r d; do
            local num
            num="$(basename "$d")"
            local info_xml="$d/info.xml"
            [[ -f "$info_xml" && -d "$d/snapshot" ]] || continue

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
        done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)
    else
        while IFS= read -r snap_path; do
            local name
            name="$(basename "$snap_path")"
            btrfs subvolume show "$snap_path" &>/dev/null || continue
            local created
            created=$(btrfs subvolume show "$snap_path" 2>/dev/null \
                | grep -i 'creation time' | sed 's/.*:\s*//' || echo "unknown")
            local ro_flag
            ro_flag=$(btrfs property get "$snap_path" ro 2>/dev/null \
                | grep -o 'true\|false' || echo "unknown")
            echo "  $name  (created: $created, readonly: $ro_flag)"
            ((count++))
        done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    fi

    if [[ "$count" -eq 0 ]]; then
        warn "No snapshots found."
        return 1
    fi
    log "$count snapshot(s) found."
    return 0
}

# Detect or prompt for the target btrfs device.
# Sets the variable named by $1 (passed by reference via nameref).
_detect_btrfs_device() {
    local -n _result_dev="$1"
    _result_dev=""

    # Try the running system's root mount first
    local root_source
    root_source=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [[ -n "$root_source" ]]; then
        root_source="${root_source%%\[*}"
        if blkid -o value -s TYPE "$root_source" 2>/dev/null | grep -q '^btrfs$'; then
            _result_dev="$root_source"
        fi
    fi

    # If root is not btrfs (Live ISO), scan for btrfs devices
    if [[ -z "$_result_dev" ]]; then
        local btrfs_devs=()
        while IFS= read -r dev; do
            [[ -n "$dev" ]] && btrfs_devs+=("$dev")
        done < <(blkid -t TYPE=btrfs -o device 2>/dev/null)

        if [[ ${#btrfs_devs[@]} -eq 1 ]]; then
            _result_dev="${btrfs_devs[0]}"
            log "Auto-detected btrfs device: $_result_dev"
        elif [[ ${#btrfs_devs[@]} -gt 1 ]]; then
            step "Multiple btrfs devices found"
            local i=1
            for dev in "${btrfs_devs[@]}"; do
                local label size
                label=$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)
                size=$(lsblk -dno SIZE "$dev" 2>/dev/null || true)
                printf "  %d) %-30s %s %s\n" "$i" "$dev" "${size:+[$size]}" "${label:+($label)}"
                ((i++))
            done
            echo ""
            local choice
            read -rp "Select device [1-${#btrfs_devs[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#btrfs_devs[@]} )); then
                _result_dev="${btrfs_devs[$((choice - 1))]}"
            else
                die "Invalid selection."
            fi
        fi
    fi

    # Still nothing — check for LUKS partitions that might contain btrfs
    if [[ -z "$_result_dev" ]]; then
        local luks_parts=()
        while IFS= read -r dev; do
            [[ -n "$dev" ]] && luks_parts+=("$dev")
        done < <(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null)

        if [[ ${#luks_parts[@]} -gt 0 ]]; then
            step "No btrfs devices found, but LUKS partition(s) detected"
            local i=1
            for dev in "${luks_parts[@]}"; do
                local size
                size=$(lsblk -dno SIZE "$dev" 2>/dev/null || true)
                printf "  %d) %-30s %s\n" "$i" "$dev" "${size:+[$size]}"
                ((i++))
            done
            echo ""
            local choice
            read -rp "Unlock a LUKS partition? [1-${#luks_parts[@]}, or n to cancel]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#luks_parts[@]} )); then
                local luks_dev="${luks_parts[$((choice - 1))]}"
                local mapper_name mapper_name_input
                read -rp "Mapper name [cryptroot]: " mapper_name_input
                mapper_name="${mapper_name_input:-cryptroot}"
                cryptsetup open "$luks_dev" "$mapper_name" || die "Failed to unlock $luks_dev"
                log "Unlocked $luks_dev as /dev/mapper/$mapper_name"
                _result_dev="/dev/mapper/$mapper_name"
            else
                die "No btrfs devices available. Unlock your LUKS volume first."
            fi
        else
            die "No btrfs or LUKS devices found."
        fi
    fi
}

cmd_restore() {
    _require_root

    local snapshot_id="" device=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -D|--device)
                [[ -n "${2:-}" ]] || die "Missing argument for $1"
                device="$2"
                shift 2
                ;;
            -*)
                die "Unknown option for restore: $1"
                ;;
            *)
                if [[ -z "$snapshot_id" ]]; then
                    snapshot_id="$1"
                    shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    # Validate snapshot ID if provided
    if [[ -n "$snapshot_id" ]]; then
        [[ "$snapshot_id" =~ ^[0-9]+$ ]] || die "Invalid snapshot ID: $snapshot_id (must be a number)"
        [[ "$snapshot_id" -ne 0 ]] || die "Cannot restore snapshot 0 (current system)."
    fi

    # ── Resolve device ───────────────────────────────────────────────────
    if [[ -n "$device" ]]; then
        [[ -b "$device" ]] || die "Device '$device' does not exist or is not a block device."
        if ! blkid -o value -s TYPE "$device" 2>/dev/null | grep -q '^btrfs$'; then
            die "'$device' does not contain a btrfs filesystem."
        fi
    else
        _detect_btrfs_device device
    fi

    # ── Live-system check ────────────────────────────────────────────────
    # If the btrfs device is the running root, we cannot restore in-place.
    local _root_dev
    _root_dev=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [[ -n "$_root_dev" ]]; then
        _root_dev="${_root_dev%%\[*}"
        local _root_real _dev_real
        _root_real=$(realpath "$_root_dev" 2>/dev/null || echo "$_root_dev")
        _dev_real=$(realpath "$device" 2>/dev/null || echo "$device")
        if [[ "$_root_real" == "$_dev_real" ]]; then
            echo ""
            warn "Cannot restore while booted from the target filesystem."
            echo ""
            echo "  To restore snapshot${snapshot_id:+ #$snapshot_id}:"
            echo "  1. Boot from the Arch Linux installation medium (live USB)"
            echo "  2. If using LUKS, unlock the volume first:"
            echo "     cryptsetup open /dev/<partition> cryptroot"
            echo "  3. Run: snapshot-manager restore${snapshot_id:+ $snapshot_id}"
            echo ""
            exit 1
        fi
    fi

    # ── Mount and restore ────────────────────────────────────────────────
    local mnt
    mnt="$(mktemp -d /tmp/snapshot-restore-XXXXXX)"

    cleanup() {
        if mountpoint -q "$mnt" 2>/dev/null; then
            # Rollback if interrupted mid-restore
            if [[ -d "$mnt/@.broken" && ! -d "$mnt/@" ]]; then
                warn "Incomplete restore detected — rolling back @.broken to @"
                mv "$mnt/@.broken" "$mnt/@" 2>/dev/null || warn "Rollback failed — manually run: mv @.broken @"
            fi
            if [[ -d "$mnt/@.new" ]]; then
                btrfs subvolume delete "$mnt/@.new" 2>/dev/null || true
            fi
            umount "$mnt" 2>/dev/null || true
        fi
        rmdir "$mnt" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    step "Mounting top-level btrfs volume from $device"
    mount -t btrfs -o subvolid=5 "$device" "$mnt"
    log "Mounted at $mnt"

    # Verify expected subvolume layout
    [[ -d "$mnt/@" ]] || die "Expected subvolume '@' not found — this does not appear to be our layout."
    [[ -d "$mnt/@snapshots" ]] || die "Expected subvolume '@snapshots' not found — no snapshots directory."

    local snap_dir="$mnt/@snapshots"

    # If no snapshot ID was given, list available snapshots and prompt
    if [[ -z "$snapshot_id" ]]; then
        step "Available snapshots on $device"
        if ! _list_snapshots_offline "$snap_dir"; then
            die "No snapshots to restore from."
        fi
        echo ""
        read -rp "Enter snapshot ID to restore: " snapshot_id
        [[ "$snapshot_id" =~ ^[0-9]+$ ]] || die "Invalid snapshot ID: $snapshot_id"
        [[ "$snapshot_id" -ne 0 ]] || die "Cannot restore snapshot 0 (current system)."
    fi

    # Resolve snapshot path
    local snap_path
    snap_path=$(_resolve_snapshot "$snap_dir" "$snapshot_id") \
        || die "Snapshot '$snapshot_id' not found in @snapshots."

    # Verify it is a btrfs subvolume
    if ! btrfs subvolume show "$snap_path" &>/dev/null; then
        die "'$snapshot_id' exists but is not a btrfs subvolume."
    fi

    # Display snapshot details
    local snap_label="$snapshot_id"
    local snap_info_xml="$snap_dir/$snapshot_id/info.xml"
    if [[ -f "$snap_info_xml" ]]; then
        local snap_desc snap_date snap_type
        snap_desc=$(_snapper_field "$snap_info_xml" "description")
        snap_date=$(_snapper_field "$snap_info_xml" "date")
        snap_type=$(_snapper_field "$snap_info_xml" "type")
        [[ -n "$snap_desc" ]] && snap_label="#${snapshot_id} (${snap_desc})"
        [[ -n "$snap_date" ]] && log "Snapshot date: $snap_date"
        [[ -n "$snap_type" ]] && log "Snapshot type: $snap_type"
    fi

    step "Restore plan"
    log "Source snapshot: ${snap_label}"
    log "Target:         @ (current root subvolume)"
    echo ""
    warn "This will:"
    echo "  1. Rename the current '@' subvolume to '@.broken' (as a backup)"
    echo "  2. Create a new '@' as a writable snapshot of '@snapshots/$snapshot_id'"
    echo "  3. The system will boot into the restored state on next reboot"
    echo ""
    warn "The old root will be preserved as '@.broken'. You can delete it later"
    warn "once you've confirmed the restored system works correctly."
    echo ""

    read -rp "Type 'YES' to proceed with the restore: " confirm
    [[ "$confirm" == "YES" ]] || die "Restore aborted by user."

    # Remove any previous @.broken to avoid conflicts
    if [[ -d "$mnt/@.broken" ]]; then
        warn "Previous @.broken found from a prior restore session."
        warn "It must be deleted before proceeding (the current @ will be renamed to @.broken)."
        read -rp "Type 'YES' to delete the existing @.broken: " confirm_broken
        [[ "$confirm_broken" == "YES" ]] || die "Cannot proceed without deleting @.broken. Aborting."
        if ! btrfs subvolume delete "$mnt/@.broken"; then
            die "Failed to delete previous @.broken — it may contain nested subvolumes. Remove it manually before retrying."
        fi
        log "Old @.broken deleted"
    fi

    step "Creating writable snapshot from @snapshots/$snapshot_id"
    btrfs subvolume snapshot "$snap_path" "$mnt/@.new"
    log "Snapshot created as @.new — verifying"

    if ! btrfs subvolume show "$mnt/@.new" &>/dev/null; then
        die "Snapshot verification failed — @.new is not a valid subvolume. Aborting."
    fi

    step "Swapping subvolumes: @ → @.broken, @.new → @"
    mv "$mnt/@" "$mnt/@.broken"
    mv "$mnt/@.new" "$mnt/@"
    log "Subvolume swap complete"

    step "Restore complete!"
    echo ""
    log "The root subvolume has been restored from: $snap_label"
    log "The previous root is preserved as @.broken"
    log ""
    log "Next steps:"
    log "  1. Unmount and reboot into the restored system"
    log "  2. Verify everything works correctly"
    log "  3. (Optional) Delete the old root backup:"
    log "     mount -o subvolid=5 $device /mnt"
    log "     btrfs subvolume delete /mnt/@.broken"
}

# ── Main dispatch ────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-list}"

    case "$cmd" in
        -h|--help) usage ;;
    esac

    shift 2>/dev/null || true

    case "$cmd" in
        list)    cmd_list "$@" ;;
        create)  cmd_create "$@" ;;
        delete)  cmd_delete "$@" ;;
        diff)    cmd_diff "$@" ;;
        restore) cmd_restore "$@" ;;
        *)       die "Unknown command: $cmd. Run 'snapshot-manager --help' for usage." ;;
    esac
}

main "$@"
