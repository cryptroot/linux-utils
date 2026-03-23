#!/usr/bin/env bash
#
# Arch Linux automated installation script
# Based on: https://wiki.archlinux.org/title/Installation_guide
#
# Files (keep all together in the same directory):
#   install.sh      — this script; run it to start the installation
#   install-tui.sh  — interactive TUI wizard (recommended entry point)
#   chroot-setup.sh — system configuration executed inside arch-chroot
#   update.sh       — daily update script deployed to the installed system
#   ../tools/snapshot-manager.sh — manage and restore btrfs snapshots
#
# Usage:
#   1. Boot from the Arch Linux installation medium
#   2. Copy the entire archlinux/ directory to the live environment
#   3. Edit the CONFIGURATION section in install.sh
#   4. Run: bash install.sh
#
# WARNING: This script will DESTROY all data on the target disk.
#          Review the configuration carefully before running.
#
# Additional note to self: It is common to see "fatal library error, lookup self" during chroot update, this is apparently fine.

set -euo pipefail

# ==============================================================================
# CONFIGURATION — Edit these variables before running
# ==============================================================================
# Automation flags
REQUIRE_WIPE_CONFIRMATION=true  # set to false to skip "type YES to continue" prompt for disk wiping
REQUIRE_REBOOT_CONFIRMATION=true  # set to false to skip the reboot prompt at the end

# Target disk (e.g., /dev/sda, /dev/nvme0n1, /dev/vda)
DISK="/dev/sda"

# Partition sizes
EFI_SIZE="512M"      # EFI system partition (UEFI only)
SWAP_SIZE="4G"       # Swap partition (set to "" to skip swap)
ROOT_SIZE=""         # Root partition size (e.g., "50G"); "" = root uses remaining space, no separate /home
# When set, /home takes the remaining disk space

# Filesystem for root partition
ROOT_FS="ext4"       # ext4 | btrfs | xfs

# Timezone (ls /usr/share/zoneinfo/ for options)
TIMEZONE="UTC"

# Locale (must exist in /etc/locale.gen)
LOCALE="en_US.UTF-8"

# Console keyboard layout (localectl list-keymaps)
KEYMAP="us"

# Hostname
HOSTNAME="archlinux"

# Root password — will be prompted interactively if left empty
# These may be pre-set via environment (e.g., by install-tui.sh)
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# Create a regular user (leave empty to skip)
USERNAME=""
USER_PASSWORD="${USER_PASSWORD:-}"

# Kernel package
KERNEL="linux"       # linux | linux-lts | linux-zen | linux-hardened

# Additional packages to install (space-separated)
EXTRA_PACKAGES="nano networkmanager base-devel openssh"

# CPU microcode (amd-ucode | intel-ucode | "" for none/VM)
MICROCODE=""

# Boot loader: systemd-boot (UEFI) or grub (BIOS/UEFI)
BOOTLOADER="systemd-boot"

# Use reflector to rank mirrors? (true/false)
USE_REFLECTOR="true"
REFLECTOR_COUNTRY=""  # e.g., "US" or "US,DE" (empty = auto)

# Enable multilib repository? (true/false)
ENABLE_MULTILIB="false"

# GPU / display driver
# Options: amd | intel | nvidia | nvidia-open | qemu | vmware | virtualbox | "" (none/headless)
GPU_DRIVER=""

# Desktop environment
# Options: kde | gnome | xfce | i3 | hyprland | sway | "" (none/headless)
# "kde" installs KDE Plasma.
DESKTOP_ENV=""

# Install and enable the daily automated system update timer? (true/false)
ENABLE_AUTO_UPDATE="true"

# AUR helper to install for the regular user (requires USERNAME to be set)
# Options: yay | paru | "" (none)
AUR_HELPER=""

# Encrypt root (and home) partition with LUKS2 at rest? (true/false)
LUKS="false"
LUKS_PASSWORD="${LUKS_PASSWORD:-}"     # LUKS passphrase — prompted interactively if empty

# ==============================================================================
# END OF CONFIGURATION
# ==============================================================================

# Parse command-line flags
DRY_RUN=false
VERIFY_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --verify)   VERIFY_ONLY=true ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

die() {
    error "$@"
    exit 1
}

# ==============================================================================
# CLEANUP TRAP
# ==============================================================================

INSTALL_STARTED=false
INSTALL_COMPLETE=false
LUKS_ROOT_UUID=""
LUKS_HOME_UUID=""
SWAP_INSTALL_MAPPER=""  # set when swap is opened as an encrypted dm-crypt device during install

cleanup() {
    [[ "$INSTALL_COMPLETE" == "true" ]] && return
    [[ "$INSTALL_STARTED" == "false" ]] && return
    error "Installation failed. Cleaning up..."
    if [[ -n "${SWAP_INSTALL_MAPPER:-}" ]]; then
        swapoff "/dev/mapper/${SWAP_INSTALL_MAPPER}" 2>/dev/null || true
        cryptsetup close "${SWAP_INSTALL_MAPPER}" 2>/dev/null || true
    elif [[ -n "${SWAP_PART:-}" ]]; then
        swapoff "$SWAP_PART" 2>/dev/null || true
    fi
    mountpoint -q /mnt && umount -R /mnt 2>/dev/null || true
    [[ "$LUKS" == "true" && -n "${LUKS_HOME_UUID:-}" ]] && { cryptsetup close crypthome 2>/dev/null || true; }
    [[ "$LUKS" == "true" && -n "${LUKS_ROOT_UUID:-}" ]] && { cryptsetup close cryptroot 2>/dev/null || true; }
    error "Cleanup complete. Re-run the installer after fixing the issue."
}

trap cleanup EXIT INT TERM

# ==============================================================================
# COLLECT PASSWORDS
# ==============================================================================

