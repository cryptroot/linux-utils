#!/usr/bin/env bash
#
# Arch Linux automated (non-interactive) installation.
#
# Reads a named configuration from archlinux/config/install.json, applies
# the settings to install.sh, disables all interactive confirmation prompts,
# and launches the installer.
#
# Usage:
#   bash automated.sh <config-name> [-- extra-install-args...]
#
# Example:
#   bash automated.sh minimal
#   bash automated.sh desktop-kde -- --dry-run
#
# Requirements:
#   jq — for parsing install.json
#
# All sibling scripts (install.sh, chroot-setup.sh, update.sh, btrfs-restore.sh)
# must be in the same directory as this file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
CONFIG_FILE="$CONFIG_DIR/install.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

usage() {
    echo "Usage: $(basename "$0") <config-name> [-- extra-install-args...]"
    echo ""
    echo "Runs an unattended Arch Linux installation using a named config"
    echo "from archlinux/config/install.json."
    echo ""

    if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        echo "Available configs:"
        jq -r '.configs | to_entries[] | "  \(.key)  — \(.value.description // "no description")"' \
            "$CONFIG_FILE" 2>/dev/null || true
    fi

    echo ""
    echo "Options after '--' are forwarded to install.sh (e.g. --dry-run)."
    exit 1
}

[[ "$#" -lt 1 ]] && usage

CONFIG_NAME="$1"
shift

# Collect any extra args after "--"
EXTRA_ARGS=()
if [[ "${1:-}" == "--" ]]; then
    shift
    EXTRA_ARGS=("$@")
fi

# ==============================================================================
# DEPENDENCY CHECK
# ==============================================================================

if ! command -v jq &>/dev/null; then
    die "jq is required but not installed. Install it with: pacman -S jq"
fi

[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# ==============================================================================
# LOAD CONFIG
# ==============================================================================

if ! jq -e ".configs[\"$CONFIG_NAME\"]" "$CONFIG_FILE" >/dev/null 2>&1; then
    error "Config '$CONFIG_NAME' not found in $CONFIG_FILE"
    echo ""
    usage
fi

log "Loading config: $CONFIG_NAME"

CONFIG_JSON=$(jq -r ".configs[\"$CONFIG_NAME\"]" "$CONFIG_FILE")

# ==============================================================================
# APPLY CONFIG TO INSTALL.SH
# ==============================================================================

WORK_DIR="$(mktemp -d /tmp/arch-auto-XXXXXX)"

cp "$SCRIPT_DIR/install.sh"       "$WORK_DIR/install.sh"
cp "$SCRIPT_DIR/chroot-setup.sh"  "$WORK_DIR/chroot-setup.sh"
cp "$SCRIPT_DIR/update.sh"        "$WORK_DIR/update.sh"
cp "$SCRIPT_DIR/btrfs-restore.sh" "$WORK_DIR/btrfs-restore.sh"

CFG="$WORK_DIR/install.sh"

# Replace the first assignment of a variable in the config file.
_subst() {
    local var="$1" val="$2"
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

# List of config keys that map to install.sh variables (skip "description")
CONFIG_KEYS=(
    DISK EFI_SIZE SWAP_SIZE ROOT_SIZE ROOT_FS LUKS
    TIMEZONE LOCALE KEYMAP HOSTNAME KERNEL MICROCODE
    BOOTLOADER GPU_DRIVER DESKTOP_ENV EXTRA_PACKAGES
    USERNAME AUR_HELPER USE_REFLECTOR REFLECTOR_COUNTRY
    ENABLE_MULTILIB ENABLE_AUTO_UPDATE
)

for key in "${CONFIG_KEYS[@]}"; do
    val=$(echo "$CONFIG_JSON" | jq -r ".[\"$key\"] // empty")
    if [[ -n "$val" ]]; then
        _subst "$key" "$val"
        log "  $key=$val"
    fi
done

# Force non-interactive — disable all confirmation prompts
_subst REQUIRE_WIPE_CONFIRMATION   "false"
_subst REQUIRE_REBOOT_CONFIRMATION "false"

log "Confirmation prompts disabled for automated run"

chmod +x "$CFG"

# ==============================================================================
# LAUNCH
# ==============================================================================

log "Launching install.sh from $WORK_DIR"
echo ""

# install.sh will prompt for empty passwords if any of these are not set, so we set them to empty strings by default.
exec env \
    ROOT_PASSWORD="${ROOT_PASSWORD:-}" \
    USER_PASSWORD="${USER_PASSWORD:-}" \
    LUKS_PASSWORD="${LUKS_PASSWORD:-}" \
    bash "$CFG" "${EXTRA_ARGS[@]}"
