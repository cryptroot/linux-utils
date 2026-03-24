#!/usr/bin/env bash
#
# Arch Linux installation TUI wizard
#
# Walks the user through all configuration options for install.sh,
# then launches install.sh with the chosen settings applied.
#
# Usage:
#   bash install-tui.sh
#
# Requirements:
#   dialog — installed automatically if missing (requires internet + pacman)
#
# All scripts (install.sh, chroot-setup.sh, snapshot-manager.sh, update-manager.sh) must be in
# the same directory or tools/ subdirectory as this file.

set -euo pipefail

# ==============================================================================
# BOOTSTRAP — ensure dialog is available
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v dialog &>/dev/null; then
    echo "The 'dialog' package is required but not installed."
    read -rp "Install it now with pacman? [Y/n] " _ans
    if [[ "${_ans,,}" != "n" ]]; then
        pacman -S --noconfirm --needed dialog
    else
        echo "Cannot continue without dialog. Exiting."
        exit 1
    fi
fi

# ==============================================================================
# TEMP FILE & CLEANUP
# ==============================================================================

TMPFILE="$(mktemp /tmp/arch-tui-XXXXXX)"
chmod 600 "$TMPFILE"

cleanup() {
    # Overwrite temp file before removal to avoid leaving passwords on disk
    if [[ -f "$TMPFILE" ]]; then
        if command -v shred &>/dev/null; then
            shred -u "$TMPFILE" 2>/dev/null || rm -f "$TMPFILE"
        else
            dd if=/dev/zero of="$TMPFILE" bs=1 count="$(stat -c %s "$TMPFILE" 2>/dev/null || echo 1024)" conv=notrunc 2>/dev/null || true
            rm -f "$TMPFILE"
        fi
    fi
}
trap cleanup EXIT INT TERM

# ==============================================================================
# DIALOG HELPERS
# ==============================================================================

TITLE="Arch Linux Installer"
DH=20   # default height
DW=70   # default width

# show_menu <text> <tag desc...>
# Writes chosen tag to $TMPFILE. Returns 0 on OK, 1 on Cancel/Back.
show_menu() {
    local text="$1"; shift
    local -a items=("$@")
    dialog --clear --backtitle "$TITLE" \
           --title "$(echo "$text" | head -1)" \
           --menu "$text" $DH $DW 10 \
           "${items[@]}" 2>"$TMPFILE"
}

# show_input <title> <text> <default>
# Writes input to $TMPFILE. Returns 0 on OK, 1 on Cancel/Back.
show_input() {
    local title="$1" text="$2" default="$3"
    dialog --clear --backtitle "$TITLE" \
           --title "$title" \
           --inputbox "$text" $DH $DW "$default" 2>"$TMPFILE"
}

# show_password <title> <text>
# Writes password to $TMPFILE. Returns 0 on OK, 1 on Cancel/Back.
show_password() {
    local title="$1" text="$2"
    dialog --clear --backtitle "$TITLE" \
           --title "$title" \
           --passwordbox "$text" 10 $DW "" 2>"$TMPFILE"
}

# show_yesno <title> <text>
# Returns 0 for Yes, 1 for No.
show_yesno() {
    local title="$1" text="$2"
    dialog --clear --backtitle "$TITLE" \
           --title "$title" \
           --yesno "$text" 10 $DW
}

# show_checklist <title> <text> <tag desc status...>
# Writes space-separated selected tags to $TMPFILE. Returns 0/1.
show_checklist() {
    local title="$1" text="$2"; shift 2
    local -a items=("$@")
    dialog --clear --backtitle "$TITLE" \
           --title "$title" \
           --checklist "$text" $DH $DW 10 \
           "${items[@]}" 2>"$TMPFILE"
}

# show_msg <title> <text>
show_msg() {
    local title="$1" text="$2"
    dialog --clear --backtitle "$TITLE" \
           --title "$title" \
           --msgbox "$text" $DH $DW
}

# ==============================================================================
# CONFIG DEFAULTS
# ==============================================================================

DISK="/dev/sda"
EFI_SIZE="512M"
SWAP_SIZE="4G"
ROOT_SIZE=""
ROOT_FS="ext4"
LUKS="false"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"
HOSTNAME="archlinux"
KERNEL="linux"
MICROCODE=""
BOOTLOADER="systemd-boot"
GPU_DRIVER=""
DESKTOP_ENV=""
EXTRA_PACKAGES="nano networkmanager base-devel openssh"
USERNAME=""
AUR_HELPER=""
USE_REFLECTOR="true"
REFLECTOR_COUNTRY=""
ENABLE_MULTILIB="false"
ENABLE_AUTO_UPDATE="true"
ROOT_PASSWORD=""
USER_PASSWORD=""
LUKS_PASSWORD=""

