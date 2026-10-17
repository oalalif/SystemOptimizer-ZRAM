# SystemOptimizer-ZRAM

A robust, modern Linux system optimization suite designed to maximize RAM throughput via ZRAM (`zstd` compression & `systemd-zram-generator`), optimize CPU governors and scheduler latency, manage disk I/O schedulers, and safely perform system cleanup without disk thrashing. Available in Indonesian (`optimize-id.sh`) and English (`optimize-en.sh`).

## Table of Contents
- [Overview](#overview)
- [Architecture & The Modern ZRAM Standard](#architecture--the-modern-zram-standard)
- [Key Improvements in Version 3.2.0](#key-improvements-in-version-320)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Alias Configuration](#alias-configuration)
- [Troubleshooting & Solved Conflicts](#troubleshooting--solved-conflicts)
- [Contributing](#contributing)
- [License](#license)

---

## Overview
This script tunes Linux systems for peak responsiveness and memory efficiency:
- **Primary Swap Pool**: High-performance in-memory ZRAM with `zstd` compression (~4.3x ratio).
- **Zero Disk Thrashing**: Prohibits rogue activation of unallocated or external USB drive swap partitions.
- **CPU Scheduler Optimization**: Schedutil / performance governors and ultra-low task latency parameters.
- **I/O Scheduler Optimization**: Direct NVMe `none` bypass, MQ-Deadline for SSDs/HDDs.
- **System Debloat**: Safe cleanup of package caches (APT/DNF/Pacman) and vacuuming systemd journal logs.

**Current Version**: `3.2.1` (Native `systemd-zram-generator` integration, `zstd` 4x compression, automated conflict resolution for `zswap`/`zram-config`/`zramswap`, safe secondary swap management).

---

## Architecture & The Modern ZRAM Standard

### 1. `systemd-zram-generator` vs. Legacy Standalone `zramctl`
- **Modern Linux (Ubuntu 22.04/24.04, Fedora, Debian 12+)**:
  The system uses `systemd-zram-generator` controlled via `/etc/systemd/zram-generator.conf`. Systemd manages `/dev/zram0` as a native service (`systemd-zram-setup@zram0.service`).
  - *Previous Error*: Legacy scripts attempted to forcibly unload `rmmod zram` or run `zramctl --reset`, conflicting directly with active systemd units and causing "Device or resource busy" or boot failures.
  - *Version 3.2.0 Solution*: Automatically detects `systemd-zram-generator`, writes clean unit configurations, reloads systemd cleanly, and eliminates module race conditions.
- **Standalone Fallback**:
  For distributions without systemd or the generator, the script seamlessly falls back to graceful `zramctl` configuration without indiscriminate process termination (`fuser -k`).

### 2. Compression: `zstd` vs. `lz4`
- `lz4`: Older standard, fast but offers ~1.8x – 2.1x compression ratio.
- `zstd`: Modern standard on multi-core CPUs. Delivers ~3.5x – 4.5x compression ratio with negligible CPU overhead, allowing 8GB of RAM to comfortably hold 15GB+ of compressed memory without hitting slow disk storage.

### 3. Swappiness (180) & Zero Page-Cluster
- **Swappiness = 180**: Because ZRAM operates at RAM speeds (5–10 GB/s), setting a high swappiness tells the kernel to aggressively compress inactive memory pages into ZRAM. This keeps filesystem caches (`page cache`) intact and prevents disk I/O lockups.
- **Page-Cluster = 0**: Disables disk read-ahead seek clustering. Since RAM has zero seek penalty, reading 1 page (4KB) at a time delivers instantaneous decompression latency.

---

## Key Improvements in Version 3.2.0
1. **Eliminated False "Available Memory Too Low" Error**: Removed the flawed check that required 110% of uncompressed free RAM. ZRAM allocates dynamically upon compression.
2. **Prevented Boot Delay (90s Hang)**: Automatically sanitizes `/etc/fstab` to comment out static `/dev/zram0` entries that cause systemd mount timeouts during boot.
3. **Safe Swap Priority Management**: Replaced blind `/dev/sd*` device scanning with strict verification of active `/proc/swaps` and `/etc/fstab` entries, permanently preventing external USB SSDs from being accidentally turned into thrashing swap devices.
4. **Anti-Freeze Kernel Parameters**: Tuned `vfs_cache_pressure = 50`, `dirty_ratio = 10`, `dirty_background_ratio = 5`, and `watermark_boost_factor = 0` to eliminate desktop stutter.

---

## Features
- **RAM & Swap**:
  - Dynamically configures ZRAM size (default: 100% RAM pool).
  - Defaults to optimal `zstd` compression with automatic fallback to `lz4`/`lzo-rle`.
  - Sets swappiness to 180 and page-cluster to 0.
- **CPU & I/O**:
  - Sets `schedutil` or `performance` governor.
  - Lowers scheduling latencies (`sched_latency_ns`, `sched_migration_cost_ns`).
  - Sets NVMe drives to `none` scheduler and SSD/HDD to `mq-deadline`.
- **System Maintenance**:
  - Trims APT, DNF, and Pacman package archives.
  - Vacuums systemd journal logs (>50MB or >7d).
- **Safety First**:
  - Never kills running processes using `fuser -k`.
  - Full syntax compatibility and POSIX error handling (`set -euo pipefail`).

---

## Installation
1. **Clone the repository**:
   ```bash
   git clone https://github.com/oalalif/SystemOptimizer-ZRAM.git
   cd SystemOptimizer-ZRAM
   ```
2. **Install dependencies**:
   - Debian / Ubuntu:
     ```bash
     sudo apt update && sudo apt install -y bc util-linux systemd-zram-generator
     ```
   - Fedora:
     ```bash
     sudo dnf install -y bc util-linux zram-generator
     ```
   - Arch Linux:
     ```bash
     sudo pacman -S --noconfirm bc util-linux zram-generator
     ```
3. **Make executable**:
   ```bash
   chmod +x optimize-id.sh optimize-en.sh
   ```

---

## Usage
Run as root:
```bash
# Indonesian
sudo ./optimize-id.sh [MODE] [OPTIONS]

# English
sudo ./optimize-en.sh [MODE] [OPTIONS]
```

### Modes
- `(none)` / `all`: Full optimization (RAM + CPU + Cleanup)
- `ram`: Optimize RAM and ZRAM only
- `cpu`: Optimize CPU and I/O scheduler only
- `cleanup`: Clean package caches, journals, and temporary files

### Options
| Option | Description | Default |
| :--- | :--- | :--- |
| `--zram PERCENT` | Target ZRAM pool ratio relative to physical RAM (0.1–1.5) | `1.0` (100% RAM) |
| `--swappiness N` | Kernel swappiness (0–200) | `180` |
| `--algorithm ALGO` | Compression algorithm (`zstd`, `lz4`, `lzo-rle`) | `zstd` |
| `--no-zram` | Skip ZRAM configuration entirely | - |
| `--force-zram` | Force reset of standalone ZRAM devices | - |
| `--help`, `-h` | Display help message | - |

---

## Alias Configuration
Add these aliases to your `~/.bashrc` or `~/.zshrc`:
```bash
# Main optimizers
alias sysopt='sudo ~/bin/optimize-id.sh'
alias ramopt='sudo ~/bin/optimize-id.sh ram'
alias cpuopt='sudo ~/bin/optimize-id.sh cpu'
alias cleanopt='sudo ~/bin/optimize-id.sh cleanup'

# Monitoring
alias zramstat='zramctl'
alias memstat='free -h && swapon --show'
alias zramlog='sudo dmesg | grep -i zram'
```

---

## Troubleshooting & Solved Conflicts

### 1. Boot hangs for 90 seconds on "A start job is running for dev-zram0.device"
- **Cause**: ChatGPT or legacy guides advised adding `/dev/zram0 none swap defaults 0 0` into `/etc/fstab`. Because ZRAM block devices are created dynamically by systemd generators after boot, fstab waits 90 seconds for a non-existent static block device.
- **Fix**: The script automatically comments out `/dev/zram0` in `/etc/fstab`. `systemd-zram-generator` mounts the swap unit dynamically at target readiness without any delay.

### 2. "Device or resource busy" during swap modification
- **Cause**: Attempting to run `modprobe -r zram` while `systemd-zram-setup@zram0.service` holds the device open.
- **Fix**: Version 3.2.0 interacts directly with `systemctl restart systemd-zram-setup@zram0.service` instead of trying to violently unload the kernel module.

### 3. External USB SSD starts thrashing and freezes the machine
- **Cause**: The previous script searched `/dev/sd*` and ran `swapon` on every partition formatted as swap, accidentally activating slow USB SSD partitions.
- **Fix**: The script now strictly checks only currently active swaps in `/proc/swaps` and uncommented entries in `/etc/fstab`.

### 4. Conflicting ZRAM Daemons (`zram-config` & `zram-tools` fighting `systemd-zram-generator`)
- **Cause**: Having legacy packages like `zram-config` or `zram-tools` installed alongside `systemd-zram-generator` causes multiple services to compete for `/dev/zram0` on boot, overriding compression settings, resetting priority down to 5, and allocating fragmented devices per core.
- **Fix**: Version 3.2.1 automatically checks, stops, disables, and masks `zram-config.service` and `zramswap.service`. For complete cleanup on Ubuntu/Debian, run: `sudo apt purge -y zram-config zram-tools`.

### 5. Kernel `zswap` Redundant Double Compression
- **Cause**: Kernel `zswap` intercepts memory pages and compresses them before swapping them out. When swapping to ZRAM, pages end up being compressed twice (once in zswap and once in zram), producing high CPU spikes and memory latency.
- **Fix**: Version 3.2.1 detects active `zswap` and automatically sets `/sys/module/zswap/parameters/enabled` to `0`. To permanently disable it across reboots, add `zswap.enabled=0` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` and run `sudo update-grub`.

---

## Contributing
1. Fork the repository.
2. Create your feature branch (`git checkout -b feature/kernel-enhancement`).
3. Commit your changes (`git commit -m "feat(zram): add support for custom sysctl templates"`).
4. Push to branch (`git push origin feature/kernel-enhancement`).
5. Open a Pull Request.

---

## License
Distributed under the MIT License. See [LICENSE](LICENSE) for more information.
