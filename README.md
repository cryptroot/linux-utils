# linux-utils

A collection of Linux utilities and helpers.

## Quick start

The top-level `install.sh` is a dispatcher that routes to the correct OS-specific installer:

```bash
# Interactive TUI wizard
bash install.sh archlinux tui

# Automated install using a named config from archlinux/config/install.json
bash install.sh archlinux auto minimal
bash install.sh archlinux auto desktop-kde -- --dry-run
```

Run `bash install.sh` with no arguments to see available operating systems and modes.

## Contents

### archlinux

Automated Arch Linux installation script based on the [official installation guide](https://wiki.archlinux.org/title/Installation_guide).

| File | Purpose |
|---|---|
| `installation/install-tui.sh` | Interactive TUI wizard — recommended entry point |
| `installation/install.sh` | Headless installer — edit config variables at the top, then run |
| `installation/chroot-setup.sh` | System configuration executed inside `arch-chroot` (called by `install.sh`) |
| `installation/update.sh` | Daily automated update script deployed to the installed system via systemd timer |
| `installation/automated.sh` | Non-interactive installer driven by a named JSON config |
| `installation/btrfs-restore.sh` | Restore root filesystem from a btrfs pre-upgrade snapshot |
| `config/install.json` | Named configuration presets for automated installs |

**Usage (TUI — recommended):**

1. Boot from the Arch Linux installation medium
2. Connect to the internet (`iwctl` for Wi-Fi, or plug in Ethernet)
3. Download or copy the entire `archlinux/` directory to the live environment
4. Run the interactive wizard:
   ```bash
   bash installation/install-tui.sh
   ```

**Usage (headless):**

1. Boot from the Arch Linux installation medium
2. Connect to the internet
3. Copy the `archlinux/` directory to the live environment
4. Edit the configuration variables at the top of `installation/install.sh`
5. Preview without making changes:
   ```bash
   bash installation/install.sh --dry-run
   ```
6. Run:
   ```bash
   bash installation/install.sh
   ```

**Usage (automated):**

1. Boot from the Arch Linux installation medium
2. Connect to the internet
3. Copy the `archlinux/` directory to the live environment
4. Review/edit configuration presets in `config/install.json`
5. Preview without making changes:
   ```bash
   bash installation/automated.sh minimal -- --dry-run
   ```
6. Run:
   ```bash
   bash installation/automated.sh minimal
   ```

Passwords can be passed via environment variables (`ROOT_PASSWORD`, `USER_PASSWORD`, `LUKS_PASSWORD`).

**Key configuration options:**

| Variable | Description | Default |
|---|---|---|
| `DISK` | Target disk device | `/dev/sda` |
| `EFI_SIZE` | EFI system partition size (UEFI only) | `512M` |
| `SWAP_SIZE` | Swap partition size (empty to skip) | `4G` |
| `ROOT_SIZE` | Root partition size; `/home` gets remaining space (empty = no separate `/home`) | (empty) |
| `ROOT_FS` | Root filesystem (`ext4`, `btrfs`, `xfs`) | `ext4` |
| `LUKS` | Encrypt root/home/swap with LUKS2 | `false` |
| `TIMEZONE` | System timezone | `UTC` |
| `LOCALE` | System locale | `en_US.UTF-8` |
| `KEYMAP` | Console keyboard layout | `us` |
| `HOSTNAME` | Machine hostname | `archlinux` |
| `KERNEL` | Kernel package | `linux` |
| `MICROCODE` | CPU microcode (`amd-ucode`, `intel-ucode`) | (empty) |
| `BOOTLOADER` | Boot loader (`systemd-boot`, `grub`) | `systemd-boot` |
| `GPU_DRIVER` | Display driver (`amd`, `intel`, `nvidia`, `nvidia-open`, `vmware`, `virtualbox`, `qemu`) | (empty) |
| `DESKTOP_ENV` | Desktop environment (`kde`/`plasma`, `gnome`, `xfce`, `i3`, `hyprland`, `sway`) | (empty) |
| `EXTRA_PACKAGES` | Additional packages to install | `nano networkmanager base-devel openssh` |
| `USERNAME` | Create a regular user with full sudo access (empty to skip) | (empty) |
| `AUR_HELPER` | AUR helper (`yay`, `paru`; requires `USERNAME`) | (empty) |
| `USE_REFLECTOR` | Rank mirrors with `reflector` before install | `true` |
| `REFLECTOR_COUNTRY` | Limit reflector to a country (e.g. `US`, `US,DE`) | (empty) |
| `ENABLE_MULTILIB` | Enable the multilib repository (32-bit support) | `false` |
| `ENABLE_AUTO_UPDATE` | Deploy daily automated system update timer | `true` |

**Features:**
- Automatic UEFI/BIOS detection with appropriate partitioning (GPT)
- NVMe and MMC device naming support
- Optional mirror ranking via `reflector`
- Supports `systemd-boot` (UEFI) and `GRUB` (BIOS/UEFI)
- GPU/display driver selection
- Optional desktop environment (KDE Plasma, GNOME, XFCE, i3, Hyprland, Sway)
- Optional user account with full sudo access
- Optional AUR helper installation (`yay` or `paru`)
- LUKS2 full-disk encryption (root, home, and swap)
- Daily automated system update via systemd timer (`update.sh`)
- AUR package updates via `yay`/`paru` (when installed)
- Btrfs snapshots managed by [snapper](https://wiki.archlinux.org/title/Snapper) with restore script (`btrfs-restore.sh`)
  - Automatic timeline snapshots (hourly, with configurable retention)
  - Pre/post snapshots on every pacman transaction via `snap-pac`
  - Automatic cleanup via `snapper-cleanup.timer`
- `--dry-run` mode to preview configuration without making changes
- Full install log saved to `/var/log/arch-install.log`

> **Warning:** This script will erase all data on the target disk. Review the configuration carefully before running.