# ==============================================================================
# STEP MACHINE
# ==============================================================================

STEP=1
MAX_STEP=21   # last step = passwords; handoff is post-loop

while [[ "$STEP" -le "$MAX_STEP" ]]; do
    case "$STEP" in

    # --------------------------------------------------------------------------
    # 1: WELCOME
    # --------------------------------------------------------------------------
    1)
        show_msg "Welcome" \
"Arch Linux Installation Wizard

This wizard will guide you through configuring your Arch Linux
installation. At the end, it will launch the automated installer
(install.sh) with your chosen settings.

WARNING: The installation will DESTROY all data on the target disk.
         Review every option carefully before proceeding.

Press OK to begin."
        STEP=$(( STEP + 1 ))
        ;;

    # --------------------------------------------------------------------------
    # 2: DISK SELECTION
    # --------------------------------------------------------------------------
    2)
        # Build menu items from lsblk — exclude loop/rom/sr devices
        declare -a DISK_ITEMS=()
        while IFS= read -r line; do
            dev=$(echo "$line" | awk '{print $1}')
            size=$(echo "$line" | awk '{print $2}')
            model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
            [[ -z "$model" ]] && model="(no model)"
            DISK_ITEMS+=("$dev" "${size}  ${model}")
        done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null \
                 | grep -v -E "^/dev/(loop|sr|fd|ram)" || true)

        if [[ ${#DISK_ITEMS[@]} -eq 0 ]]; then
            show_msg "No Disks Found" \
"No block devices were detected.

Please enter the disk path manually (e.g. /dev/sda)."
            if show_input "Target Disk" "Enter target disk device path:" "$DISK"; then
                DISK="$(cat "$TMPFILE")"
                STEP=$(( STEP + 1 ))
            fi
            # If cancelled at manual input, stay on step 2
        else
            if show_menu "Select the disk to install Arch Linux on.

WARNING: All data on the selected disk will be erased." \
                    "${DISK_ITEMS[@]}"; then
                DISK="$(cat "$TMPFILE")"
                STEP=$(( STEP + 1 ))
            else
                STEP=$(( STEP - 1 ))  # back to welcome
                [[ "$STEP" -lt 1 ]] && STEP=1
            fi
        fi
        unset DISK_ITEMS
        ;;

    # --------------------------------------------------------------------------
    # 3: PARTITION SIZES
    # --------------------------------------------------------------------------
    3)
        if show_input "Swap Partition Size" \
"Enter the swap partition size (e.g. 4G, 8G).
Leave empty to skip creating a swap partition." \
                "$SWAP_SIZE"; then
            SWAP_SIZE="$(cat "$TMPFILE")"
            if show_input "Root Partition Size" \
"Enter the root partition size (e.g. 50G, 100G).
/home will use the remaining disk space.
Leave empty to use the entire disk for root (no separate /home)." \
                    "$ROOT_SIZE"; then
                ROOT_SIZE="$(cat "$TMPFILE")"
                STEP=$(( STEP + 1 ))
            else
                STEP=$(( STEP - 1 ))
            fi
        else
            STEP=$(( STEP - 1 ))
            [[ "$STEP" -lt 1 ]] && STEP=1
        fi
        ;;

    # --------------------------------------------------------------------------
    # 4: FILESYSTEM
    # --------------------------------------------------------------------------
    4)
        if show_menu "Root Filesystem Type

Select the filesystem for the root (and home) partition." \
                "ext4"  "ext4   — stable, widely supported  (recommended)" \
                "btrfs" "btrfs  — snapshots, compression, copy-on-write" \
                "xfs"   "xfs    — high-performance, good for large files"; then
            ROOT_FS="$(cat "$TMPFILE")"
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 5: LUKS ENCRYPTION
    # --------------------------------------------------------------------------
    5)
        if show_yesno "Full-Disk Encryption (LUKS2)" \
"Enable LUKS2 encryption on the root (and home) partition?

