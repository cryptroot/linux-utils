#!/usr/bin/env bash
#
# Install packages from packages.json
#
# Post-install utility that reads a JSON package manifest and installs
# packages using the distro's package manager. Designed to be run by the
# user after the OS is installed and booted.
#
# Usage:
#   bash install-packages.sh [OPTIONS]
#
# Options:
#   --dry-run              Preview packages without installing
#   --category <name>      Install only the named category (repeatable)
#   --config <path>        Path to packages.json (default: ./packages.json)
#   --no-aur               Skip AUR packages
#   --help                 Show this help message
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
DRY_RUN=false
NO_AUR=false
CONFIG="${SCRIPT_DIR}/packages.json"
declare -a CATEGORIES=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }
die()   { error "$@"; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --category)
            [[ -z "${2:-}" ]] && die "--category requires a value"
            CATEGORIES+=("$2")
            shift 2
            ;;
        --config)
            [[ -z "${2:-}" ]] && die "--config requires a path"
            CONFIG="$2"
            shift 2
            ;;
        --no-aur)
            NO_AUR=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1 (see --help)"
            ;;
    esac
done

# ==============================================================================
# VALIDATION
# ==============================================================================

[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"

# Ensure jq is available — install it if missing
if ! command -v jq &>/dev/null; then
    step "Installing jq (required for JSON parsing)"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] Would install: jq"
    else
        sudo pacman -S --noconfirm --needed jq || die "Failed to install jq"
    fi
fi

# Validate JSON syntax
if command -v jq &>/dev/null; then
    if ! jq empty "$CONFIG" 2>/dev/null; then
        die "Invalid JSON in $CONFIG"
    fi
fi

# Read distro metadata
DISTRO=$(jq -r '.distro // empty' "$CONFIG")
PKG_MANAGER=$(jq -r '.packageManager // empty' "$CONFIG")
AUR_HELPER=$(jq -r '.aurHelper // empty' "$CONFIG")

[[ -n "$DISTRO" ]]      || die "Missing 'distro' field in $CONFIG"
[[ -n "$PKG_MANAGER" ]] || die "Missing 'packageManager' field in $CONFIG"

# Build the install command based on package manager
case "$PKG_MANAGER" in
    pacman) INSTALL_CMD=(sudo pacman -S --noconfirm --needed) ;;
    apt)    INSTALL_CMD=(sudo apt-get install -y) ;;
    dnf)    INSTALL_CMD=(sudo dnf install -y) ;;
    zypper) INSTALL_CMD=(sudo zypper install -y) ;;
    *)      die "Unsupported package manager: $PKG_MANAGER" ;;
esac

# Build the AUR install command (only relevant for pacman-based distros)
if [[ -n "$AUR_HELPER" && "$NO_AUR" == "false" ]]; then
    if command -v "$AUR_HELPER" &>/dev/null; then
        AUR_CMD=("$AUR_HELPER" -S --noconfirm --needed)
    else
        warn "AUR helper '$AUR_HELPER' not found — AUR packages will be skipped"
        AUR_CMD=()
    fi
else
    AUR_CMD=()
fi

# ==============================================================================
# INSTALL LOGIC
# ==============================================================================

install_packages() {
    local category_name="$1"
    shift
    local -a pkgs=("$@")

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] Would install: ${pkgs[*]}"
    else
        log "Installing: ${pkgs[*]}"
        if ! "${INSTALL_CMD[@]}" "${pkgs[@]}"; then
            error "Failed to install some packages in category '$category_name'"
            return 1
        fi
    fi
}

install_aur_packages() {
    local category_name="$1"
    shift
    local -a pkgs=("$@")

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return
    fi

    if [[ ${#AUR_CMD[@]} -eq 0 ]]; then
        warn "Skipping AUR packages (no helper available): ${pkgs[*]}"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] Would install (AUR): ${pkgs[*]}"
    else
        log "Installing (AUR): ${pkgs[*]}"
        if ! "${AUR_CMD[@]}" "${pkgs[@]}"; then
            error "Failed to install some AUR packages in category '$category_name'"
            return 1
        fi
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

step "Package installer — ${DISTRO} (${PKG_MANAGER})"
[[ "$DRY_RUN" == "true" ]] && warn "Dry-run mode — no packages will be installed"

num_categories=$(jq '.categories | length' "$CONFIG")

for (( i = 0; i < num_categories; i++ )); do
    cat_name=$(jq -r ".categories[$i].name" "$CONFIG")
    cat_desc=$(jq -r ".categories[$i].description // empty" "$CONFIG")

    # Filter by --category if specified
    if [[ ${#CATEGORIES[@]} -gt 0 ]]; then
        match=false
        for c in "${CATEGORIES[@]}"; do
            if [[ "$c" == "$cat_name" ]]; then
                match=true
                break
            fi
        done
        [[ "$match" == "false" ]] && continue
    fi

    step "Category: ${cat_name}${cat_desc:+ — ${cat_desc}}"

    # Collect official and AUR packages separately
    declare -a official_pkgs=()
    declare -a aur_pkgs=()
    declare -a optional_official=()
    declare -a optional_aur=()

    num_pkgs=$(jq ".categories[$i].packages | length" "$CONFIG")
    for (( j = 0; j < num_pkgs; j++ )); do
        pkg_name=$(jq -r ".categories[$i].packages[$j].name" "$CONFIG")
        is_aur=$(jq -r ".categories[$i].packages[$j].aur // false" "$CONFIG")
        is_optional=$(jq -r ".categories[$i].packages[$j].optional // false" "$CONFIG")

        if [[ "$is_aur" == "true" ]]; then
            if [[ "$is_optional" == "true" ]]; then
                optional_aur+=("$pkg_name")
            else
                aur_pkgs+=("$pkg_name")
            fi
        else
            if [[ "$is_optional" == "true" ]]; then
                optional_official+=("$pkg_name")
            else
                official_pkgs+=("$pkg_name")
            fi
        fi
    done

    # Install required official packages
    if [[ ${#official_pkgs[@]} -gt 0 ]]; then
        install_packages "$cat_name" "${official_pkgs[@]}"
    fi

    # Install optional official packages one-by-one (skip on failure)
    for pkg in "${optional_official[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[dry-run] Would install (optional): $pkg"
        else
            log "Installing (optional): $pkg"
            if ! "${INSTALL_CMD[@]}" "$pkg"; then
                warn "Optional package '$pkg' failed to install — skipping"
            fi
        fi
    done

    # Install required AUR packages
    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        install_aur_packages "$cat_name" "${aur_pkgs[@]}"
    fi

    # Install optional AUR packages one-by-one (skip on failure)
    for pkg in "${optional_aur[@]}"; do
        if [[ ${#AUR_CMD[@]} -eq 0 ]]; then
            warn "Skipping optional AUR package (no helper): $pkg"
            continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[dry-run] Would install (AUR, optional): $pkg"
        else
            log "Installing (AUR, optional): $pkg"
            if ! "${AUR_CMD[@]}" "$pkg"; then
                warn "Optional AUR package '$pkg' failed to install — skipping"
            fi
        fi
    done

    unset official_pkgs aur_pkgs optional_official optional_aur
done

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry-run complete. No changes were made."
else
    log "All packages installed successfully."
fi
