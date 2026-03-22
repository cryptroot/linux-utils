#!/usr/bin/env bash
#
# Arch Linux chroot configuration script.
# Called by install.sh via arch-chroot after base packages are installed.
# Placeholder values (__VAR__) are substituted by install.sh before execution.
#
set -euo pipefail

# ==============================================================================
# CONFIGURATION — substituted by install.sh
# ==============================================================================
TIMEZONE="__TIMEZONE__"
LOCALE="__LOCALE__"
KEYMAP="__KEYMAP__"
HOSTNAME="__HOSTNAME__"
# Sensitive variables passed via environment from install.sh to avoid writing passwords to disk
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
USERNAME="${USERNAME:-}"
USER_PASSWORD="${USER_PASSWORD:-}"
KERNEL="__KERNEL__"
BOOT_MODE="__BOOT_MODE__"
BOOTLOADER="__BOOTLOADER__"
DISK="__DISK__"
MICROCODE="__MICROCODE__"
ENABLE_MULTILIB="__ENABLE_MULTILIB__"
ROOT_FS="__ROOT_FS__"
GPU_DRIVER="__GPU_DRIVER__"
DESKTOP_ENV="__DESKTOP_ENV__"
ENABLE_AUTO_UPDATE="__ENABLE_AUTO_UPDATE__"
LUKS="__LUKS__"
LUKS_ROOT_UUID="__LUKS_ROOT_UUID__"
LUKS_HOME_UUID="__LUKS_HOME_UUID__"
SWAP_PART="__SWAP_PART__"
AUR_HELPER="__AUR_HELPER__"
REFLECTOR_COUNTRY="__REFLECTOR_COUNTRY__"

# ==============================================================================