You will be prompted for a LUKS passphrase later.
Without this, data on disk is readable without a password."; then
            LUKS="true"
        else
            LUKS="false"
        fi
        STEP=$(( STEP + 1 ))
        ;;

    # --------------------------------------------------------------------------
    # 6: TIMEZONE — region
    # --------------------------------------------------------------------------
    6)
        # Build region list from /usr/share/zoneinfo (directories only)
        declare -a REGION_ITEMS=()
        if [[ -d /usr/share/zoneinfo ]]; then
            while IFS= read -r dir; do
                region="$(basename "$dir")"
                REGION_ITEMS+=("$region" "$region")
            done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d \
                          ! -name "posix" ! -name "right" | sort)
        fi

        # Also add common flat-file timezones and an Other option
        if [[ -d /usr/share/zoneinfo ]]; then
            while IFS= read -r tz; do
                name="$(basename "$tz")"
                # Skip posix/right aliases and leap-seconds table
                [[ "$name" =~ ^(leap-seconds|leap_seconds|posixrules|zone\.tab|zone1970\.tab|\.+)$ ]] && continue
                REGION_ITEMS+=("$name" "$name")
            done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type f | sort)
        fi
        REGION_ITEMS+=("Other" "Enter timezone manually...")

        if [[ ${#REGION_ITEMS[@]} -eq 0 ]]; then
            # Fallback to manual input
            if show_input "Timezone" \
"Enter your timezone (e.g. America/New_York, Europe/London, UTC):" \
                    "$TIMEZONE"; then
                TIMEZONE="$(cat "$TMPFILE")"
                STEP=$(( STEP + 1 ))
            else
                STEP=$(( STEP - 1 ))
            fi
        else
            if show_menu "Timezone — Select Region" "${REGION_ITEMS[@]}"; then
                TZ_REGION="$(cat "$TMPFILE")"
                if [[ "$TZ_REGION" == "Other" ]]; then
                    # Manual input
                    if show_input "Timezone" \
"Enter your timezone (e.g. America/New_York, Europe/London, UTC):" \
                            "$TIMEZONE"; then
                        TIMEZONE="$(cat "$TMPFILE")"
                        TZ_REGION=""
                        STEP=$(( STEP + 2 ))  # skip city step
                    fi
                    # Cancelled → stay on step 6
                elif [[ ! -d "/usr/share/zoneinfo/$TZ_REGION" ]]; then
                    # Flat-file timezone (e.g. UTC, CET) — no city step needed
                    TIMEZONE="$TZ_REGION"
                    TZ_REGION=""
                    STEP=$(( STEP + 2 ))  # skip city step
                else
                    STEP=$(( STEP + 1 ))  # advance to city selection
                fi
            else
                STEP=$(( STEP - 1 ))
                TZ_REGION=""
            fi
        fi
        unset REGION_ITEMS
        ;;

    # --------------------------------------------------------------------------
    # 7: TIMEZONE — city
    # --------------------------------------------------------------------------
    7)
        if [[ -n "${TZ_REGION:-}" && -d "/usr/share/zoneinfo/$TZ_REGION" ]]; then
            declare -a CITY_ITEMS=()
            # Add sub-directories as selectable regions (e.g. America/Indiana/...)
            while IFS= read -r tz; do
                name="$(basename "$tz")"
                CITY_ITEMS+=("$name" "$name")
            done < <(find "/usr/share/zoneinfo/$TZ_REGION" -maxdepth 1 \( -type f -o -type l \) | sort)

            if show_menu "Timezone — Select City/Zone (${TZ_REGION})" \
                    "${CITY_ITEMS[@]}"; then
                TIMEZONE="${TZ_REGION}/$(cat "$TMPFILE")"
                STEP=$(( STEP + 1 ))
            else
                STEP=$(( STEP - 1 ))  # back to region
            fi
            unset CITY_ITEMS
        else
            # TZ_REGION is empty — either a flat-file/manual timezone was chosen in step 6
            # (which already advanced STEP past here), or we're navigating backwards from
            # step 8. In either case, skip back to step 6 so the user can re-select.
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 8: LOCALE
    # --------------------------------------------------------------------------
    8)
        if show_menu "System Locale" \
                "en_US.UTF-8" "English (United States)" \
                "en_GB.UTF-8" "English (United Kingdom)" \
                "de_DE.UTF-8" "German" \
                "fr_FR.UTF-8" "French" \
                "es_ES.UTF-8" "Spanish" \
                "pt_BR.UTF-8" "Portuguese (Brazil)" \
                "it_IT.UTF-8" "Italian" \
                "nl_NL.UTF-8" "Dutch" \
                "ru_RU.UTF-8" "Russian" \
                "ja_JP.UTF-8" "Japanese" \
                "zh_CN.UTF-8" "Chinese (Simplified)" \
                "Other"       "Enter a custom locale..."; then
            _sel="$(cat "$TMPFILE")"
            if [[ "$_sel" == "Other" ]]; then
                if show_input "Custom Locale" \
"Enter the locale string exactly as it appears in /etc/locale.gen
(e.g. pl_PL.UTF-8, ko_KR.UTF-8):" \
                        "$LOCALE"; then
                    LOCALE="$(cat "$TMPFILE")"
                    STEP=$(( STEP + 1 ))
                fi
                # if cancelled on custom input, stay on step 8
            else
                LOCALE="$_sel"
                STEP=$(( STEP + 1 ))
            fi
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 9: KEYMAP
    # --------------------------------------------------------------------------
    9)
        if show_menu "Console Keyboard Layout" \
                "us"     "US (English)" \
                "uk"     "UK (British)" \
                "de"     "German" \
                "de-latin1" "German (latin1)" \
                "fr"     "French" \
                "es"     "Spanish" \
                "it"     "Italian" \
                "pt-latin1" "Portuguese" \
                "br-abnt2"  "Portuguese (Brazilian ABNT2)" \
                "ru"     "Russian" \
                "jp106"  "Japanese" \
                "dvorak" "Dvorak" \
                "Other"  "Enter a custom keymap..."; then
            _sel="$(cat "$TMPFILE")"
            if [[ "$_sel" == "Other" ]]; then
                if show_input "Custom Keymap" \
