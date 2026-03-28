#!/usr/bin/env bash
#
# Post-install smoke test for Arch Linux.
# Runs inside arch-chroot (or on an already-installed system) and verifies
# that critical installation steps completed correctly.
#
# Placeholder values (__VAR__) are substituted by install.sh before execution,
# following the same pattern as chroot-setup.sh.
#
# Usage (standalone, from within the installed system):
#   bash verify-install.sh
#
# Usage (via install.sh):
#   bash install.sh --verify
#
set -euo pipefail

# ==============================================================================
# CONFIGURATION — substituted by install.sh
# ==============================================================================
KERNEL="__KERNEL__"
BOOTLOADER="__BOOTLOADER__"
ROOT_FS="__ROOT_FS__"
TIMEZONE="__TIMEZONE__"
LOCALE="__LOCALE__"
HOSTNAME_CFG="__HOSTNAME__"
MICROCODE="__MICROCODE__"
LUKS="__LUKS__"
LUKS_HOME_UUID="__LUKS_HOME_UUID__"
DESKTOP_ENV="__DESKTOP_ENV__"
WIREGUARD_CONFIG="__WIREGUARD_CONFIG__"
# Sensitive — passed via environment
USERNAME="${USERNAME:-}"

# ==============================================================================
# SYMBOLS & COLOURS
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

SYM_OK="✔"
SYM_ERR="✘"
SYM_WARN="⚠"

PASS=0
FAIL=0
TOTAL=0

# ==============================================================================
# HELPERS
# ==============================================================================

_pass() {
    echo -e "  ${GREEN}${SYM_OK}${NC} $1"
    (( ++PASS ))
    (( ++TOTAL ))
}

_fail() {
    echo -e "  ${RED}${SYM_ERR}${NC} $1"
    (( ++FAIL ))
    (( ++TOTAL ))
}

_warn() {
    echo -e "  ${YELLOW}${SYM_WARN}${NC} $1"
}

_detail() {
    echo -e "    ${DIM}$1${NC}"
}

# ==============================================================================
# CHECK FUNCTIONS
# ==============================================================================

check_bootloader() {
    local ok=true

    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        if [[ -f /boot/loader/loader.conf ]]; then
            if [[ -f /boot/loader/entries/arch.conf ]]; then
                if grep -q "vmlinuz-${KERNEL}" /boot/loader/entries/arch.conf; then
                    :  # all good
                else
                    _detail "arch.conf does not reference vmlinuz-${KERNEL}"
                    ok=false
                fi
            else
                _detail "/boot/loader/entries/arch.conf missing"
                ok=false
            fi
        else
            _detail "/boot/loader/loader.conf missing"
            ok=false
        fi
    elif [[ "$BOOTLOADER" == "grub" ]]; then
        if [[ -f /boot/grub/grub.cfg ]]; then
            if ! grep -q "vmlinuz-${KERNEL}" /boot/grub/grub.cfg; then
                _detail "grub.cfg does not reference vmlinuz-${KERNEL}"
                ok=false
            fi
        else
            _detail "/boot/grub/grub.cfg missing"
            ok=false
        fi
        if [[ -f /etc/default/grub ]]; then
            if [[ "$LUKS" == "true" ]]; then
                if ! grep -q 'GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub; then
                    _detail "GRUB_ENABLE_CRYPTODISK=y not set (required for LUKS)"
                    ok=false
                fi
                if ! grep -q 'rd.luks.name=' /etc/default/grub; then
                    _detail "GRUB_CMDLINE_LINUX missing rd.luks.name= (required for LUKS)"
                    ok=false
                fi
            fi
            if [[ "$ROOT_FS" == "btrfs" ]]; then
                if ! grep -q 'rootflags=subvol=@' /etc/default/grub; then
                    _detail "GRUB_CMDLINE_LINUX missing rootflags=subvol=@ (required for btrfs)"
                    ok=false
                fi
            fi
        else
            _detail "/etc/default/grub not found"
            ok=false
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "Bootloader ($BOOTLOADER)"
    else
        _fail "Bootloader ($BOOTLOADER)"
    fi
}

check_fstab() {
    local ok=true

    if ! grep -qE '\s/\s' /etc/fstab; then
        _detail "/etc/fstab: no root (/) mount found"
        ok=false
    fi

    if ! grep -qE '\s/boot\s' /etc/fstab; then
        _detail "/etc/fstab: no /boot mount found"
        ok=false
    fi

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        if ! grep -qE 'subvol=/?@(,|[[:space:]]|$)' /etc/fstab; then
            _detail "/etc/fstab: btrfs root should have subvol=@ or subvol=/@"
            ok=false
        fi
    fi

    if command -v findmnt &>/dev/null; then
        if ! findmnt --verify --tab-file /etc/fstab &>/dev/null; then
            _warn "findmnt --verify reported issues (may be expected inside chroot)"
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "fstab"
    else
        _fail "fstab"
    fi
}