collect_passwords() {
    step "Collecting credentials"

    if [[ -z "$ROOT_PASSWORD" ]]; then
        while true; do
            read -rsp "Enter root password: " ROOT_PASSWORD; echo
            read -rsp "Confirm root password: " _confirm; echo
            if [[ "$ROOT_PASSWORD" != "$_confirm" ]]; then
                warn "Passwords do not match, please try again."
                continue
            fi
            if [[ -z "$ROOT_PASSWORD" ]]; then
                warn "Root password cannot be empty."
                continue
            fi
            if [[ ${#ROOT_PASSWORD} -lt 8 ]]; then
                warn "Password is shorter than 8 characters. Consider using a stronger password."
                read -rp "Continue anyway? [y/N]: " _weak_ok
                [[ "${_weak_ok,,}" == "y" ]] && break
                ROOT_PASSWORD=""
                continue
            fi
            break
        done
    fi

    if [[ -n "$USERNAME" && -z "$USER_PASSWORD" ]]; then
        while true; do
            read -rsp "Enter password for ${USERNAME}: " USER_PASSWORD; echo
            read -rsp "Confirm password for ${USERNAME}: " _confirm; echo
            if [[ "$USER_PASSWORD" != "$_confirm" ]]; then
                warn "Passwords do not match, please try again."
                continue
            fi
            if [[ -z "$USER_PASSWORD" ]]; then
                warn "User password cannot be empty."
                continue
            fi
            if [[ ${#USER_PASSWORD} -lt 8 ]]; then
                warn "Password is shorter than 8 characters. Consider using a stronger password."
                read -rp "Continue anyway? [y/N]: " _weak_ok
                [[ "${_weak_ok,,}" == "y" ]] && break
                USER_PASSWORD=""
                continue
            fi
            break
        done
    fi

    if [[ "$LUKS" == "true" && -z "$LUKS_PASSWORD" ]]; then
        while true; do
            read -rsp "Enter LUKS encryption passphrase: " LUKS_PASSWORD; echo
            read -rsp "Confirm LUKS passphrase: " _confirm; echo
            if [[ "$LUKS_PASSWORD" != "$_confirm" ]]; then
                warn "Passphrases do not match, please try again."
                continue
            fi
            if [[ -z "$LUKS_PASSWORD" ]]; then
                warn "LUKS passphrase cannot be empty."
                continue
            fi
            if [[ ${#LUKS_PASSWORD} -lt 8 ]]; then
                warn "Passphrase is shorter than 8 characters. Consider using a stronger passphrase."
                read -rp "Continue anyway? [y/N]: " _weak_ok
                [[ "${_weak_ok,,}" == "y" ]] && break
                LUKS_PASSWORD=""
                continue
            fi
            break
        done
    fi
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

preflight_checks() {
    step "Running pre-flight checks"

    # Must be root
    [[ "$EUID" -eq 0 ]] || die "This script must be run as root."

    # Must be running from the Arch ISO
    [[ -f /etc/arch-release ]] || die "This script must be run from the Arch Linux live environment."

    # Target disk must exist
    [[ -b "$DISK" ]] || die "Disk $DISK does not exist."

    # Validate configuration values
    [[ "$ROOT_FS" =~ ^(ext4|btrfs|xfs)$ ]]                             || die "Invalid ROOT_FS '$ROOT_FS'. Must be: ext4, btrfs, or xfs."
    [[ "$BOOTLOADER" =~ ^(systemd-boot|grub)$ ]]                       || die "Invalid BOOTLOADER '$BOOTLOADER'. Must be: systemd-boot or grub."
    [[ "$KERNEL" =~ ^(linux|linux-lts|linux-zen|linux-hardened)$ ]]    || die "Invalid KERNEL '$KERNEL'. Must be: linux, linux-lts, linux-zen, or linux-hardened."
    [[ -z "$MICROCODE" || "$MICROCODE" =~ ^(amd-ucode|intel-ucode)$ ]] || die "Invalid MICROCODE '$MICROCODE'. Must be: amd-ucode, intel-ucode, or empty."
    [[ -z "$AUR_HELPER" || "$AUR_HELPER" =~ ^(yay|paru)$ ]]               || die "Invalid AUR_HELPER '$AUR_HELPER'. Must be: yay, paru, or empty."
    [[ -z "$AUR_HELPER" || -n "$USERNAME" ]]                               || die "AUR_HELPER requires USERNAME to be set (AUR helpers should not run as root)."
    # Validate username (useradd constraints + sudoers drop-in filename safety)
    if [[ -n "$USERNAME" ]]; then
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
            || die "Invalid USERNAME '$USERNAME'. Must start with a lowercase letter or underscore, contain only lowercase letters, digits, underscores, or hyphens, and be 1-32 characters."
    fi
    [[ -z "$GPU_DRIVER"  || "$GPU_DRIVER"  =~ ^(amd|intel|nvidia|nvidia-open|qemu|vmware|virtualbox)$ ]] \
                                                                            || die "Invalid GPU_DRIVER '$GPU_DRIVER'. Must be: amd, intel, nvidia, nvidia-open, qemu, vmware, virtualbox, or empty."
    # Normalize "plasma" → "kde" (single canonical name)
    [[ "$DESKTOP_ENV" == "plasma" ]] && DESKTOP_ENV="kde"
    [[ -z "$DESKTOP_ENV" || "$DESKTOP_ENV" =~ ^(kde|gnome|xfce|i3|hyprland|sway)$ ]] \
                                                                            || die "Invalid DESKTOP_ENV '$DESKTOP_ENV'. Must be: kde, gnome, xfce, i3, hyprland, sway, or empty."

    # Validate hostname (RFC 1123: alphanums and hyphens, 1-63 chars, must start/end with alnum)
    if [[ -z "$HOSTNAME" ]]; then
        die "HOSTNAME cannot be empty."
    elif [[ ${#HOSTNAME} -gt 63 ]]; then
        die "HOSTNAME must be 63 characters or fewer."
    elif [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        die "Invalid HOSTNAME '$HOSTNAME'. May only contain letters, digits, and hyphens, and must start/end with a letter or digit."
    fi

    # Validate timezone
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Invalid TIMEZONE '$TIMEZONE'. File /usr/share/zoneinfo/$TIMEZONE does not exist."

    # Validate locale
    if ! grep -q "^#\?${LOCALE} " /etc/locale.gen 2>/dev/null; then
        die "Invalid LOCALE '$LOCALE'. Not found in /etc/locale.gen."
    fi

    # Detect boot mode
    if [[ -d /sys/firmware/efi/efivars ]]; then
        BOOT_MODE="uefi"
        log "Boot mode: UEFI"
    else
        BOOT_MODE="bios"
        log "Boot mode: BIOS (Legacy)"
        if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
            warn "systemd-boot requires UEFI. Switching to GRUB."
            BOOTLOADER="grub"
        fi
    fi

    # Ensure the target disk is not currently mounted or used as swap
    if grep -q "^${DISK}" /proc/mounts 2>/dev/null; then
        die "Disk $DISK (or a partition on it) is currently mounted. Unmount it first."
    fi
    if grep -q "^${DISK}" /proc/swaps 2>/dev/null; then
        die "Disk $DISK (or a partition on it) is currently in use as swap. Run 'swapoff' first."
    fi
    log "Disk not in use: OK"

    # Check internet connectivity
    if ! ping -c 1 -W 5 ping.archlinux.org &>/dev/null; then
        die "No internet connection. Connect to the internet first (e.g., iwctl for Wi-Fi)."
    fi
    log "Internet connection: OK"

    # Determine partition naming scheme: devices whose name ends in a digit
    # (nvme0n1, mmcblk0, loop0, md0, …) need a 'p' separator before the
    # partition number; others (sda, vda, xvda, …) do not.
    if [[ "$DISK" =~ [0-9]$ ]]; then
        PART_PREFIX="${DISK}p"
    else
        PART_PREFIX="${DISK}"
    fi

    log "Target disk: $DISK"
    log "Bootloader: $BOOTLOADER"
    log "Kernel: $KERNEL"
    log "Timezone: $TIMEZONE"
    log "Locale: $LOCALE"
    log "Hostname: $HOSTNAME"
    [[ -n "$GPU_DRIVER" ]]  && log "GPU driver: $GPU_DRIVER"
    [[ -n "$DESKTOP_ENV" ]] && log "Desktop env: $DESKTOP_ENV"

    # Warn about GRUB + LUKS requiring two passphrase prompts at boot.
    # On UEFI, /boot is the unencrypted EFI partition so GRUB reads the kernel
    # without decryption — only the initramfs prompt occurs. The double-prompt
    # issue only affects BIOS where GRUB must unlock the LUKS volume itself.
    if [[ "$LUKS" == "true" && "$BOOTLOADER" == "grub" && "$BOOT_MODE" == "bios" ]]; then
        warn "GRUB + LUKS (BIOS): You will be prompted for the LUKS passphrase TWICE at boot"
        warn "(once for GRUB to read the kernel, once for the initramfs to mount root)."
        warn "Consider using UEFI with systemd-boot to avoid the double prompt."
        echo ""
        read -rp "Continue with GRUB + BIOS + LUKS? [y/N]: " _grub_luks_ok
        [[ "${_grub_luks_ok,,}" == "y" ]] || die "Installation aborted. Re-run with a different BOOTLOADER or disable LUKS."
    fi

    # Parse a size string (e.g., "4G", "512M", "1T") to bytes.
    # A unit suffix is required — bare numbers are rejected.
    _parse_size() {
        local s="$1"
        if [[ ! "$s" =~ ^[0-9]+(\.[0-9]+)?[KkMmGgTt]([Ii][Bb])?$ ]]; then
            die "Invalid size '${s}'. Expected a number with a unit suffix (e.g. 512M, 4G, 1T)."
        fi
        local num unit
        num=$(echo "$s" | sed 's/[^0-9.]//g')
        unit=$(echo "$s" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
        case "$unit" in
            K|KIB) awk "BEGIN{printf \"%d\", $num * 1024}" ;;
            M|MIB) awk "BEGIN{printf \"%d\", $num * 1024 * 1024}" ;;
            G|GIB) awk "BEGIN{printf \"%d\", $num * 1024 * 1024 * 1024}" ;;
            T|TIB) awk "BEGIN{printf \"%d\", $num * 1024 * 1024 * 1024 * 1024}" ;;
        esac
    }

    # Validate all user-provided sizes upfront (even if disk size is unknown)
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        _parse_size "$EFI_SIZE" > /dev/null
        local efi_bytes
        efi_bytes=$(_parse_size "$EFI_SIZE")
        if (( efi_bytes < 268435456 )); then  # 256 MiB minimum
            die "EFI_SIZE '${EFI_SIZE}' is too small. The EFI partition must be at least 256M to fit the kernel, initramfs, and microcode."
        fi
    fi
    [[ -n "$SWAP_SIZE" ]] && _parse_size "$SWAP_SIZE" > /dev/null
    [[ -n "$ROOT_SIZE" ]] && _parse_size "$ROOT_SIZE" > /dev/null

    # Validate disk capacity against requested partition sizes
    local disk_bytes min_root_bytes=8589934592  # 8 GiB minimum for root
    disk_bytes=$(lsblk -bno SIZE "$DISK" 2>/dev/null | head -1)
    if [[ -n "$disk_bytes" ]]; then
        local required=0

        # EFI or BIOS boot partition
        if [[ "$BOOT_MODE" == "uefi" ]]; then
            required=$(( required + $(_parse_size "$EFI_SIZE") ))
        else
            required=$(( required + 1048576 ))  # 1M BIOS boot
        fi

        # Swap
        [[ -n "$SWAP_SIZE" ]] && required=$(( required + $(_parse_size "$SWAP_SIZE") ))

        # Root (fixed size or minimum)
        if [[ -n "$ROOT_SIZE" ]]; then
            required=$(( required + $(_parse_size "$ROOT_SIZE") ))
            # Home takes remaining space — ensure at least 1 GiB is left
            required=$(( required + 1073741824 ))
        else
            required=$(( required + min_root_bytes ))
        fi

        if (( required > disk_bytes )); then
            local disk_gib req_gib
            disk_gib=$(awk "BEGIN{printf \"%.1f\", $disk_bytes / 1073741824}")
            req_gib=$(awk "BEGIN{printf \"%.1f\", $required / 1073741824}")
            die "Disk $DISK is too small (${disk_gib} GiB). The requested layout requires at least ${req_gib} GiB."
        fi
        log "Disk capacity: $(awk "BEGIN{printf \"%.1f\", $disk_bytes / 1073741824}") GiB — OK"
    else
        warn "Could not determine disk size — skipping capacity check"
    fi
}

# ==============================================================================
# CONFIRMATION
# ==============================================================================

confirm_install() {
    step "Disk layout of $DISK"
    fdisk -l "$DISK" 2>/dev/null || true

    echo ""
    warn "ALL DATA ON $DISK WILL BE DESTROYED!"
    echo ""
    read -rp "Type 'YES' to continue: " confirmation
    [[ "$confirmation" == "YES" ]] || die "Installation aborted by user."
}

# ==============================================================================
# UPDATE SYSTEM CLOCK
# ==============================================================================

update_clock() {
    step "Updating system clock"
    timedatectl set-ntp true
    sleep 2
    log "System clock synchronized"
}

# ==============================================================================
# PARTITION THE DISK
# ==============================================================================

partition_disk() {
    step "Partitioning $DISK"

    # Wipe existing partition table
    sgdisk --zap-all "$DISK" &>/dev/null

    local part_num=1

    # Boot partition: EFI (UEFI) or BIOS boot (Legacy)
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        sgdisk -n "${part_num}:0:+${EFI_SIZE}" -t "${part_num}:ef00" -c "${part_num}:EFI" "$DISK"
        EFI_PART="${PART_PREFIX}${part_num}"
    else
        sgdisk -n "${part_num}:0:+1M" -t "${part_num}:ef02" -c "${part_num}:BIOS" "$DISK"
        EFI_PART=""
    fi
    ((part_num++))

    # Swap partition (optional)
    if [[ -n "$SWAP_SIZE" ]]; then
        sgdisk -n "${part_num}:0:+${SWAP_SIZE}" -t "${part_num}:8200" -c "${part_num}:SWAP" "$DISK"
        SWAP_PART="${PART_PREFIX}${part_num}"
        ((part_num++))
    else
        SWAP_PART=""
    fi

    # Root partition (fixed size when ROOT_SIZE is set, otherwise remaining space)
    local root_type="8304"
    [[ "$BOOT_MODE" != "uefi" ]] && root_type="8300"
    if [[ -n "$ROOT_SIZE" ]]; then
        sgdisk -n "${part_num}:0:+${ROOT_SIZE}" -t "${part_num}:${root_type}" -c "${part_num}:ROOT" "$DISK"
    else
        sgdisk -n "${part_num}:0:0" -t "${part_num}:${root_type}" -c "${part_num}:ROOT" "$DISK"
    fi
    ROOT_PART="${PART_PREFIX}${part_num}"
    ((part_num++))

    # Home partition (takes remaining space; created only when ROOT_SIZE is set)
    if [[ -n "$ROOT_SIZE" ]]; then
        sgdisk -n "${part_num}:0:0" -t "${part_num}:8302" -c "${part_num}:HOME" "$DISK"
        HOME_PART="${PART_PREFIX}${part_num}"
    else
        HOME_PART=""
    fi

    # Inform the kernel of partition table changes
    partprobe "$DISK"
    udevadm settle

    # Wait for partition device nodes to appear (some systems are slow)
    local _parts_to_check=("$ROOT_PART")
    [[ -n "${EFI_PART:-}" ]]  && _parts_to_check+=("$EFI_PART")
    [[ -n "${SWAP_PART:-}" ]] && _parts_to_check+=("$SWAP_PART")
    [[ -n "${HOME_PART:-}" ]] && _parts_to_check+=("$HOME_PART")
    for _p in "${_parts_to_check[@]}"; do
        local _wait=0
        while [[ ! -b "$_p" ]]; do
            if (( _wait >= 10 )); then
                die "Partition device node $_p did not appear after 10 seconds. Check kernel logs (dmesg)."
            fi
            sleep 1
            ((_wait++))
        done
    done

    log "Partitioning complete"
    lsblk "$DISK"
}

# ==============================================================================
# FORMAT THE PARTITIONS
# ==============================================================================

format_partitions() {
    step "Formatting partitions"

    # Format EFI partition
    if [[ -n "${EFI_PART:-}" ]]; then
        log "Formatting EFI partition ($EFI_PART) as FAT32"
        mkfs.fat -F 32 "$EFI_PART"
    fi

    # Format swap partition (skip when LUKS is enabled — swap will be
    # opened as a plain dm-crypt device with a random key in mount_filesystems)
    if [[ -n "${SWAP_PART:-}" && "$LUKS" != "true" ]]; then
        log "Formatting swap partition ($SWAP_PART)"
        mkswap "$SWAP_PART"
    fi

    # LUKS encryption — set up containers BEFORE formatting filesystems
    if [[ "$LUKS" == "true" ]]; then
        # GRUB's LUKS2 support only handles PBKDF2; Argon2id (the default) won't boot.
        local luks_extra_args=()
        if [[ "$BOOTLOADER" == "grub" ]]; then
            luks_extra_args=(--pbkdf pbkdf2)
        fi

        log "Setting up LUKS2 encryption on root partition ($ROOT_PART)"
        printf '%s' "$LUKS_PASSWORD" | cryptsetup --batch-mode luksFormat --type luks2 "${luks_extra_args[@]}" "$ROOT_PART"
        LUKS_ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
        printf '%s' "$LUKS_PASSWORD" | cryptsetup --batch-mode open "$ROOT_PART" cryptroot
        ROOT_PART="/dev/mapper/cryptroot"
        log "Opened LUKS root as /dev/mapper/cryptroot (UUID: $LUKS_ROOT_UUID)"

        if [[ -n "${HOME_PART:-}" ]]; then
            log "Setting up LUKS2 encryption on home partition ($HOME_PART)"
            printf '%s' "$LUKS_PASSWORD" | cryptsetup --batch-mode luksFormat --type luks2 "${luks_extra_args[@]}" "$HOME_PART"
            LUKS_HOME_UUID=$(blkid -s UUID -o value "$HOME_PART")
            printf '%s' "$LUKS_PASSWORD" | cryptsetup --batch-mode open "$HOME_PART" crypthome
            HOME_PART="/dev/mapper/crypthome"
            log "Opened LUKS home as /dev/mapper/crypthome (UUID: $LUKS_HOME_UUID)"
        fi
    fi

    # Format home partition (or its LUKS mapper device)
    if [[ -n "${HOME_PART:-}" ]]; then
        log "Formatting home partition ($HOME_PART) as $ROOT_FS"
        case "$ROOT_FS" in
            ext4)  mkfs.ext4 -F "$HOME_PART" ;;
            btrfs) mkfs.btrfs -f "$HOME_PART" ;;
            xfs)   mkfs.xfs -f "$HOME_PART" ;;
            *)     die "Unsupported filesystem: $ROOT_FS" ;;
        esac
    fi

    # Format root partition (or its LUKS mapper device)
    log "Formatting root partition ($ROOT_PART) as $ROOT_FS"
    case "$ROOT_FS" in
        ext4)  mkfs.ext4 -F "$ROOT_PART" ;;
        btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
        xfs)   mkfs.xfs -f "$ROOT_PART" ;;
        *)     die "Unsupported filesystem: $ROOT_FS" ;;
    esac

    log "Formatting complete"
}

# ==============================================================================
# MOUNT THE FILE SYSTEMS
# ==============================================================================

mount_filesystems() {
    step "Mounting file systems"

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        # Temporarily mount to create subvolumes
        mount "$ROOT_PART" /mnt
        log "Creating btrfs subvolumes"
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@log
        btrfs subvolume create /mnt/@cache
        btrfs subvolume create /mnt/@snapshots
        [[ -z "${HOME_PART:-}" ]] && btrfs subvolume create /mnt/@home
        umount /mnt

        # Mount root subvolume
        mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" /mnt
        log "Mounted $ROOT_PART (subvol=@) on /mnt"

        # Mount auxiliary subvolumes
        mount --mkdir -o subvol=@log,compress=zstd,noatime        "$ROOT_PART" /mnt/var/log
        log "Mounted $ROOT_PART (subvol=@log) on /mnt/var/log"
        mount --mkdir -o subvol=@cache,compress=zstd,noatime      "$ROOT_PART" /mnt/var/cache
        log "Mounted $ROOT_PART (subvol=@cache) on /mnt/var/cache"
        mount --mkdir -o subvol=@snapshots,compress=zstd,noatime  "$ROOT_PART" /mnt/.snapshots
        log "Mounted $ROOT_PART (subvol=@snapshots) on /mnt/.snapshots"
    else
        # Non-btrfs: plain mount
        mount "$ROOT_PART" /mnt
        log "Mounted $ROOT_PART on /mnt"
    fi

    # Mount EFI
    if [[ -n "${EFI_PART:-}" ]]; then
        mount --mkdir "$EFI_PART" /mnt/boot
        log "Mounted $EFI_PART on /mnt/boot"
    fi

    # Enable swap
    if [[ -n "${SWAP_PART:-}" ]]; then
        if [[ "$LUKS" == "true" ]]; then
            # Open a plain dm-crypt device with a random key so that any sensitive data
            # written to swap during installation is never stored in plaintext on disk.
            log "Opening encrypted swap (random key) on $SWAP_PART for installation"
            cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 256 \
                --key-file /dev/urandom "$SWAP_PART" cryptswap-install
            SWAP_INSTALL_MAPPER="cryptswap-install"
            mkswap "/dev/mapper/${SWAP_INSTALL_MAPPER}"
            swapon "/dev/mapper/${SWAP_INSTALL_MAPPER}"
            log "Encrypted swap enabled on /dev/mapper/${SWAP_INSTALL_MAPPER}"
        else
            swapon "$SWAP_PART"
            log "Swap enabled on $SWAP_PART"
        fi
    fi

    # Mount home
    if [[ -n "${HOME_PART:-}" ]]; then
        mount --mkdir "$HOME_PART" /mnt/home
        log "Mounted $HOME_PART on /mnt/home"
    elif [[ "$ROOT_FS" == "btrfs" ]]; then
        mount --mkdir -o subvol=@home,compress=zstd,noatime "$ROOT_PART" /mnt/home
        log "Mounted $ROOT_PART (subvol=@home) on /mnt/home"
    fi

    # Create LUKS keyfile for /home to avoid a second passphrase prompt at boot
    if [[ "$LUKS" == "true" && -n "${LUKS_HOME_UUID:-}" ]]; then
        log "Creating LUKS keyfile for crypthome"
        mkdir -p /mnt/etc/cryptsetup-keys.d
        dd bs=512 count=8 iflag=fullblock if=/dev/urandom of=/mnt/etc/cryptsetup-keys.d/crypthome.key 2>/dev/null
        chmod 0000 /mnt/etc/cryptsetup-keys.d/crypthome.key
        printf '%s' "$LUKS_PASSWORD" | cryptsetup luksAddKey \
            "/dev/disk/by-uuid/${LUKS_HOME_UUID}" \
            /mnt/etc/cryptsetup-keys.d/crypthome.key
        log "Keyfile added to crypthome LUKS container"
    fi

}

# NOTE: TPM2 enrollment for LUKS is deferred to a first-boot systemd service
# (see chroot-setup.sh). Enrolling from the live ISO would record the ISO's
# PCR measurements, which won't match the installed system's boot chain.

# ==============================================================================
# SELECT MIRRORS
# ==============================================================================

select_mirrors() {
    step "Configuring package mirrors"

    if [[ "$USE_REFLECTOR" == "true" ]]; then
        log "Using reflector to find fastest mirrors..."
        pacman -S --noconfirm reflector

        local reflector_args=(
            --latest 20
            --sort rate
            --protocol https
            --age 48
            --connection-timeout 5
            --download-timeout 5
            --save /etc/pacman.d/mirrorlist
        )

        if [[ -n "$REFLECTOR_COUNTRY" ]]; then
            reflector_args+=(--country "$REFLECTOR_COUNTRY")
        fi

        if reflector "${reflector_args[@]}"; then
            log "Mirror list updated"
        else
            warn "reflector failed — continuing with existing mirror list"
            warn "If pacstrap times out, mirrors may be stale. Run reflector manually."
        fi
    else
        log "Using default mirror list"
    fi
}

# ==============================================================================
# INSTALL ESSENTIAL PACKAGES
# ==============================================================================

build_package_list() {
    local -n _pkgs=$1
    _pkgs=(base "$KERNEL" linux-firmware)

    [[ -n "$MICROCODE" ]] && _pkgs+=("$MICROCODE")

    case "$ROOT_FS" in
        btrfs)
            _pkgs+=(btrfs-progs snapper snap-pac)
            [[ "$BOOTLOADER" == "grub" ]] && _pkgs+=(grub-btrfs)
            ;;
        xfs)   _pkgs+=(xfsprogs) ;;
    esac

    if [[ "$BOOTLOADER" == "grub" ]]; then
        _pkgs+=(grub)
        [[ "$BOOT_MODE" == "uefi" ]] && _pkgs+=(efibootmgr)
    fi

    if [[ -n "$EXTRA_PACKAGES" ]]; then
        local -a extra
        read -ra extra <<< "$EXTRA_PACKAGES"
        _pkgs+=("${extra[@]}")
    fi

    [[ "$USE_REFLECTOR" == "true" ]] && _pkgs+=(reflector)
    [[ "$LUKS" == "true" ]] && _pkgs+=(cryptsetup)

    # sudo is required for the user account sudoers drop-ins, AUR helper, and
    # auto-update notifications. base-devel normally pulls it in, but if the
    # user customises EXTRA_PACKAGES we must guarantee it explicitly.
    [[ -n "$USERNAME" ]] && _pkgs+=(sudo)

    case "$GPU_DRIVER" in
        amd)         _pkgs+=(mesa xf86-video-amdgpu vulkan-radeon libva-mesa-driver) ;;
        # xf86-video-intel is deprecated upstream; the modesetting DDX (built into
        # Xorg) is preferred and handles modern Intel GPUs better.
        intel)       _pkgs+=(mesa vulkan-intel intel-media-driver) ;;
        nvidia)
            # nvidia is kernel-specific; pick the right variant
            case "$KERNEL" in
                linux)          _pkgs+=(nvidia) ;;
                linux-lts)      _pkgs+=(nvidia-lts) ;;
                *)              _pkgs+=(nvidia-dkms) ;;
            esac
            _pkgs+=("${KERNEL}-headers" nvidia-utils nvidia-settings)
            ;;
        nvidia-open)
            case "$KERNEL" in
                linux)          _pkgs+=(nvidia-open) ;;
                *)              _pkgs+=(nvidia-open-dkms) ;;
            esac
            _pkgs+=("${KERNEL}-headers" nvidia-utils nvidia-settings)
            ;;
        qemu)        _pkgs+=(mesa qemu-guest-agent spice-vdagent) ;;
        vmware)      _pkgs+=(xf86-video-vmware open-vm-tools) ;;
        virtualbox)  _pkgs+=(virtualbox-guest-utils) ;;
    esac

    case "$DESKTOP_ENV" in
        kde) _pkgs+=(plasma-meta sddm dolphin konsole kate gwenview spectacle) ;;
        gnome)      _pkgs+=(gnome gdm) ;;
        xfce)       _pkgs+=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xorg-server) ;;
        i3)         _pkgs+=(i3-wm i3status i3lock dmenu xorg-server xorg-xinit lightdm lightdm-gtk-greeter xterm) ;;
        hyprland)   _pkgs+=(hyprland xdg-desktop-portal-hyprland kitty wofi sddm polkit-kde-agent qt5-wayland qt6-wayland) ;;
        sway)       _pkgs+=(sway swaybg swayidle swaylock foot wofi xorg-xwayland sddm polkit-kde-agent) ;;
    esac
}