"Enter the keymap name (run 'localectl list-keymaps' for a full list):" \
                        "$KEYMAP"; then
                    KEYMAP="$(cat "$TMPFILE")"
                    STEP=$(( STEP + 1 ))
                fi
            else
                KEYMAP="$_sel"
                STEP=$(( STEP + 1 ))
            fi
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 10: HOSTNAME
    # --------------------------------------------------------------------------
    10)
        if show_input "Hostname" \
"Enter the hostname for this machine
(letters, digits, and hyphens only; e.g. my-arch-pc):" \
                "$HOSTNAME"; then
            _h="$(cat "$TMPFILE")"
            if [[ -z "$_h" ]]; then
                show_msg "Invalid Hostname" "Hostname cannot be empty. Please try again."
                # stay on step 10
            elif [[ ${#_h} -gt 63 ]]; then
                show_msg "Invalid Hostname" "Hostname must be 63 characters or fewer."
            elif [[ ! "$_h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
                show_msg "Invalid Hostname" \
"Hostname may only contain letters, digits, and hyphens.
It must start and end with a letter or digit."
            else
                HOSTNAME="$_h"
                STEP=$(( STEP + 1 ))
            fi
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 11: KERNEL
    # --------------------------------------------------------------------------
    11)
        if show_menu "Kernel Package" \
                "linux"          "linux          — latest stable kernel (recommended)" \
                "linux-lts"      "linux-lts      — long-term support kernel" \
                "linux-zen"      "linux-zen      — performance/desktop-tuned kernel" \
                "linux-hardened" "linux-hardened — security-hardened kernel"; then
            KERNEL="$(cat "$TMPFILE")"
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 12: MICROCODE
    # --------------------------------------------------------------------------
    12)
        # Auto-detect CPU vendor to pre-select microcode
        _auto_ucode=""
        if command -v lscpu &>/dev/null; then
            _cpu_vendor=$(lscpu 2>/dev/null | grep -i 'vendor' | head -1 || true)
            if [[ "$_cpu_vendor" == *"Intel"* ]]; then
                _auto_ucode="intel-ucode"
            elif [[ "$_cpu_vendor" == *"AMD"* || "$_cpu_vendor" == *"AuthenticAMD"* ]]; then
                _auto_ucode="amd-ucode"
            fi
        fi
        _detect_hint=""
        [[ -n "$_auto_ucode" ]] && _detect_hint="\n\nDetected: $_auto_ucode"

        if show_menu "CPU Microcode${_detect_hint}" \
                ""            "None / VM — no microcode updates needed" \
                "intel-ucode" "intel-ucode — Intel CPU" \
                "amd-ucode"   "amd-ucode   — AMD CPU"; then
            MICROCODE="$(cat "$TMPFILE")"
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 13: BOOTLOADER
    # --------------------------------------------------------------------------
    13)
        # Detect boot mode to warn about systemd-boot on BIOS
        _bios_warn=""
        if [[ ! -d /sys/firmware/efi/efivars ]]; then
            _bios_warn="\n\nNote: BIOS (Legacy) boot detected. systemd-boot requires\nUEFI and will be automatically switched to GRUB if selected."
        fi
        if show_menu "Boot Loader${_bios_warn}" \
                "systemd-boot" "systemd-boot — lightweight, UEFI only (recommended)" \
                "grub"         "GRUB         — universal, supports BIOS and UEFI"; then
            BOOTLOADER="$(cat "$TMPFILE")"
            # Warn immediately if systemd-boot chosen on a BIOS system
            if [[ "$BOOTLOADER" == "systemd-boot" && ! -d /sys/firmware/efi/efivars ]]; then
                show_msg "BIOS Detected" \
"This system booted in BIOS (Legacy) mode. systemd-boot\nrequires UEFI and cannot be used.\n\nThe installer will automatically switch to GRUB."
                BOOTLOADER="grub"
            fi
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 14: GPU DRIVER
    # --------------------------------------------------------------------------
    14)
        if show_menu "GPU / Display Driver" \
                ""             "None / Headless — no display driver" \
                "amd"          "AMD            — mesa + vulkan-radeon" \
                "intel"        "Intel          — mesa + vulkan-intel" \
                "nvidia"       "NVIDIA         — proprietary driver" \
                "nvidia-open"  "NVIDIA Open    — open-source NVIDIA kernel module" \
                "qemu"         "QEMU/KVM       — mesa + qemu-guest-agent + spice" \
                "vmware"       "VMware         — open-vm-tools" \
                "virtualbox"   "VirtualBox     — virtualbox-guest-utils"; then
            GPU_DRIVER="$(cat "$TMPFILE")"
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 15: DESKTOP ENVIRONMENT
    # --------------------------------------------------------------------------
    15)
        if show_menu "Desktop Environment" \
                ""      "None / Headless — server or minimal install" \
                "kde"   "KDE Plasma      — feature-rich, Qt-based (recommended)" \
                "gnome" "GNOME           — clean, GTK-based" \
                "xfce"     "XFCE            — lightweight, GTK-based" \
                "i3"       "i3              — tiling window manager" \
                "hyprland" "Hyprland        — dynamic tiling Wayland compositor" \
                "sway"     "Sway            — i3-compatible Wayland compositor"; then
            DESKTOP_ENV="$(cat "$TMPFILE")"
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 16: EXTRA PACKAGES
    # --------------------------------------------------------------------------
    16)
        if show_input "Extra Packages" \
