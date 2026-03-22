#!/usr/bin/env bash
#
# linux-utils installation dispatcher.
#
# Routes to the correct OS-specific installer based on arguments.
#
# Usage:
#   bash install.sh <os> <mode> [mode-args...]
#
# Examples:
#   bash install.sh archlinux tui
#   bash install.sh archlinux auto minimal
#   bash install.sh archlinux auto minimal -- --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# HELP
# ==============================================================================

show_help() {
    echo -e "${CYAN}linux-utils installer${NC}"
    echo ""
    echo "Usage: $(basename "$0") <os> <mode> [mode-args...]"
    echo ""
    echo -e "${CYAN}Supported operating systems:${NC}"
    echo "  archlinux    Arch Linux installation scripts"
    echo ""
    echo -e "${CYAN}Modes (archlinux):${NC}"
    echo "  tui          Interactive TUI wizard (recommended)"
    echo "  auto <cfg>   Automated install using a named config from install.json"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo "  $(basename "$0") archlinux tui"
    echo "  $(basename "$0") archlinux auto minimal"
    echo "  $(basename "$0") archlinux auto desktop-kde -- --dry-run"
    exit 0
}

show_os_help() {
    local os="$1"
    echo -e "${CYAN}linux-utils installer — ${os}${NC}"
    echo ""
    echo "Usage: $(basename "$0") ${os} <mode> [mode-args...]"
    echo ""
    echo -e "${CYAN}Available modes:${NC}"
    echo "  tui          Launch the interactive TUI wizard"
    echo "  auto <cfg>   Run an automated install with a named JSON config"
    echo ""

    local config_file="$SCRIPT_DIR/${os}/config/install.json"
    if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
        echo -e "${CYAN}Available auto configs:${NC}"
        jq -r '.configs | to_entries[] | "  \(.key)  — \(.value.description // "no description")"' \
            "$config_file" 2>/dev/null || true
        echo ""
    fi

    echo -e "${CYAN}Examples:${NC}"
    echo "  $(basename "$0") ${os} tui"
    echo "  $(basename "$0") ${os} auto minimal"
    exit 0
}

# ==============================================================================
# ARGUMENT ROUTING
# ==============================================================================

[[ "$#" -lt 1 ]] && show_help

OS="$1"
shift

case "$OS" in
    -h|--help|help)
        show_help
        ;;
    archlinux)
        INSTALL_DIR="$SCRIPT_DIR/archlinux/installation"

        [[ "$#" -lt 1 ]] && show_os_help "$OS"

        MODE="$1"
        shift

        case "$MODE" in
            tui)
                exec bash "$INSTALL_DIR/install-tui.sh" "$@"
                ;;
            auto)
                if ! command -v jq &>/dev/null; then
                    echo -e "${YELLOW}[!]${NC} jq is required for auto mode — installing..."
                    pacman -Sy --noconfirm --needed jq
                fi
                exec bash "$INSTALL_DIR/automated.sh" "$@"
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} Unknown mode: $MODE" >&2
                echo ""
                show_os_help "$OS"
                ;;
        esac
        ;;
    *)
        echo -e "${RED}[ERROR]${NC} Unknown operating system: $OS" >&2
        echo ""
        show_help
        ;;
esac