install_base() {
    step "Installing base system"

    local -a packages
    build_package_list packages

    log "Initializing pacman keyring"
    pacman-key --init
    pacman-key --populate archlinux

    # Pre-create vconsole.conf so the mkinitcpio hook triggered by the kernel
    # package during pacstrap finds it (sd-vconsole requires this file).
    mkdir -p /mnt/etc
    echo "KEYMAP=${KEYMAP}" > /mnt/etc/vconsole.conf

    log "Packages: ${packages[@]}"
    if ! pacstrap -K /mnt "${packages[@]}"; then
        die "pacstrap failed. Check package names in EXTRA_PACKAGES and ensure mirrors are reachable."
    fi
    log "Base system installed"
}

# ==============================================================================
# GENERATE FSTAB
# ==============================================================================

generate_fstab() {
    step "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab
    log "fstab generated:"
    cat /mnt/etc/fstab
}

# ==============================================================================
# CHROOT CONFIGURATION
# ==============================================================================

configure_system() {
    step "Configuring installed system (chroot)"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Verify companion scripts are present
    [[ -f "${script_dir}/chroot-setup.sh" ]] || die "chroot-setup.sh not found next to install.sh"
    [[ -f "${script_dir}/update.sh" ]]        || die "update.sh not found next to install.sh"

    # snapshot-manager.sh lives in tools/ in the repo, but may be copied as a
    # sibling when launched from the TUI or automated installer work directory.
    local snapshot_manager=""
    if [[ -f "${script_dir}/../tools/snapshot-manager.sh" ]]; then
        snapshot_manager="${script_dir}/../tools/snapshot-manager.sh"
    elif [[ -f "${script_dir}/snapshot-manager.sh" ]]; then
        snapshot_manager="${script_dir}/snapshot-manager.sh"
    else
        die "snapshot-manager.sh not found (checked ../tools/ and script directory)"
    fi

    [[ -f "${script_dir}/update-check.sh" ]] || die "update-check.sh not found next to install.sh"

    # Stage scripts inside the new system's /root (not /tmp, because
    # arch-chroot mounts a fresh tmpfs on /tmp that hides existing files)
    cp "${script_dir}/chroot-setup.sh" /mnt/root/chroot-setup.sh
    cp "${script_dir}/update.sh"       /mnt/root/update.sh
    cp "$snapshot_manager" /mnt/root/snapshot-manager.sh
    cp "${script_dir}/update-check.sh" /mnt/root/update-check.sh

    # Substitute placeholder variables (non-sensitive only)
    # Passwords are passed via environment variables to avoid writing them to disk
    sed -i \
        -e "s|__TIMEZONE__|${TIMEZONE}|g" \
        -e "s|__LOCALE__|${LOCALE}|g" \
        -e "s|__KEYMAP__|${KEYMAP}|g" \
        -e "s|__HOSTNAME__|${HOSTNAME}|g" \
        -e "s|__KERNEL__|${KERNEL}|g" \
        -e "s|__BOOT_MODE__|${BOOT_MODE}|g" \
        -e "s|__BOOTLOADER__|${BOOTLOADER}|g" \
        -e "s|__DISK__|${DISK}|g" \
        -e "s|__MICROCODE__|${MICROCODE}|g" \
        -e "s|__ENABLE_MULTILIB__|${ENABLE_MULTILIB}|g" \
        -e "s|__ROOT_FS__|${ROOT_FS}|g" \
        -e "s|__GPU_DRIVER__|${GPU_DRIVER}|g" \
        -e "s|__DESKTOP_ENV__|${DESKTOP_ENV}|g" \
        -e "s|__ENABLE_AUTO_UPDATE__|${ENABLE_AUTO_UPDATE}|g" \
        -e "s|__LUKS__|${LUKS}|g" \
        -e "s|__LUKS_ROOT_UUID__|${LUKS_ROOT_UUID}|g" \
        -e "s|__LUKS_HOME_UUID__|${LUKS_HOME_UUID}|g" \
        -e "s|__SWAP_PART__|${SWAP_PART:-}|g" \
        -e "s|__AUR_HELPER__|${AUR_HELPER}|g" \
        -e "s|__REFLECTOR_COUNTRY__|${REFLECTOR_COUNTRY}|g" \
        /mnt/root/chroot-setup.sh

    sed -i \
        -e "s|__NOTIFY_USER__|${USERNAME}|g" \
        /mnt/root/update.sh

    chmod +x /mnt/root/chroot-setup.sh
    # Pass passwords via environment so they are never written to the staged script file.
    # NOTE: Environment variables are readable in /proc/<pid>/environ by root processes.
    # This is acceptable on a single-user live ISO; no untrusted code is running.
    arch-chroot /mnt \
        env \
        ROOT_PASSWORD="${ROOT_PASSWORD}" \
        USERNAME="${USERNAME}" \
        USER_PASSWORD="${USER_PASSWORD}" \
        /root/chroot-setup.sh

    # Deploy snapshot-manager for convenient access from the installed system
    if [[ "$ROOT_FS" == "btrfs" ]]; then
        install -Dm0755 /mnt/root/snapshot-manager.sh /mnt/usr/local/bin/snapshot-manager
        log "snapshot-manager deployed to /usr/local/bin/snapshot-manager"
    fi

    # Stage verify-install.sh for post-install smoke test
    if [[ -f "${script_dir}/verify-install.sh" ]]; then
        cp "${script_dir}/verify-install.sh" /mnt/root/verify-install.sh
        sed -i \
            -e "s|__KERNEL__|${KERNEL}|g" \
            -e "s|__BOOTLOADER__|${BOOTLOADER}|g" \
            -e "s|__ROOT_FS__|${ROOT_FS}|g" \
            -e "s|__TIMEZONE__|${TIMEZONE}|g" \
            -e "s|__LOCALE__|${LOCALE}|g" \
            -e "s|__HOSTNAME__|${HOSTNAME}|g" \
            -e "s|__MICROCODE__|${MICROCODE}|g" \
            -e "s|__LUKS__|${LUKS}|g" \
            -e "s|__LUKS_HOME_UUID__|${LUKS_HOME_UUID}|g" \
            -e "s|__DESKTOP_ENV__|${DESKTOP_ENV}|g" \
            /mnt/root/verify-install.sh
        chmod +x /mnt/root/verify-install.sh
    fi

    # Clean up staging files (keep verify-install.sh for run_verification)
    rm -f /mnt/root/chroot-setup.sh /mnt/root/update.sh /mnt/root/snapshot-manager.sh /mnt/root/update-check.sh

    # Clean pacman package cache to save disk space
    step "Cleaning pacman package cache"
    arch-chroot /mnt bash -c 'paccache -rk1 2>/dev/null || pacman -Scc --noconfirm' 2>/dev/null || true
    log "Package cache cleaned"
}