"Space-separated list of additional packages to install.
These are installed via pacstrap into the new system." \
                "$EXTRA_PACKAGES"; then
            EXTRA_PACKAGES="$(cat "$TMPFILE")"
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 17: USER ACCOUNT
    # --------------------------------------------------------------------------
    17)
        if show_input "Regular User Account" \
"Enter the username for the regular (non-root) user account.
Leave empty to skip creating a user (root login only)." \
                "$USERNAME"; then
            _u="$(cat "$TMPFILE")"
            if [[ -z "$_u" ]]; then
                USERNAME=""
                STEP=$(( STEP + 1 ))
            elif [[ ! "$_u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                show_msg "Invalid Username" \
"Usernames must start with a lowercase letter or underscore,
contain only lowercase letters, digits, underscores, or hyphens,
and be at most 32 characters."
            else
                USERNAME="$_u"
                STEP=$(( STEP + 1 ))
            fi
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 18: AUR HELPER  (only shown if USERNAME is set)
    # --------------------------------------------------------------------------
    18)
        if [[ -n "$USERNAME" ]]; then
            if show_menu "AUR Helper" \
                    ""     "None — do not install an AUR helper" \
                    "yay"  "yay  — Yet Another Yogurt (popular, Go-based)" \
                    "paru" "paru — feature-rich Rust-based AUR helper"; then
                AUR_HELPER="$(cat "$TMPFILE")"
                STEP=$(( STEP + 1 ))
            else
                STEP=$(( STEP - 1 ))
            fi
        else
            AUR_HELPER=""
            STEP=$(( STEP + 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 19: MISCELLANEOUS OPTIONS
    # --------------------------------------------------------------------------
    19)
        # Build checklist with current state
        _reflector_state="off"
        [[ "$USE_REFLECTOR"     == "true" ]] && _reflector_state="on"
        _multilib_state="off"
        [[ "$ENABLE_MULTILIB"   == "true" ]] && _multilib_state="on"
        _autoupdate_state="off"
        [[ "$ENABLE_AUTO_UPDATE" == "true" ]] && _autoupdate_state="on"

        if show_checklist "Miscellaneous Options" \
"Select optional features. Use SPACE to toggle, ENTER to confirm." \
                "USE_REFLECTOR"     "Rank mirrors with reflector (faster downloads)" "$_reflector_state" \
                "ENABLE_MULTILIB"   "Enable multilib repository (32-bit support)"   "$_multilib_state"  \
                "ENABLE_AUTO_UPDATE" "Deploy daily automated system update timer"    "$_autoupdate_state"; then

            _selected="$(cat "$TMPFILE")"
            USE_REFLECTOR="false"
            ENABLE_MULTILIB="false"
            ENABLE_AUTO_UPDATE="false"
            [[ "$_selected" == *"USE_REFLECTOR"*      ]] && USE_REFLECTOR="true"
            [[ "$_selected" == *"ENABLE_MULTILIB"*    ]] && ENABLE_MULTILIB="true"
            [[ "$_selected" == *"ENABLE_AUTO_UPDATE"* ]] && ENABLE_AUTO_UPDATE="true"

            # If reflector enabled, optionally ask for country filter
            if [[ "$USE_REFLECTOR" == "true" ]]; then
                if show_input "Reflector Country Filter" \
"Optionally limit mirror selection to a country (ISO 3166-1 alpha-2).
Examples: US  DE  US,DE
Leave empty to use all worldwide mirrors." \
                        "$REFLECTOR_COUNTRY"; then
                    REFLECTOR_COUNTRY="$(cat "$TMPFILE")"
                fi
                # Cancelled = keep existing value, still advance
            fi

            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 20: SUMMARY
    # --------------------------------------------------------------------------
    20)
        _luks_disp="$LUKS"
        _reflector_disp="$USE_REFLECTOR"
        [[ -n "$REFLECTOR_COUNTRY" ]] && _reflector_disp="${USE_REFLECTOR} (country: ${REFLECTOR_COUNTRY})"
        _user_disp="${USERNAME:-<none>}"
        _aur_disp="${AUR_HELPER:-<none>}"
        _micro_disp="${MICROCODE:-<none>}"
        _gpu_disp="${GPU_DRIVER:-<none>}"
        _de_disp="${DESKTOP_ENV:-<none>}"

        SUMMARY="$(cat <<EOF
┌─────────────────────────────────────────────────────────────┐
│                   INSTALLATION SUMMARY                      │
├──────────────────────┬──────────────────────────────────────┤
│ Disk                 │ $DISK
│ Swap size            │ ${SWAP_SIZE:-<no swap>}
│ Root partition size  │ ${ROOT_SIZE:-<entire disk>}
│ Separate /home       │ $([[ -n "$ROOT_SIZE" ]] && echo "yes (remaining space)" || echo "no (on root)")
│ Filesystem           │ $ROOT_FS
│ LUKS encryption      │ $_luks_disp
├──────────────────────┼──────────────────────────────────────┤
│ Timezone             │ $TIMEZONE
│ Locale               │ $LOCALE
│ Keymap               │ $KEYMAP
│ Hostname             │ $HOSTNAME
├──────────────────────┼──────────────────────────────────────┤
│ Kernel               │ $KERNEL
│ Microcode            │ $_micro_disp
│ Bootloader           │ $BOOTLOADER
│ GPU driver           │ $_gpu_disp
│ Desktop environment  │ $_de_disp
├──────────────────────┼──────────────────────────────────────┤
│ Extra packages       │ $EXTRA_PACKAGES
│ Username             │ $_user_disp
│ AUR helper           │ $_aur_disp
├──────────────────────┼──────────────────────────────────────┤
│ Reflector            │ $_reflector_disp
│ Multilib             │ $ENABLE_MULTILIB
│ Auto-update          │ $ENABLE_AUTO_UPDATE
└──────────────────────┴──────────────────────────────────────┘

Press OK to continue to the password setup, or Cancel to go back
and revise your settings.
EOF
)"
        if dialog --clear --backtitle "$TITLE" \
                  --title "Summary" \
                  --ok-label "Continue" \
                  --cancel-label "Go Back" \
                  --msgbox "$SUMMARY" 30 $DW; then
            STEP=$(( STEP + 1 ))
        else
            STEP=$(( STEP - 1 ))
        fi
        ;;

    # --------------------------------------------------------------------------
    # 21: PASSWORDS
    # --------------------------------------------------------------------------
    21)
        _pw_error=""

        # --- Root password ---
        while true; do
            if [[ -n "$_pw_error" ]]; then
                show_msg "Password Mismatch" "$_pw_error"
                _pw_error=""
            fi
            show_password "Root Password" \