check_initramfs() {
    local ok=true
    local img="/boot/initramfs-${KERNEL}.img"
    local fallback_hyphen="/boot/initramfs-${KERNEL}-fallback.img"
    local fallback_underscore="/boot/initramfs-${KERNEL}_fallback.img"

    if [[ -f "$img" ]]; then
        local size
        size=$(stat -c%s "$img" 2>/dev/null || echo 0)
        if [[ "$size" -lt 1048576 ]]; then
            _detail "initramfs is suspiciously small (${size} bytes)"
            ok=false
        fi
    else
        _detail "$img not found"
        ok=false
    fi

    if [[ ! -f "$fallback_hyphen" && ! -f "$fallback_underscore" ]]; then
        _warn "fallback initramfs not found (checked -fallback and _fallback naming)"
    fi

    if [[ "$LUKS" == "true" ]]; then
        if [[ -f /etc/mkinitcpio.conf ]]; then
            local hooks
            hooks=$(grep '^HOOKS=' /etc/mkinitcpio.conf || true)
            if [[ -n "$hooks" ]] && ! echo "$hooks" | grep -q 'sd-encrypt'; then
                _detail "sd-encrypt not found in mkinitcpio HOOKS (required for LUKS)"
                ok=false
            fi
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "Initramfs"
    else
        _fail "Initramfs"
    fi
}

check_locale() {
    local ok=true

    if [[ -f /etc/locale.conf ]]; then
        if ! grep -q "^LANG=" /etc/locale.conf; then
            _detail "/etc/locale.conf: no LANG= entry"
            ok=false
        fi
    else
        _detail "/etc/locale.conf not found"
        ok=false
    fi

    if command -v locale &>/dev/null; then
        # locale -a outputs e.g. "en_US.utf8" while config uses "en_US.UTF-8"
        # Normalise by stripping the encoding suffix and matching the base name
        local locale_base
        locale_base=$(echo "$LOCALE" | cut -d. -f1)
        if ! locale -a 2>/dev/null | grep -qi "^${locale_base}"; then
            _detail "locale '$LOCALE' not found in locale -a output"
            ok=false
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "Locale ($LOCALE)"
    else
        _fail "Locale ($LOCALE)"
    fi
}

check_timezone() {
    local ok=true

    if [[ -L /etc/localtime ]]; then
        local target
        target=$(readlink -f /etc/localtime)
        if [[ "$target" != *"$TIMEZONE" ]]; then
            _detail "/etc/localtime points to $target (expected $TIMEZONE)"
            ok=false
        fi
    else
        _detail "/etc/localtime is not a symlink"
        ok=false
    fi

    if [[ "$ok" == true ]]; then
        _pass "Timezone ($TIMEZONE)"
    else
        _fail "Timezone ($TIMEZONE)"
    fi
}

check_hostname() {
    local ok=true

    if [[ -f /etc/hostname ]]; then
        local actual
        actual=$(cat /etc/hostname)
        if [[ "$actual" != "$HOSTNAME_CFG" ]]; then
            _detail "/etc/hostname contains '$actual' (expected '$HOSTNAME_CFG')"
            ok=false
        fi
    else
        _detail "/etc/hostname not found"
        ok=false
    fi

    if [[ -f /etc/hosts ]]; then
        if ! grep -q "$HOSTNAME_CFG" /etc/hosts; then
            _detail "/etc/hosts does not reference '$HOSTNAME_CFG'"
            ok=false
        fi
    else
        _detail "/etc/hosts not found"
        ok=false
    fi

    if [[ "$ok" == true ]]; then
        _pass "Hostname ($HOSTNAME_CFG)"
    else
        _fail "Hostname ($HOSTNAME_CFG)"
    fi
}

check_services() {
    local ok=true

    # NetworkManager
    if ! systemctl is-enabled NetworkManager.service &>/dev/null; then
        _detail "NetworkManager.service is not enabled"
        ok=false
    fi

    # Display manager (based on desktop environment)
    if [[ -n "$DESKTOP_ENV" && "$DESKTOP_ENV" != "none" ]]; then
        local dm=""
        case "$DESKTOP_ENV" in
            kde)            dm="sddm.service" ;;
            gnome)          dm="gdm.service" ;;
            xfce|i3)        dm="lightdm.service" ;;
            hyprland|sway)  dm="sddm.service" ;;
        esac
        if [[ -n "$dm" ]]; then
            if ! systemctl is-enabled "$dm" &>/dev/null; then
                _detail "$dm is not enabled (expected for $DESKTOP_ENV)"
                ok=false
            fi
        fi
    fi

    # TPM service for LUKS
    if [[ "$LUKS" == "true" ]]; then
        if ! systemctl is-enabled luks-tpm2-enroll.service &>/dev/null; then
            _detail "luks-tpm2-enroll.service is not enabled"
            # Not fatal — TPM may not be available
            _warn "TPM2 enrollment service not enabled (non-fatal if no TPM)"
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "Services"
    else
        _fail "Services"
    fi
}