log() { echo -e "\033[0;32m[+]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
die() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Time zone
# ------------------------------------------------------------------------------
log "Setting timezone to $TIMEZONE"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# ------------------------------------------------------------------------------
# Localization
# ------------------------------------------------------------------------------
log "Configuring locale: $LOCALE"
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# ------------------------------------------------------------------------------
# Network configuration
# ------------------------------------------------------------------------------
log "Setting hostname: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname

log "Writing /etc/hosts"
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

if pacman -Qi networkmanager &>/dev/null; then
    log "Enabling NetworkManager"
    systemctl enable NetworkManager.service
fi

if pacman -Qi openssh &>/dev/null; then
    log "Enabling sshd"
    systemctl enable sshd.service
fi

log "Enabling systemd-timesyncd"
systemctl enable systemd-timesyncd.service

# Enable periodic TRIM for SSD/NVMe drives.
# Resolve the underlying block device: when DISK is a dm-crypt mapper path
# (e.g. /dev/mapper/cryptroot), basename has no /sys/block/ entry. Walk the
# slave chain to find the real block device.
_trim_dev="$(basename "$DISK")"
if [[ ! -f "/sys/block/${_trim_dev}/queue/rotational" ]]; then
    # Try to resolve dm-crypt → underlying device via /sys/block/*/slaves
    for _bd in /sys/block/*/slaves/"${_trim_dev}"; do
        if [[ -d "$_bd" ]]; then
            _trim_dev="$(basename "$(dirname "$(dirname "$_bd")")")"
            break
        fi
    done
fi
if [[ -f "/sys/block/${_trim_dev}/queue/rotational" ]] \
   && [[ "$(cat "/sys/block/${_trim_dev}/queue/rotational")" == "0" ]]; then
    log "SSD detected — enabling fstrim.timer"
    systemctl enable fstrim.timer
fi

# ------------------------------------------------------------------------------
# Initramfs
# ------------------------------------------------------------------------------
log "Backing up /etc/mkinitcpio.conf"
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak

if [[ "$LUKS" == "true" ]]; then
    # Use sd-encrypt (systemd-based) instead of the legacy encrypt hook.
    # sd-encrypt reads /etc/crypttab.initramfs and supports multiple LUKS
    # devices (e.g. separate encrypted /home), which the encrypt hook cannot.
    log "Switching to systemd-based initramfs hooks for LUKS support"

    # Parse the HOOKS array, replace/insert entries by name, and reconstruct.
    # This survives upstream reordering, hook additions, and whitespace changes
    # (unlike the previous sed approach that assumed a fixed default format).
    _hooks_line=$(grep '^HOOKS=' /etc/mkinitcpio.conf || true)
    if [[ -z "$_hooks_line" ]]; then
        cp /etc/mkinitcpio.conf.bak /etc/mkinitcpio.conf
        die "No HOOKS= line found in mkinitcpio.conf — the format may have changed. Fix manually."
    fi

    # Extract the value inside HOOKS=(...)
    _hooks_raw=$(echo "$_hooks_line" | sed -n 's/^HOOKS=(\(.*\))/\1/p')
    if [[ -z "$_hooks_raw" ]]; then
        cp /etc/mkinitcpio.conf.bak /etc/mkinitcpio.conf
        die "Could not parse HOOKS=(...) in mkinitcpio.conf — unexpected format. Fix manually."
    fi

    # Split into an array
    read -ra _hooks <<< "$_hooks_raw"

    # Helper: replace a hook by name, or report that it was absent
    _replace_hook() {
        local old="$1" new="$2" found=false
        for i in "${!_hooks[@]}"; do
            if [[ "${_hooks[$i]}" == "$old" ]]; then
                _hooks[$i]="$new"
                found=true
            fi
        done
        $found
    }

    # Helper: insert a hook after another hook
    _insert_after() {
        local after="$1" new="$2"
        local -a result=()
        for h in "${_hooks[@]}"; do
            result+=("$h")
            [[ "$h" == "$after" ]] && result+=("$new")
        done
        _hooks=("${result[@]}")
    }

    _mkinitcpio_ok=true

    # udev → systemd (mkinitcpio v39+ already defaults to systemd)
    _has_systemd=false
    for h in "${_hooks[@]}"; do [[ "$h" == "systemd" ]] && _has_systemd=true; done
    if [[ "$_has_systemd" == false ]]; then
        if ! _replace_hook "udev" "systemd"; then
            error "Hook 'udev' not found in HOOKS — cannot replace with 'systemd'."
            _mkinitcpio_ok=false
        fi
    fi

    # keymap consolefont → sd-vconsole (replaces both with one entry)
    # mkinitcpio v39+ already defaults to sd-vconsole — skip if present.
    _has_sd_vconsole=false
    for h in "${_hooks[@]}"; do [[ "$h" == "sd-vconsole" ]] && _has_sd_vconsole=true; done
    if [[ "$_has_sd_vconsole" == false ]]; then
        _hooks_new=()
        _replaced_vconsole=false
        for h in "${_hooks[@]}"; do
            if [[ "$h" == "keymap" ]]; then
                if [[ "$_replaced_vconsole" == false ]]; then
                    _hooks_new+=("sd-vconsole")
                    _replaced_vconsole=true
                fi
            elif [[ "$h" == "consolefont" ]]; then
                if [[ "$_replaced_vconsole" == false ]]; then
                    _hooks_new+=("sd-vconsole")
                    _replaced_vconsole=true
                fi
            else
                _hooks_new+=("$h")
            fi
        done
        if [[ "$_replaced_vconsole" == false ]]; then
            error "Hooks 'keymap'/'consolefont' not found in HOOKS — cannot replace with 'sd-vconsole'."
            _mkinitcpio_ok=false
        fi
        _hooks=("${_hooks_new[@]}")
    fi

    # Insert sd-encrypt after block (before filesystems)
    _has_sd_encrypt=false
    for h in "${_hooks[@]}"; do
        [[ "$h" == "sd-encrypt" ]] && _has_sd_encrypt=true
    done
    if [[ "$_has_sd_encrypt" == false ]]; then
        _has_block=false
        for h in "${_hooks[@]}"; do
            [[ "$h" == "block" ]] && _has_block=true
        done
        if [[ "$_has_block" == true ]]; then
            _insert_after "block" "sd-encrypt"
        else
            error "Hook 'block' not found in HOOKS — cannot insert 'sd-encrypt'."
            _mkinitcpio_ok=false
        fi
    fi

    if [[ "$_mkinitcpio_ok" == false ]]; then
        log "Restoring /etc/mkinitcpio.conf from backup"
        cp /etc/mkinitcpio.conf.bak /etc/mkinitcpio.conf
        die "mkinitcpio.conf HOOKS modification failed — the default format may have changed. Fix manually."
    fi

    # Write the reconstructed HOOKS line atomically
    cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.tmp
    sed -i "s|^HOOKS=.*|HOOKS=(${_hooks[*]})|" /etc/mkinitcpio.conf.tmp
    mv /etc/mkinitcpio.conf.tmp /etc/mkinitcpio.conf
    log "HOOKS updated: ${_hooks[*]}"

    # Write crypttab.initramfs BEFORE mkinitcpio so sd-encrypt embeds it.
    # Guard against duplicates in case of re-run after partial failure.
    log "Writing /etc/crypttab.initramfs (for sd-encrypt) and /etc/crypttab"
    if ! grep -q "^cryptroot " /etc/crypttab.initramfs 2>/dev/null; then
        echo "cryptroot UUID=${LUKS_ROOT_UUID} - luks" >> /etc/crypttab.initramfs
    fi
    if [[ -n "$LUKS_HOME_UUID" ]]; then
        if ! grep -q "^crypthome " /etc/crypttab.initramfs 2>/dev/null; then
            echo "crypthome UUID=${LUKS_HOME_UUID} /etc/cryptsetup-keys.d/crypthome.key luks" >> /etc/crypttab.initramfs
        fi
        if ! grep -q "^crypthome " /etc/crypttab 2>/dev/null; then
            echo "crypthome UUID=${LUKS_HOME_UUID} /etc/cryptsetup-keys.d/crypthome.key luks" >> /etc/crypttab
        fi
    fi
fi
log "Regenerating initramfs"
mkinitcpio -P || die "mkinitcpio failed — check HOOKS in /etc/mkinitcpio.conf"

if [[ "$LUKS" == "true" ]]; then
    if [[ -n "$SWAP_PART" ]]; then
        log "Configuring encrypted swap in /etc/crypttab (random key each boot)"
        swap_partuuid=$(blkid -s PARTUUID -o value "$SWAP_PART" 2>/dev/null || true)
        if [[ -n "$swap_partuuid" ]]; then
            echo "cryptswap PARTUUID=${swap_partuuid} /dev/urandom swap,cipher=aes-xts-plain64,size=256" >> /etc/crypttab
        else
            echo "cryptswap ${SWAP_PART} /dev/urandom swap,cipher=aes-xts-plain64,size=256" >> /etc/crypttab
        fi
        # Update fstab to use the encrypted swap device.
        # genfstab wrote a UUID-based swap entry for the temporary install mapper;
        # match by filesystem type ("swap") rather than device path to reliably
        # remove it regardless of how genfstab formatted the line.
        sed -i '/\sswap\s/d' /etc/fstab
        echo "/dev/mapper/cryptswap none swap defaults 0 0" >> /etc/fstab
        log "Encrypted swap configured: random key each boot"
    fi
fi

# ------------------------------------------------------------------------------
# Root password
# ------------------------------------------------------------------------------
if [[ -n "$ROOT_PASSWORD" ]]; then
    log "Setting root password"
    printf '%s\n' "root:${ROOT_PASSWORD}" | chpasswd
else
    log "Setting root password (interactive)"
    passwd
fi

# ------------------------------------------------------------------------------
# User account
# ------------------------------------------------------------------------------
if [[ -n "$USERNAME" ]]; then
    log "Creating user: $USERNAME"
    useradd -m -G wheel -s /bin/bash "$USERNAME"

    if [[ -n "$USER_PASSWORD" ]]; then
        printf '%s\n' "${USERNAME}:${USER_PASSWORD}" | chpasswd
    else
        echo "Set password for $USERNAME:"
        passwd "$USERNAME"
    fi

    # Grant full sudo access via a drop-in file (safer than editing /etc/sudoers directly)
    log "Granting full sudo access to $USERNAME"
    echo "${USERNAME} ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/${USERNAME}"
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

    # Allow the AUR helper to call pacman non-interactively for package
    # installation.  AUR helpers run as the user and invoke sudo pacman
    # internally to install built packages.  The user already has full
    # sudo via the drop-in above (password required); these NOPASSWD
    # rules simply avoid repeated password prompts during AUR builds.
    # NOTE: The trailing wildcard means additional flags are not blocked;
    # this is acceptable because the user already has full sudo access.
    if [[ -n "$AUR_HELPER" ]]; then
        log "Granting NOPASSWD pacman install access for AUR helper ($AUR_HELPER)"
        cat > "/etc/sudoers.d/${USERNAME}-aur" << SUDOEOF
# Allow pacman sync/upgrade without password for AUR helper convenience.
# The user already has full sudo access (password required) via the main
# drop-in; these rules only add NOPASSWD for common AUR helper invocations.
${USERNAME} ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman -S --noconfirm --needed *
${USERNAME} ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman -U --noconfirm *
SUDOEOF
        chmod 0440 "/etc/sudoers.d/${USERNAME}-aur"
    fi
fi

# ------------------------------------------------------------------------------
# Multilib repository
# ------------------------------------------------------------------------------
if [[ "$ENABLE_MULTILIB" == "true" ]]; then
    log "Enabling multilib repository"
    sed -i -e 's/^#\[multilib\]/[multilib]/' \
           -e '/^\[multilib\]/,/^Include/{s/^#Include/Include/}' \
           /etc/pacman.conf
fi

# ------------------------------------------------------------------------------
# Desktop environment — enable display manager
# ------------------------------------------------------------------------------
_enable_service() {
    local pkg="$1" svc="$2" label="$3"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "Enabling ${label}"
        systemctl enable "$svc"
    else
        error "Cannot enable ${label} — package '${pkg}' is not installed"
    fi
}

if [[ -n "$DESKTOP_ENV" && "$DESKTOP_ENV" != "none" ]]; then
    case "$DESKTOP_ENV" in
        kde)
            _enable_service sddm sddm.service "SDDM (KDE Plasma display manager)"
            ;;
        gnome)
            _enable_service gdm gdm.service "GDM (GNOME display manager)"
            ;;
        xfce|i3)
            _enable_service lightdm lightdm.service "LightDM display manager"
            ;;
        hyprland|sway)
            _enable_service sddm sddm.service "SDDM (Wayland compositor display manager)"
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# GPU — enable guest agent services where applicable
# ------------------------------------------------------------------------------
case "$GPU_DRIVER" in
    vmware)     _enable_service open-vm-tools vmtoolsd.service "vmtoolsd (VMware guest agent)" ;;
    virtualbox) _enable_service virtualbox-guest-utils vboxservice.service "vboxservice (VirtualBox guest agent)" ;;
esac

# ==============================================================================
# CRITICAL BOOT INFRASTRUCTURE — must complete before optional features
# ==============================================================================

# ------------------------------------------------------------------------------
# Boot loader
# ------------------------------------------------------------------------------
log "Installing boot loader: $BOOTLOADER"

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    bootctl install || die "bootctl install failed — check EFI partition is mounted at /boot"

    # Pacman hook: auto-update systemd-boot whenever systemd is upgraded
    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/95-systemd-boot.hook << 'EOF'
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot loader...
When = PostTransaction
Exec = /usr/bin/bootctl update
EOF

    cat > /boot/loader/loader.conf << EOF
default arch.conf
timeout 3
console-mode max
editor  no
EOF

    # Microcode initrd line (empty string when no microcode package is selected)
    ucode_line=""
    if [[ -n "$MICROCODE" ]]; then
        ucode_line="initrd  /${MICROCODE}.img"
    fi

    root_uuid=$(findmnt -no UUID /)

    btrfs_opts=""
    [[ "$ROOT_FS" == "btrfs" ]] && btrfs_opts=" rootflags=subvol=@"

    if [[ "$LUKS" == "true" ]]; then
        root_opts="rd.luks.name=${LUKS_ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rw${btrfs_opts}"
    else
        root_opts="root=UUID=${root_uuid} rw${btrfs_opts}"
    fi

    {
        echo "title   Arch Linux"
        echo "linux   /vmlinuz-${KERNEL}"
        [[ -n "$ucode_line" ]] && echo "$ucode_line"
        echo "initrd  /initramfs-${KERNEL}.img"
        echo "options ${root_opts}"
    } > /boot/loader/entries/arch.conf

    {
        echo "title   Arch Linux (fallback)"
        echo "linux   /vmlinuz-${KERNEL}"
        [[ -n "$ucode_line" ]] && echo "$ucode_line"
        echo "initrd  /initramfs-${KERNEL}-fallback.img"
        echo "options ${root_opts}"
    } > /boot/loader/entries/arch-fallback.conf

elif [[ "$BOOTLOADER" == "grub" ]]; then
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    else
        # On BIOS, the GRUB core image is embedded in the post-MBR gap and must
        # contain all modules needed to read /boot. When LUKS is enabled, /boot
        # lives on the encrypted root, so the core image needs crypto modules to
        # unlock it. Without --install-modules, grub-install may not auto-detect
        # the LUKS layer (the chroot sees an already-decrypted mountpoint).
        declare -a grub_install_args=(--target=i386-pc)
        if [[ "$LUKS" == "true" ]]; then
            grub_install_args+=(--modules="part_gpt cryptodisk luks2")
        fi
        grub-install "${grub_install_args[@]}" "$DISK"
    fi
    grub_cmdline=""
    [[ "$LUKS" == "true" ]]     && grub_cmdline+="rd.luks.name=${LUKS_ROOT_UUID}=cryptroot "
    [[ "$ROOT_FS" == "btrfs" ]] && grub_cmdline+="rootflags=subvol=@ "
    grub_cmdline="${grub_cmdline% }"
    if [[ -n "$grub_cmdline" ]]; then
        # Append to any existing GRUB_CMDLINE_LINUX value (may be non-empty)
        sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 ${grub_cmdline}\"|" /etc/default/grub
        # Collapse any leading space left when the original value was empty
        sed -i 's|^GRUB_CMDLINE_LINUX=" |GRUB_CMDLINE_LINUX="|' /etc/default/grub
    fi
    if [[ "$LUKS" == "true" ]]; then
        if grep -q '^#GRUB_ENABLE_CRYPTODISK=' /etc/default/grub; then
            sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
        elif ! grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub; then
            echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
        fi
        # Ensure GRUB loads the modules needed to unlock LUKS at boot
        if grep -q '^GRUB_PRELOAD_MODULES=' /etc/default/grub; then
            sed -i 's/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="part_gpt cryptodisk luks2"/' /etc/default/grub
        elif grep -q '^#GRUB_PRELOAD_MODULES=' /etc/default/grub; then
            sed -i 's/^#GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="part_gpt cryptodisk luks2"/' /etc/default/grub
        else
            echo 'GRUB_PRELOAD_MODULES="part_gpt cryptodisk luks2"' >> /etc/default/grub
        fi
    fi
    grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed"

    # grub-btrfs: adds btrfs snapshot entries to the GRUB menu so users can
    # boot directly into a snapshot for recovery.
    if [[ "$ROOT_FS" == "btrfs" ]] && pacman -Qi grub-btrfs &>/dev/null; then
        log "Enabling grub-btrfsd (auto-regenerate GRUB menu on new snapshots)"
        systemctl enable grub-btrfsd.service
    fi
fi

log "Boot loader installed successfully"

# ------------------------------------------------------------------------------
# TPM2 auto-enrollment for LUKS (first boot)
# ------------------------------------------------------------------------------
# Enrolling from the live ISO would record the ISO's PCR measurements, which
# won't match the installed system's boot chain. Instead, deploy a one-shot
# service that runs after the first real boot, when measurements are correct.
if [[ "$LUKS" == "true" ]]; then
    log "Deploying TPM2 LUKS enrollment service (runs on first boot if TPM2 is present)"
    cat > /etc/systemd/system/luks-tpm2-enroll.service << 'EOF'
[Unit]
Description=Enroll TPM2 token for LUKS root partition (one-shot)
ConditionPathExists=/sys/class/tpm/tpm0
ConditionPathExists=!/etc/luks-tpm2-enrolled
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/luks-tpm2-enroll
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/bin/luks-tpm2-enroll << ENROLLEOF
#!/usr/bin/env bash
# One-shot TPM2 enrollment for the LUKS root partition.
# Runs on first boot via luks-tpm2-enroll.service.
set -euo pipefail
LUKS_ROOT_UUID="${LUKS_ROOT_UUID}"
if ! command -v systemd-cryptenroll &>/dev/null; then
    echo "systemd-cryptenroll not found — skipping TPM2 enrollment" >&2
    exit 0
fi
echo "Enrolling TPM2 token for LUKS root (UUID=\${LUKS_ROOT_UUID})..."
# Bind to PCRs 7 (Secure Boot state), 11 (unified kernel hash), and
# 14 (shim/MOK state). This ensures the TPM only releases the key when
# the boot chain (firmware policy + bootloader + kernel) is untampered.
# NOTE: A kernel or bootloader update will change these PCR values.
# After such updates, re-enroll with:
#   systemd-cryptenroll /dev/disk/by-uuid/\${LUKS_ROOT_UUID} --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7+11+14
if systemd-cryptenroll "/dev/disk/by-uuid/\${LUKS_ROOT_UUID}" --tpm2-device=auto --tpm2-pcrs=7+11+14; then
    echo "TPM2 enrollment successful (PCRs 7+11+14)"
    touch /etc/luks-tpm2-enrolled
else
    echo "TPM2 enrollment failed (non-fatal) — passphrase unlock still works" >&2
fi
ENROLLEOF
    chmod 0755 /usr/local/bin/luks-tpm2-enroll
    systemctl enable luks-tpm2-enroll.service
fi

# ==============================================================================
# OPTIONAL FEATURES — failures here are non-fatal (system is already bootable)
# ==============================================================================

# ------------------------------------------------------------------------------
# Daily system update — systemd timer
# ------------------------------------------------------------------------------
if [[ "$ENABLE_AUTO_UPDATE" == "true" ]]; then
    log "Installing daily system update (systemd timer)"
    pacman -S --noconfirm --needed pacman-contrib
    install -Dm0755 /root/update.sh /usr/local/bin/arch-update

    cat > /etc/arch-update.conf << EOF
# arch-update configuration — edit to customise behaviour
# ERE pattern of package names treated as critical (auto-upgrade is deferred when matched).
# Separate alternatives with |
CRITICAL_PKGS="linux|linux-lts|linux-zen|linux-hardened|glibc|systemd|systemd-libs"

# Reflector country filter for mirror ranking (e.g., "US" or "US,DE"; empty = auto)
REFLECTOR_COUNTRY="${REFLECTOR_COUNTRY}"
EOF
    log "arch-update configuration deployed to /etc/arch-update.conf"

    cat > /etc/systemd/system/arch-update.service << 'EOF'
[Unit]
Description=Daily Arch Linux system update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/arch-update
EOF

    cat > /etc/systemd/system/arch-update.timer << 'EOF'
[Unit]
Description=Daily Arch Linux system update timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl enable arch-update.timer
    log "arch-update.timer enabled"

    cat > /etc/logrotate.d/arch-update << 'EOF'
/var/log/arch-update.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
    log "Logrotate config installed for /var/log/arch-update.log"
else
    log "Auto-update disabled (ENABLE_AUTO_UPDATE=false), skipping"
fi

# ------------------------------------------------------------------------------
# AUR helper (non-fatal — failure must not abort installation)
# ------------------------------------------------------------------------------
if [[ -n "$AUR_HELPER" && -n "$USERNAME" ]]; then
    log "Installing AUR helper: $AUR_HELPER"
    # Build dependencies (git is needed, base-devel should already be installed)
    pacman -S --noconfirm --needed git base-devel

    # Build as the regular user, then install as root.
    # Using makepkg without -i avoids the user needing sudo during build,
    # which would prompt for a password and block automated installs.
    _aur_builddir="$(mktemp -d)"
    chown "$USERNAME":"$USERNAME" "$_aur_builddir"
    if sudo -u "$USERNAME" bash -c '
        set -euo pipefail
        cd "$1"
        git clone "https://aur.archlinux.org/${2}-bin.git" .
        makepkg --noconfirm
    ' _ "$_aur_builddir" "$AUR_HELPER"; then
        # Install the built package as root — no sudo password needed
        pacman -U --noconfirm "$_aur_builddir"/*.pkg.tar.zst
        log "$AUR_HELPER installed successfully"
    else
        error "AUR helper ($AUR_HELPER) installation failed (non-fatal) — install manually after reboot"
    fi
    rm -rf "$_aur_builddir"
fi

# ------------------------------------------------------------------------------
# Snapper — automatic btrfs snapshots (non-fatal — failure must not abort installation)
# ------------------------------------------------------------------------------
if [[ "$ROOT_FS" == "btrfs" ]]; then
    log "Configuring snapper for automatic btrfs snapshots"

    _snapper_ok=true

    # snapper create-config expects to create /.snapshots itself, but we already
    # mount the @snapshots subvolume there. Temporarily unmount so snapper can
    # create its own subvolume, then swap it for our @snapshots mount.
    if mountpoint -q /.snapshots 2>/dev/null; then
        umount /.snapshots
    fi
    rmdir /.snapshots 2>/dev/null || true

    if ! snapper --no-dbus -c root create-config /; then
        error "snapper create-config failed (non-fatal) — configure snapper manually after reboot"
        # Restore /.snapshots mount so the system remains consistent
        mkdir -p /.snapshots
        mount /.snapshots 2>/dev/null || true
        _snapper_ok=false
    fi

    if [[ "$_snapper_ok" == true ]]; then
        # Replace snapper's auto-created .snapshots subvolume with our @snapshots
        if ! btrfs subvolume delete /.snapshots; then
            error "Failed to delete snapper's .snapshots subvolume (non-fatal) — configure snapper manually after reboot"
            _snapper_ok=false
        fi
    fi

    if [[ "$_snapper_ok" == true ]]; then
        mkdir /.snapshots
        if ! mount /.snapshots; then
            error "Failed to mount @snapshots subvolume on /.snapshots (non-fatal) — check fstab entry after reboot"
            _snapper_ok=false
        fi
    fi

    if [[ "$_snapper_ok" == true ]]; then
        chmod 750 /.snapshots

        # Allow regular user to manage snapshots
        if [[ -n "$USERNAME" ]]; then
            sed -i "s/^ALLOW_USERS=.*/ALLOW_USERS=\"${USERNAME}\"/" /etc/snapper/configs/root
        fi

        # Timeline: create hourly snapshots and auto-cleanup old ones.
        # Use a helper to set config keys robustly: update existing keys in
        # place, or append missing ones. This survives upstream format changes
        # where a key might not exist in the default config.
        _snapper_set() {
            local key="$1" val="$2" file="/etc/snapper/configs/root"
            if grep -q "^${key}=" "$file" 2>/dev/null; then
                sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
            else
                echo "${key}=\"${val}\"" >> "$file"
            fi
        }
        _snapper_set TIMELINE_CREATE       yes
        _snapper_set TIMELINE_CLEANUP      yes
        _snapper_set TIMELINE_MIN_AGE      1800
        _snapper_set TIMELINE_LIMIT_HOURLY 5
        _snapper_set TIMELINE_LIMIT_DAILY  7
        _snapper_set TIMELINE_LIMIT_WEEKLY 0
        _snapper_set TIMELINE_LIMIT_MONTHLY 0
        _snapper_set TIMELINE_LIMIT_YEARLY 0

        # snap-pac creates pre/post snapshots around every pacman transaction.
        # NUMBER_CLEANUP limits how many of those accumulate.
        _snapper_set NUMBER_CLEANUP          yes
        _snapper_set NUMBER_MIN_AGE          1800
        _snapper_set NUMBER_LIMIT            10
        _snapper_set NUMBER_LIMIT_IMPORTANT  10

        # Enable snapper timers (timeline snapshots + automatic cleanup)
        systemctl enable snapper-timeline.timer
        systemctl enable snapper-cleanup.timer

        log "Snapper configured: timeline snapshots (5 hourly, 7 daily) + snap-pac pacman hooks"
    fi
fi

log "System configuration complete!"