# ==============================================================================
# 4. REBOOT
# ==============================================================================

finish_install() {
    step "Installation complete!"

    echo ""
    log "Unmounting filesystems..."
    INSTALL_COMPLETE=true
    if [[ -n "${SWAP_INSTALL_MAPPER:-}" ]]; then
        swapoff "/dev/mapper/${SWAP_INSTALL_MAPPER}" 2>/dev/null || true
        cryptsetup close "${SWAP_INSTALL_MAPPER}" 2>/dev/null || true
    elif [[ -n "${SWAP_PART:-}" ]]; then
        swapoff "$SWAP_PART"
    fi
    umount -R /mnt

    echo ""
    log "============================================"
    log "  Arch Linux has been installed!            "
    log "============================================"
    log ""
    log "  Hostname : $HOSTNAME"
    log "  Kernel   : $KERNEL"
    log "  Bootloader: $BOOTLOADER"
    log "  Timezone : $TIMEZONE"
    log "  Locale   : $LOCALE"
    [[ -n "$USERNAME" ]]    && log "  User       : $USERNAME (full sudo access)"
    [[ -n "$GPU_DRIVER" ]]  && log "  GPU Driver : $GPU_DRIVER"
    [[ -n "$DESKTOP_ENV" ]] && log "  Desktop    : $DESKTOP_ENV"
    [[ -n "${HOME_PART:-}" ]] && log "  /home      : $HOME_PART (remaining space)"
    log ""
    log "  Remove the installation medium and reboot."
    log "============================================"
    echo ""

    if [[ "$REQUIRE_REBOOT_CONFIRMATION" == true ]]; then
        read -rp "Reboot now? [y/N]: " do_reboot
        if [[ "${do_reboot,,}" == "y" ]]; then
            reboot
        fi
    else
        reboot
    fi
}

