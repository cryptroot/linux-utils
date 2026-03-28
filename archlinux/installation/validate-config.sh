#!/usr/bin/env bash
#
# Config schema validator for archlinux/config/install.json profiles.
#
# Validates that a named configuration (or all configurations) contains
# correct keys, valid values, and internally consistent cross-field
# dependencies.  Designed to be called by automated.sh before substitution,
# or run independently for quick checks.
#
# Usage:
#   bash validate-config.sh config.json profile-name
#   bash validate-config.sh --all config.json
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more validation errors found
#
# Requirements: jq
#
set -euo pipefail

# ==============================================================================
# COLOURS & OUTPUT
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ==============================================================================
# SCHEMA DEFINITION
# ==============================================================================

REQUIRED_KEYS=(
    DISK ROOT_FS TIMEZONE LOCALE KEYMAP HOSTNAME KERNEL BOOTLOADER
)

OPTIONAL_KEYS=(
    EFI_SIZE SWAP_SIZE ROOT_SIZE LUKS MICROCODE GPU_DRIVER DESKTOP_ENV
    EXTRA_PACKAGES USERNAME AUR_HELPER USE_REFLECTOR REFLECTOR_COUNTRY
    ENABLE_MULTILIB ENABLE_AUTO_UPDATE WIREGUARD_CONFIG description
)

# All known keys (required + optional)
ALL_KNOWN_KEYS=("${REQUIRED_KEYS[@]}" "${OPTIONAL_KEYS[@]}")

# Enum constraints: key → regex of allowed values
declare -A ENUM_VALUES=(
    [ROOT_FS]="^(ext4|btrfs|xfs)$"
    [BOOTLOADER]="^(systemd-boot|grub)$"
    [KERNEL]="^(linux|linux-lts|linux-zen|linux-hardened)$"
    [LUKS]="^(true|false|)$"
    [USE_REFLECTOR]="^(true|false|)$"
    [ENABLE_MULTILIB]="^(true|false|)$"
    [ENABLE_AUTO_UPDATE]="^(true|false|)$"
    [MICROCODE]="^(amd-ucode|intel-ucode|)$"
    [AUR_HELPER]="^(yay|paru|)$"
)

# ==============================================================================
# ERROR ACCUMULATOR
# ==============================================================================

ERRORS=()
WARNINGS=()

_add_error() {
    ERRORS+=("$1")
}

_add_warning() {
    WARNINGS+=("$1")
}

# ==============================================================================
# FORMAT VALIDATORS
# ==============================================================================

_validate_size_format() {
    local key="$1" val="$2"
    [[ -z "$val" ]] && return 0
    if [[ ! "$val" =~ ^[0-9]+(\.[0-9]+)?[KkMmGgTt]([Ii][Bb])?$ ]]; then
        _add_error "$key: invalid size format '$val' (expected e.g. 512M, 4G, 1.5GiB)"
    fi
}

_validate_disk_path() {
    local val="$1"
    if [[ ! "$val" =~ ^/dev/ ]]; then
        _add_error "DISK: must start with /dev/ (got '$val')"
    fi
}

_validate_hostname() {
    local val="$1"
    if [[ ! "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        _add_error "HOSTNAME: invalid hostname '$val' (RFC 1123: alphanumeric, hyphens, max 63 chars)"
    fi
}

_validate_username() {
    local val="$1"
    [[ -z "$val" ]] && return 0
    if [[ ! "$val" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        _add_error "USERNAME: invalid username '$val' (lowercase, start with letter/underscore, max 32 chars)"
    fi
}

_validate_locale_format() {
    local val="$1"
    if [[ ! "$val" =~ ^[a-z]{2}_[A-Z]{2}\.[A-Za-z0-9-]+$ ]]; then
        _add_error "LOCALE: invalid format '$val' (expected e.g. en_US.UTF-8)"
    fi
}

_validate_timezone_format() {
    local val="$1"
    if [[ ! "$val" =~ ^[A-Za-z_]+(/[A-Za-z_]+)*$ ]]; then
        _add_error "TIMEZONE: invalid format '$val' (expected e.g. America/New_York or UTC)"
    fi
}

_validate_efi_minimum() {
    local val="$1"
    [[ -z "$val" ]] && return 0

    local number unit
    number="${val%%[KkMmGgTt]*}"
    unit="${val##*[0-9.]}"
    unit="${unit%%[Ii][Bb]}"
    unit="${unit,,}"  # lowercase

    local mib_size=0
    case "$unit" in
        k) mib_size=$(awk "BEGIN { printf \"%.0f\", $number / 1024 }") ;;
        m) mib_size=$(awk "BEGIN { printf \"%.0f\", $number }") ;;
        g) mib_size=$(awk "BEGIN { printf \"%.0f\", $number * 1024 }") ;;
        t) mib_size=$(awk "BEGIN { printf \"%.0f\", $number * 1048576 }") ;;
    esac

    if [[ "$mib_size" -lt 256 ]]; then
        _add_error "EFI_SIZE: $val is below minimum 256MiB (got ~${mib_size}MiB)"
    fi
}

# ==============================================================================
# PROFILE VALIDATOR
# ==============================================================================