check_users() {
    if [[ -z "$USERNAME" ]]; then
        _pass "Users (no regular user configured)"
        return
    fi

    local ok=true

    if ! grep -q "^${USERNAME}:" /etc/passwd; then
        _detail "User '$USERNAME' not found in /etc/passwd"
        ok=false
    fi

    if [[ ! -f "/etc/sudoers.d/${USERNAME}" ]]; then
        _detail "Sudoers drop-in /etc/sudoers.d/${USERNAME} not found"
        ok=false
    fi

    if [[ "$ok" == true ]]; then
        _pass "Users ($USERNAME)"
    else
        _fail "Users ($USERNAME)"
    fi
}

check_crypto() {
    if [[ "$LUKS" != "true" ]]; then
        _pass "Crypto (LUKS not enabled)"
        return
    fi

    local ok=true

    # crypttab.initramfs should reference cryptroot
    if [[ -f /etc/crypttab.initramfs ]]; then
        if ! grep -q "^cryptroot " /etc/crypttab.initramfs; then
            _detail "/etc/crypttab.initramfs: no cryptroot entry"
            ok=false
        fi
    else
        _detail "/etc/crypttab.initramfs not found"
        ok=false
    fi

    # If separate /home, check for crypthome keyfile
    if [[ -n "$LUKS_HOME_UUID" ]]; then
        if [[ ! -f /etc/cryptsetup-keys.d/crypthome.key ]]; then
            _detail "Keyfile /etc/cryptsetup-keys.d/crypthome.key not found"
            ok=false
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "Crypto (LUKS)"
    else
        _fail "Crypto (LUKS)"
    fi
}

check_kernel() {
    local ok=true

    if [[ ! -f "/boot/vmlinuz-${KERNEL}" ]]; then
        _detail "/boot/vmlinuz-${KERNEL} not found"
        ok=false
    fi

    if [[ -n "$MICROCODE" ]]; then
        if [[ ! -f "/boot/${MICROCODE}.img" ]]; then
            _detail "/boot/${MICROCODE}.img not found"
            ok=false
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "Kernel ($KERNEL)"
    else
        _fail "Kernel ($KERNEL)"
    fi
}

check_wireguard() {
    if [[ -z "$WIREGUARD_CONFIG" ]]; then
        _pass "WireGuard (not configured)"
        return
    fi

    local ok=true
    local wg_basename wg_iface
    wg_basename="$(basename "$WIREGUARD_CONFIG")"
    wg_iface="${wg_basename%.conf}"

    # Package installed?
    if ! pacman -Qi wireguard-tools &>/dev/null; then
        _detail "wireguard-tools package is not installed"
        ok=false
    fi

    # Config file exists with correct permissions?
    local wg_conf="/etc/wireguard/${wg_basename}"
    if [[ -f "$wg_conf" ]]; then
        local perms
        perms=$(stat -c '%a' "$wg_conf" 2>/dev/null || echo "unknown")
        if [[ "$perms" != "600" ]]; then
            _detail "$wg_conf has permissions $perms (expected 600)"
            ok=false
        fi
    else
        _detail "$wg_conf not found"
        ok=false
    fi

    # Service enabled?
    if ! systemctl is-enabled "wg-quick@${wg_iface}.service" &>/dev/null; then
        _detail "wg-quick@${wg_iface}.service is not enabled"
        ok=false
    fi

    # system-manager deployed?
    if [[ ! -x /usr/local/bin/system-manager ]]; then
        _detail "/usr/local/bin/system-manager not found or not executable"
        ok=false
    fi

    # Sudoers for wg show?
    if [[ -n "$USERNAME" ]]; then
        if [[ ! -f "/etc/sudoers.d/${USERNAME}-wireguard" ]]; then
            _detail "Sudoers drop-in /etc/sudoers.d/${USERNAME}-wireguard not found"
            ok=false
        fi
    fi

    if [[ "$ok" == true ]]; then
        _pass "WireGuard ($wg_iface)"
    else
        _fail "WireGuard ($wg_iface)"
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

echo ""
echo -e "${CYAN}==> Post-install verification${NC}"
echo ""

check_bootloader
check_fstab
check_initramfs
check_locale
check_timezone
check_hostname
check_services
check_users
check_crypto
check_kernel
check_wireguard

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}Post-install verification: ${PASS}/${TOTAL} passed${NC}"
else
    echo -e "${YELLOW}Post-install verification: ${PASS}/${TOTAL} passed, ${FAIL} failed${NC}"
fi
echo ""

exit "$FAIL"