"Enter the root account password:" || { STEP=$(( STEP - 1 )); break; }
            _pass1="$(cat "$TMPFILE")"

            show_password "Root Password — Confirm" \
"Confirm the root password:" || { STEP=$(( STEP - 1 )); break; }
            _pass2="$(cat "$TMPFILE")"

            if [[ "$_pass1" == "$_pass2" ]]; then
                if [[ -z "$_pass1" ]]; then
                    _pw_error="Root password cannot be empty."
                    continue
                fi
                if [[ ${#_pass1} -lt 8 ]]; then
                    if ! show_yesno "Weak Password" \
"The root password is shorter than 8 characters.
Continue with this weak password?"; then
                        _pw_error=""
                        continue
                    fi
                fi
                ROOT_PASSWORD="$_pass1"
                break
            else
                _pw_error="Root passwords do not match. Please try again."
            fi
        done
        # If user cancelled (STEP decremented inside loop), skip remaining password steps
        [[ "$STEP" -lt 21 ]] && continue

        # --- User password (if username is set) ---
        if [[ -n "$USERNAME" ]]; then
            _pw_error=""
            while true; do
                if [[ -n "$_pw_error" ]]; then
                    show_msg "Password Mismatch" "$_pw_error"
                    _pw_error=""
                fi
                show_password "User Password: $USERNAME" \
"Enter the password for user '$USERNAME':" || { STEP=$(( STEP - 1 )); break; }
                _pass1="$(cat "$TMPFILE")"

                show_password "User Password: $USERNAME — Confirm" \
"Confirm the password for user '$USERNAME':" || { STEP=$(( STEP - 1 )); break; }
                _pass2="$(cat "$TMPFILE")"

                if [[ "$_pass1" == "$_pass2" ]]; then
                    if [[ -z "$_pass1" ]]; then
                        _pw_error="User password cannot be empty."
                        continue
                    fi
                    if [[ ${#_pass1} -lt 8 ]]; then
                        if ! show_yesno "Weak Password" \
"The password for '$USERNAME' is shorter than 8 characters.
Continue with this weak password?"; then
                            _pw_error=""
                            continue
                        fi
                    fi
                    USER_PASSWORD="$_pass1"
                    break
                else
                    _pw_error="User passwords do not match. Please try again."
                fi
            done
        else
            USER_PASSWORD=""
        fi

        # If user cancelled
        [[ "$STEP" -lt 21 ]] && continue

        # --- LUKS passphrase (if encryption enabled) ---
        if [[ "$LUKS" == "true" ]]; then
            _pw_error=""
            while true; do
                if [[ -n "$_pw_error" ]]; then
                    show_msg "Passphrase Mismatch" "$_pw_error"
                    _pw_error=""
                fi
                show_password "LUKS Encryption Passphrase" \
"Enter the LUKS2 disk encryption passphrase.
This passphrase protects all data on disk and is required at every boot.
It cannot be empty." || { STEP=$(( STEP - 1 )); break; }
                _pass1="$(cat "$TMPFILE")"

                show_password "LUKS Passphrase — Confirm" \
"Confirm the LUKS2 passphrase:" || { STEP=$(( STEP - 1 )); break; }
                _pass2="$(cat "$TMPFILE")"

                if [[ "$_pass1" == "$_pass2" ]]; then
                    if [[ -z "$_pass1" ]]; then
                        _pw_error="LUKS passphrase cannot be empty."
                        continue
                    fi
                    if [[ ${#_pass1} -lt 8 ]]; then
                        if ! show_yesno "Weak Passphrase" \
"The LUKS passphrase is shorter than 8 characters.
Continue with this weak passphrase?"; then
                            _pw_error=""
                            continue
                        fi
                    fi
                    LUKS_PASSWORD="$_pass1"
                    break
                else
                    _pw_error="LUKS passphrases do not match. Please try again."
                fi
            done
        else
            LUKS_PASSWORD=""
        fi

        # If user cancelled
        [[ "$STEP" -lt 21 ]] && continue

        # All passwords collected — advance to handoff
        STEP=$(( STEP + 1 ))
        ;;

    # --------------------------------------------------------------------------
    # 22 (MAX_STEP + 1): GENERATE CONFIG & LAUNCH
    # This step is handled outside the case because MAX_STEP=21 and the while
    # condition allows STEP=22 to fall through — we break here.
    # --------------------------------------------------------------------------
    *)
        break
        ;;

    esac
done

# ==============================================================================
# HANDOFF — generate configured install.sh and launch
# ==============================================================================

clear

if [[ "$STEP" -le "$MAX_STEP" ]]; then
    echo "Installation wizard cancelled. No changes were made."
    exit 0
fi

echo "Preparing installation..."

WORK_DIR="$(mktemp -d /tmp/arch-install-XXXXXX)"

# Copy all scripts to the work directory
cp "$SCRIPT_DIR/install.sh"       "$WORK_DIR/install.sh"
cp "$SCRIPT_DIR/chroot-setup.sh"  "$WORK_DIR/chroot-setup.sh"
cp "$SCRIPT_DIR/../tools/snapshot-manager.sh" "$WORK_DIR/snapshot-manager.sh"
cp "$SCRIPT_DIR/../tools/update-manager.sh" "$WORK_DIR/update-manager.sh"

# Apply variable substitutions to install.sh
CFG="$WORK_DIR/install.sh"

# Replace the first assignment of a variable in the config file.
# Uses pure bash to avoid sed injection issues with special characters.
_subst() {
    local var="$1" val="$2"
    # Escape characters that are special inside double quotes: \ " $ `
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//\$/\\\$}"
    val="${val//\`/\\\`}"
    local tmpfile="${CFG}.tmp"
    local replaced=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$replaced" == false ]] && [[ "$line" == "${var}="* ]]; then
            printf '%s\n' "${var}=\"${val}\""
            replaced=true
        else
            printf '%s\n' "$line"
        fi
    done < "$CFG" > "$tmpfile"
    mv "$tmpfile" "$CFG"
}

_subst DISK             "$DISK"
_subst EFI_SIZE         "$EFI_SIZE"
_subst SWAP_SIZE        "$SWAP_SIZE"
_subst ROOT_SIZE        "$ROOT_SIZE"
_subst ROOT_FS          "$ROOT_FS"
_subst LUKS             "$LUKS"
_subst TIMEZONE         "$TIMEZONE"
_subst LOCALE           "$LOCALE"
_subst KEYMAP           "$KEYMAP"
_subst HOSTNAME         "$HOSTNAME"
_subst KERNEL           "$KERNEL"
_subst MICROCODE        "$MICROCODE"
_subst BOOTLOADER       "$BOOTLOADER"
_subst GPU_DRIVER       "$GPU_DRIVER"
_subst DESKTOP_ENV      "$DESKTOP_ENV"
_subst EXTRA_PACKAGES   "$EXTRA_PACKAGES"
_subst USERNAME         "$USERNAME"
_subst AUR_HELPER       "$AUR_HELPER"
_subst USE_REFLECTOR    "$USE_REFLECTOR"
_subst REFLECTOR_COUNTRY "$REFLECTOR_COUNTRY"
_subst ENABLE_MULTILIB  "$ENABLE_MULTILIB"
_subst ENABLE_AUTO_UPDATE "$ENABLE_AUTO_UPDATE"

# Write passwords into the temp file
# Passwords are passed via environment to avoid leaving them on disk; install.sh
# will pick them up from ROOT_PASSWORD / USER_PASSWORD / LUKS_PASSWORD env vars.

# Unset password variables from this shell's environment after exec transfers them
chmod +x "$CFG"

echo ""
echo "Configuration written to: $WORK_DIR/install.sh"
echo "Launching installer..."
echo ""

# NOTE: Passwords are passed via environment variables, which are readable in
# /proc/<pid>/environ by any root process. This is acceptable on a single-user
# live ISO where no untrusted code is running. A named pipe or
# systemd-ask-password would be more secure for multi-user environments.
exec env \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_PASSWORD="$USER_PASSWORD" \
    LUKS_PASSWORD="$LUKS_PASSWORD" \
    bash "$WORK_DIR/install.sh"
