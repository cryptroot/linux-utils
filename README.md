# linux-utils

A collection of Linux utilities and helpers.

## Contents

### archlinux

Automated Arch Linux installation script based on the [official installation guide](https://wiki.archlinux.org/title/Installation_guide).

| File | Purpose |
|---|---|
| `install-tui.sh` | Interactive TUI wizard — recommended entry point |
| `install.sh` | Headless installer — edit config variables at the top, then run |
| `chroot-setup.sh` | System configuration executed inside `arch-chroot` (called by `install.sh`) |
| `update.sh` | Daily automated update script deployed to the installed system via systemd timer |
| `btrfs-restore.sh` | Restore root filesystem from a btrfs pre-upgrade snapshot |
| `packages.json` | Declarative package manifest — edit to define desired packages |
| `install-packages.sh` | Post-install package installer — reads `packages.json` and installs packages |

**Usage (TUI — recommended):**

1. Boot from the Arch Linux installation medium
2. Connect to the internet (`iwctl` for Wi-Fi, or plug in Ethernet)
3. Download or copy the entire `archlinux/` directory to the live environment
4. Run the interactive wizard:
   ```bash
   bash install-tui.sh
   ```

**Usage (headless):**

1. Boot from the Arch Linux installation medium
2. Connect to the internet
3. Copy the `archlinux/` directory to the live environment
4. Edit the configuration variables at the top of `install.sh`
5. Preview without making changes:
   ```bash
   bash install.sh --dry-run
   ```
6. Run:
   ```bash
   bash install.sh
   ```

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
| `GPU_DRIVER` | Display driver (`amd`, `intel`, `nvidia`, `nvidia-open`, `vmware`, `virtualbox`) | (empty) |
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

---

#### Post-install package management

After the OS is installed and booted, use `packages.json` and `install-packages.sh` to declaratively install your desired packages.

**`packages.json` format:**

```json
{
  "distro": "archlinux",
  "packageManager": "pacman",
  "aurHelper": "yay",
  "categories": [
    {
      "name": "base",
      "description": "Essential system packages",
      "packages": [
        { "name": "git" },
        { "name": "visual-studio-code-bin", "aur": true, "optional": true }
      ]
    }
  ]
}
```

| Field | Level | Description |
|---|---|---|
| `distro` | root | Linux distribution identifier |
| `packageManager` | root | Package manager command (`pacman`, `apt`, `dnf`, `zypper`) |
| `aurHelper` | root | AUR helper command, e.g. `yay` or `paru` (Arch only, optional) |
| `categories[].name` | category | Category identifier |
| `categories[].description` | category | Human-readable description (optional) |
| `categories[].packages[].name` | package | Package name for the distro's package manager |
| `categories[].packages[].aur` | package | Install via AUR helper instead of pacman (default: `false`) |
| `categories[].packages[].optional` | package | Skip on failure without aborting (default: `false`) |

**Usage:**

```bash
# Preview without installing
bash install-packages.sh --dry-run

# Install all packages
bash install-packages.sh

# Install only specific categories
bash install-packages.sh --category base --category utilities

# Use a custom config path
bash install-packages.sh --config /path/to/packages.json

# Skip AUR packages
bash install-packages.sh --no-aur
```

**Expanding to other distributions:**

Create a new directory following the same structure (e.g. `debian/`, `fedora/`) with its own `packages.json` and `install-packages.sh`. The `packageManager` field determines the install command used:

| `packageManager` | Install command |
|---|---|
| `pacman` | `sudo pacman -S --noconfirm --needed` |
| `apt` | `sudo apt-get install -y` |
| `dnf` | `sudo dnf install -y` |
| `zypper` | `sudo zypper install -y` |