# ==============================================================================
# DRY-RUN SUMMARY
# ==============================================================================

dry_run_summary() {
    step "Dry-run summary (no changes will be made)"
    echo ""
    log "Disk        : $DISK"
    log "Boot mode   : $BOOT_MODE"
    log "Bootloader  : $BOOTLOADER"
    log "Kernel      : $KERNEL"
    log "Root FS     : $ROOT_FS"
    log "Timezone    : $TIMEZONE"
    log "Locale      : $LOCALE"
    log "Keymap      : $KEYMAP"
    log "Hostname    : $HOSTNAME"
    [[ -n "$MICROCODE" ]]  && log "Microcode   : $MICROCODE"
    [[ -n "$GPU_DRIVER" ]] && log "GPU driver  : $GPU_DRIVER"
    [[ -n "$DESKTOP_ENV" ]] && log "Desktop     : $DESKTOP_ENV"
    [[ -n "$USERNAME" ]]   && log "User        : $USERNAME"
    [[ -n "$AUR_HELPER" ]] && log "AUR helper  : $AUR_HELPER"
    [[ "$LUKS" == "true" ]]  && log "LUKS        : enabled"
    echo ""

    step "Partition layout"
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        log "  ${PART_PREFIX}1 : EFI  ($EFI_SIZE, FAT32)"
        local n=2
    else
        log "  ${PART_PREFIX}1 : BIOS boot (1M)"
        local n=2
    fi
    if [[ -n "$SWAP_SIZE" ]]; then
        log "  ${PART_PREFIX}${n} : swap ($SWAP_SIZE)$([ "$LUKS" == "true" ] && echo ' [encrypted, random key]')"
        ((n++))
    fi
    if [[ -n "$ROOT_SIZE" ]]; then
        log "  ${PART_PREFIX}${n} : /     ($ROOT_SIZE, $ROOT_FS)$([ "$LUKS" == "true" ] && echo ' [LUKS2]')"
        ((n++))
        log "  ${PART_PREFIX}${n} : /home (remaining, $ROOT_FS)$([ "$LUKS" == "true" ] && echo ' [LUKS2]')"
    else
        log "  ${PART_PREFIX}${n} : /     (remaining, $ROOT_FS)$([ "$LUKS" == "true" ] && echo ' [LUKS2]')"
    fi

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        echo ""
        step "Btrfs subvolumes"
        log "  @           -> /"
        log "  @log        -> /var/log"
        log "  @cache      -> /var/cache"
        log "  @snapshots  -> /.snapshots  (managed by snapper)"
        [[ -z "$ROOT_SIZE" ]] && log "  @home       -> /home"
        echo ""
        step "Snapper configuration"
        log "  Timeline snapshots: hourly (keep 5 hourly, 7 daily)"
        log "  snap-pac: pre/post snapshots on every pacman transaction"
        log "  Cleanup: snapper-cleanup.timer (automatic)"
    fi

    echo ""
    step "Packages"
    local -a packages
    build_package_list packages
    log "  ${packages[@]}"

    echo ""
    log "Dry run complete. No changes were made."
    log "Remove --dry-run to perform the actual installation."
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    echo ""
    echo "============================================"
    echo "  Arch Linux Automated Installer           "
    echo "============================================"
    echo ""

    # Log all output to a file while preserving terminal display
    local install_log
    install_log="/tmp/arch-install-$(date '+%Y%m%d-%H%M%S').log"
    log "Logging to $install_log"
    exec > >(tee -a "$install_log") 2>&1

    preflight_checks

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_summary
        return 0
    fi

    if [[ "$VERIFY_ONLY" == true ]]; then
        # Standalone verification — arch-chroot into /mnt and run checks
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ ! -f "${script_dir}/verify-install.sh" ]]; then
            die "verify-install.sh not found next to install.sh"
        fi
        mountpoint -q /mnt || die "/mnt is not mounted — mount the installed system first"
        cp "${script_dir}/verify-install.sh" /mnt/root/verify-install.sh
        sed -i \
            -e "s|__KERNEL__|${KERNEL}|g" \
            -e "s|__BOOTLOADER__|${BOOTLOADER}|g" \
            -e "s|__ROOT_FS__|${ROOT_FS}|g" \
            -e "s|__TIMEZONE__|${TIMEZONE}|g" \
            -e "s|__LOCALE__|${LOCALE}|g" \
            -e "s|__HOSTNAME__|${HOSTNAME}|g" \
            -e "s|__MICROCODE__|${MICROCODE}|g" \
            -e "s|__LUKS__|${LUKS}|g" \
            -e "s|__LUKS_HOME_UUID__|${LUKS_HOME_UUID}|g" \
            -e "s|__DESKTOP_ENV__|${DESKTOP_ENV}|g" \
            /mnt/root/verify-install.sh
        chmod +x /mnt/root/verify-install.sh
        step "Running post-install verification (standalone)"
        arch-chroot /mnt \
            env USERNAME="${USERNAME}" \
            /root/verify-install.sh
        local rc=$?
        rm -f /mnt/root/verify-install.sh
        return "$rc"
    fi

    if [[ "$REQUIRE_WIPE_CONFIRMATION" == true ]]; then
        confirm_install
    fi

    collect_passwords
    update_clock
    INSTALL_STARTED=true
    partition_disk
    format_partitions
    mount_filesystems
    select_mirrors
    install_base
    generate_fstab
    configure_system

    # Post-install smoke test (runs by default)
    if [[ -f /mnt/root/verify-install.sh ]]; then
        step "Running post-install verification"
        arch-chroot /mnt \
            env USERNAME="${USERNAME}" \
            /root/verify-install.sh || true
        rm -f /mnt/root/verify-install.sh
    fi

    # Copy the install log to the new system before unmounting
    cp "$install_log" /mnt/var/log/arch-install.log 2>/dev/null || true

    finish_install
}

main "$@"
