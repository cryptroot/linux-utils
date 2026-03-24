# linux-utils

A collection of Linux utilities and helpers.

> **Warning:** Some of these scripts will erase all data on the target disk. Review the configuration carefully before running.

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
| `tools/update-manager.sh` | Update manager — status display, automated upgrades, and systemd timer management |
| `installation/automated.sh` | Non-interactive installer driven by a named JSON config |
| `tools/snapshot-manager.sh` | Interactive snapper wrapper — list, create, delete, diff, and restore btrfs snapshots |
| `config/install.json` | Named configuration presets for automated installs |

**Setup:**

1. Boot from the Arch Linux installation medium
2. Connect to the internet (`iwctl` for Wi-Fi, or plug in Ethernet)
3. Install git and clone the repo:
   ```bash
   pacman -Sy git
   git clone https://github.com/cryptroot/linux-utils.git
   ```
4. Run `install.sh` from the root directory or `cd linux-utils/archlinux`

**Usage (TUI — recommended):**

4. Run the interactive wizard:
   ```bash
   bash installation/install-tui.sh
   ```

**Usage (headless):**

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

4. Review/edit configuration presets in `config/install.json`
5. Preview without making changes:
   ```bash
   bash installation/automated.sh minimal-vm -- --dry-run
   ```
6. Run:
   ```bash
   bash installation/automated.sh minimal-vm
   ```

Passwords can be passed via environment variables (`ROOT_PASSWORD`, `USER_PASSWORD`, `LUKS_PASSWORD`).

**Note:** If the password is shorter than 8 characters, you will be prompted to check if you are sure.

**Note:** If the disk already contains device signatures, you will be prompted to type YES to wipe it.

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
- Daily automated system update via systemd timer (`update-manager`)
- AUR package updates via `yay`/`paru` (when installed)
- Btrfs snapshots managed by [snapper](https://wiki.archlinux.org/title/Snapper) with `snapshot-manager` CLI (list, create, delete, diff, restore)
  - Automatic timeline snapshots (hourly, with configurable retention)
  - Pre/post snapshots on every pacman transaction via `snap-pac`
  - Automatic cleanup via `snapper-cleanup.timer`
- `--dry-run` mode to preview configuration without making changes
- Full install log saved to `/var/log/arch-install.log`

### Testing

- **Non-installation changes:** These are tested on a pre-existing Linux install. These do not require additional testing in a new environment if the scripts are single-use - i.e. they self-manage their own dependencies and handle their own logic - see `archlinux/tools/system-check.sh` as an example.

- **Installation changes:** [**IMPORTANT**] These *MUST* be tested end-to-end using a new install. Personally, I have been using virt-manager to create QEMU VMs to test any installation logic. However, it would be better if a machine running on real hardware could be used - I've only used AMD hardware so the `nvidia` and `intel` installations are potentially flaky / non-functional in some circumstances. Since I've been using `archlinux` to do all my work, I've used the scripts to do my own installs too as a self-test.