validate_profile() {
    local config_file="$1" profile_name="$2"
    local profile_json

    profile_json=$(jq -r ".configs[\"$profile_name\"]" "$config_file")
    if [[ "$profile_json" == "null" ]]; then
        _add_error "Profile '$profile_name' not found in config file"
        return
    fi

    # ── Required keys ────────────────────────────────────────────────────
    for key in "${REQUIRED_KEYS[@]}"; do
        local val
        val=$(echo "$profile_json" | jq -r ".[\"$key\"] // empty")
        if [[ -z "$val" ]]; then
            _add_error "$key: required key is missing or empty"
        fi
    done

    # ── Unknown key detection ────────────────────────────────────────────
    local profile_keys
    profile_keys=$(echo "$profile_json" | jq -r 'keys[]')
    while IFS= read -r pkey; do
        local found=false
        for known in "${ALL_KNOWN_KEYS[@]}"; do
            if [[ "$pkey" == "$known" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            _add_warning "Unknown key '$pkey' (possible typo?)"
        fi
    done <<< "$profile_keys"

    # ── Enum validation ──────────────────────────────────────────────────
    for key in "${!ENUM_VALUES[@]}"; do
        local val
        val=$(echo "$profile_json" | jq -r ".[\"$key\"] // empty")
        local pattern="${ENUM_VALUES[$key]}"
        if [[ ! "$val" =~ $pattern ]]; then
            # Build a human-readable list of allowed values from the regex
            local allowed="${pattern#^(}"
            allowed="${allowed%)\$}"
            allowed="${allowed//|/, }"
            _add_error "$key: invalid value '$val' (allowed: $allowed)"
        fi
    done

    # ── Format validation ────────────────────────────────────────────────
    local val

    val=$(echo "$profile_json" | jq -r '.DISK // empty')
    [[ -n "$val" ]] && _validate_disk_path "$val"

    val=$(echo "$profile_json" | jq -r '.HOSTNAME // empty')
    [[ -n "$val" ]] && _validate_hostname "$val"

    val=$(echo "$profile_json" | jq -r '.USERNAME // empty')
    _validate_username "$val"

    val=$(echo "$profile_json" | jq -r '.LOCALE // empty')
    [[ -n "$val" ]] && _validate_locale_format "$val"

    val=$(echo "$profile_json" | jq -r '.TIMEZONE // empty')
    [[ -n "$val" ]] && _validate_timezone_format "$val"

    for size_key in EFI_SIZE SWAP_SIZE ROOT_SIZE; do
        val=$(echo "$profile_json" | jq -r ".[\"$size_key\"] // empty")
        _validate_size_format "$size_key" "$val"
    done

    val=$(echo "$profile_json" | jq -r '.EFI_SIZE // empty')
    _validate_efi_minimum "$val"

    # ── Cross-field dependency checks ────────────────────────────────────
    local aur_helper username luks
    aur_helper=$(echo "$profile_json" | jq -r '.AUR_HELPER // empty')
    username=$(echo "$profile_json" | jq -r '.USERNAME // empty')
    luks=$(echo "$profile_json" | jq -r '.LUKS // empty')

    if [[ -n "$aur_helper" && -z "$username" ]]; then
        _add_error "AUR_HELPER is set to '$aur_helper' but USERNAME is empty (AUR helper requires a regular user)"
    fi

    # WireGuard config validation
    local wg_config
    wg_config=$(echo "$profile_json" | jq -r '.WIREGUARD_CONFIG // empty')
    if [[ -n "$wg_config" ]]; then
        if [[ "$wg_config" != *.conf ]]; then
            _add_error "WIREGUARD_CONFIG: must end in .conf (got '$wg_config')"
        fi
        if [[ -z "$username" ]]; then
            _add_error "WIREGUARD_CONFIG is set but USERNAME is empty (sudoers requires a regular user)"
        fi
    fi

    if [[ "$luks" == "true" ]]; then
        _add_warning "LUKS=true — ensure LUKS_PASSWORD environment variable is set at install time"
    fi
}

# ==============================================================================
# RESULTS
# ==============================================================================

print_results() {
    local profile_label="$1"

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo ""
        for w in "${WARNINGS[@]}"; do
            warn "$profile_label: $w"
        done
    fi

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        for e in "${ERRORS[@]}"; do
            error "$profile_label: $e"
        done
        echo ""
        error "$profile_label: ${#ERRORS[@]} error(s) found"
        return 1
    fi

    log "$profile_label: all checks passed"
    return 0
}

# ==============================================================================
# CLI
# ==============================================================================

usage() {
    echo "Usage: $(basename "$0") <config.json> <profile-name>"
    echo "       $(basename "$0") --all <config.json>"
    echo ""
    echo "Validates install.json config profiles against the expected schema."
    exit 1
}

[[ "$#" -lt 1 ]] && usage

if ! command -v jq &>/dev/null; then
    die "jq is required but not installed. Install it with: pacman -S jq"
fi

VALIDATE_ALL=false
CONFIG_FILE=""
PROFILE_NAME=""

if [[ "$1" == "--all" ]]; then
    VALIDATE_ALL=true
    [[ "$#" -lt 2 ]] && usage
    CONFIG_FILE="$2"
else
    [[ "$#" -lt 2 ]] && usage
    CONFIG_FILE="$1"
    PROFILE_NAME="$2"
fi

[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# Verify the file is valid JSON
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    die "Config file is not valid JSON: $CONFIG_FILE"
fi

EXIT_CODE=0

if [[ "$VALIDATE_ALL" == true ]]; then
    log "Validating all profiles in $CONFIG_FILE"
    echo ""

    profiles=$(jq -r '.configs | keys[]' "$CONFIG_FILE")
    while IFS= read -r pname; do
        ERRORS=()
        WARNINGS=()
        validate_profile "$CONFIG_FILE" "$pname"
        if ! print_results "$pname"; then
            EXIT_CODE=1
        fi
    done <<< "$profiles"
else
    validate_profile "$CONFIG_FILE" "$PROFILE_NAME"
    if ! print_results "$PROFILE_NAME"; then
        EXIT_CODE=1
    fi
fi

exit "$EXIT_CODE"
