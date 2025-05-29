# SystemOptimizer-ZRAM

A robust Linux system optimization script for enhancing RAM (with ZRAM), CPU, and system cleanup. Available in Indonesian (`optimize-id.sh`) and English (`optimize-en.sh`).

## Table of Contents
- [Overview](#overview)
- [What is ZRAM?](#what-is-zram)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Alias Configuration](#alias-configuration)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Overview
This script optimizes Linux system performance by:
- Configuring **ZRAM** for compressed RAM-based swap.
- Tuning CPU governors and scheduler parameters.
- Cleaning up temporary files, caches, and package leftovers.
- Managing swap priorities for efficient memory usage.

**Version**: 3.0.0 (Fixed ZRAM failures, robust cleanup, enhanced logging)

## What is ZRAM?
ZRAM is a Linux kernel feature that creates a compressed block device in RAM, used as swap space. It compresses data (e.g., with `lz4` or `zstd`) to reduce memory usage, ideal for systems with limited RAM.

### ZRAM vs. Module vs. Built-In
- **ZRAM Module**:
  - Loaded dynamically via `modprobe zram`.
  - Configurable via parameters (e.g., `num_devices` in `/sys/module/zram/parameters/`).
  - Can be unloaded/reloaded for flexibility.
  - Example: `modprobe zram num_devices=1`
  - Check: `modinfo zram_info`
- **ZRAM Built-In**:
  - Compiled into the kernel, not a separate module.
  - Parameters are fixed at compile-time (no `/sys/module/zram/`).
  - Cannot be unloaded without rebooting.
  - Check: `zcat /proc/config.gz | grep CONFIG_ZRAM`
- **Key Differences**:
  - **Module**: More flexible, supports runtime changes (e.g., `num_devices=1`).
  - **Built-In**: More static, may lack sysfs parameters (e.g., `num_devices` missing).
  - This script supports both, detecting via `/proc/config.gz`, `/boot/config-*`, or `modinfo`.

### ZRAM in This Script
- Configures ZRAM with `zramctl` for precise size and algorithm control.
- Default: 50% of RAM (adjustable 10–150%).
- Uses `lz4` for fast compression.
- Prioritizes ZRAM swap (priority 100) over disk/file swaps (priority 5–10).
- Robust cleanup ensures no conflicts (e.g., multiple ZRAM devices).

## Features
- **RAM Optimization**:
  - Configures ZRAM with customizable size and swappiness.
  - Adjusts kernel parameters (e.g., `vfs_cache_pressure`, `overcommit_memory`).
  - Manages swap priorities for optimal performance.
- **CPU Optimization**:
  - Sets efficient CPU governors (`schedutil`, `ondemand`, or `performance`).
  - Tunes scheduler parameters for responsiveness.
  - Optimizes I/O schedulers (`mq-deadline`, `kyber`, `none` for NVMe).
- **System Cleanup**:
  - Clears caches, temporary files, and logs.
  - Cleans package managers (`apt`, `dnf`, `pacman`).
- **Robustness**:
  - Validates dependencies and memory availability.
  - Handles ZRAM module/built-in differences.
  - Detailed logging for debugging.
- **Multilingual**: Available in Indonesian and English.

## Installation
1. **Clone the repository**:
   ```bash
   git clone https://github.com/oalalif/SystemOptimizer-ZRAM.git
   cd SystemOptimizer-ZRAM
   ```
2. **Install dependencies**:
   - Debian/Ubuntu:
     ```bash
     sudo apt install bc util-linux
     ```
   - Fedora:
     ```bash
     sudo dnf install bc util-linux
     ```
   - Arch:
     ```bash
     sudo pacman -S bc util-linux
     ```
3. **Make executable**:
   ```bash
   chmod +x optimize-id.sh optimize-en.sh
   ```

## Usage
Run as root:
```bash
sudo ./optimize-id.sh [MODE] [OPTIONS]
sudo ./optimize-en.sh [MODE] [OPTIONS]
```

### Modes
- `(none)`: Full optimization (RAM + CPU + Cleanup)
- `ram`: Optimize RAM and ZRAM only
- `cpu`: Optimize CPU only
- `cleanup`: System cleanup only

### Options
| Option | Description | Default |
|-------------|-------------------|---------|
| `--zram PERCENT` | ZRAM size (0.1–1.5x RAM) | 0.5 |
| `--swappiness N` | Swappiness value (0–100) | 10 |
| `--no-zram` | Skip ZRAM setup | - |
| `--force-zram` | Force ZRAM reset | - |
| `--help`, `-h` | Show help | - |

### Examples
- Default optimization:
  ```bash
  sudo ./optimize-id.sh
  ```
- ZRAM with 25% RAM:
  ```bash
  sudo ./optimize-id.sh ram --zram 0.25 --swappiness 15
  ```
- Skip ZRAM:
  ```bash
  sudo ./optimize-id.sh ram --no-zram
  ```
- Force ZRAM reset:
  ```bash
  sudo ./optimize-id.sh ram --force-zram
  ```

## Alias Configuration
Add these to `~/.zshrc` or `~/.bashrc` for convenience:
```bash
# Main optimization
alias sysopt='sudo ~/bin/optimize-id.sh'
alias ramopt='sudo ~/bin/optimize-id.sh ram --zram 0.25 --swappiness 15'
alias cpuopt='sudo ~/bin/optimize-id.sh cpu'
alias cleanopt='sudo ~/bin/optimize-id.sh cleanup'

# ZRAM variants
alias ramoptc='sudo ~/bin/optimize-id.sh ram --zram 0.75 --swappiness 25'
alias ramopt50='sudo ~/bin/optimize-id.sh ram --zram 0.5 --swappiness 20'
alias ramopt25='sudo ~/bin/optimize-id.sh ram --zram 0.25 --swappiness 15'
alias ramopt15='sudo ~/bin/optimize-id.sh ram --zram 0.15 --swappiness 10'
alias ramopt10='sudo ~/bin/optimize-id.sh ram --zram 0.10 --swappiness 10'
alias ramoptno='sudo ~/bin/optimize-id.sh ram --no-zram'
alias ramoptforce='sudo ~/bin/optimize-id.sh ram --force-zram'
alias sysoptno='sudo ~/bin/optimize-id.sh --no-zram'
alias sysoptforce='sudo ~/bin/optimize-id.sh --force-zram'

# Monitoring
alias zramstat='zramctl && cat /proc/swaps'
alias memstat='free -h && cat /proc/swaps'
alias zramdev='ls /sys/block/zram* 2>/dev/null || echo "No ZRAM devices found"'
alias zramlog='sudo dmesg | grep zram'
```

Apply:
```bash
source ~/.zshrc
```

## Troubleshooting
### Common Issues
1. **ZRAM Setup Fails: Insufficient Memory**
   - **Error**: `Available memory too low for ZRAM`
   - **Cause**: Not enough free memory (requires 1.1x ZRAM size).
   - **Solution**:
     ```bash
     sudo sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
     free -h
     sudo ./optimize-id.sh ram --zram 0.25
     ```
     Or use smaller ZRAM:
     ```bash
     sudo ./optimize-id.sh ram --zram 0.10
     ```

2. **Multiple ZRAM Devices (`/dev/zram1`, etc.)**
   - **Error**: `zramctl --find` shows `/dev/zram1` or higher.
   - **Cause**: `num_devices` > 1 in ZRAM module.
   - **Solution**:
     ```bash
     sudo swapoff /dev/zram*
     sudo zramctl --reset /dev/zram*
     sudo modprobe -r zram
     sudo modprobe zram num_devices=1
     echo "options zram num_devices=1" | sudo tee /etc/modprobe.d/zram.conf
     ```

3. **Cannot Unload ZRAM Module**
   - **Error**: `modprobe: FATAL: Module zram is in use`
   - **Cause**: ZRAM devices active or processes using them.
   - **Solution**:
     ```bash
     sudo swapoff /dev/zram*
     sudo zramctl --reset /dev/zram*
     lsof /dev/zram*
     sudo modprobe -r zram
     ```

4. **dmesg Permission Denied**
   - **Error**: `dmesg: read kernel buffer failed: Operation not permitted`
   - **Cause**: `kernel.dmesg_restrict=1` limits non-root access.
   - **Solution**:
     ```bash
     sudo dmesg | grep zram
     ```
     Or disable restriction (less secure):
     ```bash
     sudo sysctl -w kernel.dmesg_restrict=0
     ```

5. **num_devices Parameter Missing**
   - **Error**: `cat: /sys/module/zram/parameters/num_devices: No such file or directory`
   - **Cause**: ZRAM built-in or non-standard kernel.
   - **Solution**:
     ```bash
     ls /sys/block/zram*
     zcat /boot/config-$(uname -r) | grep CONFIG_ZRAM
     ```

6. **Cannot Change Disksize or Algorithm**
   - **Error**: `zram: Cannot change disksize for initialized device`
   - **Cause**: Attempting to modify active ZRAM device.
   - **Solution**:
     ```bash
     sudo swapoff /dev/zram0
     sudo zramctl --reset /dev/zram0
     sudo ./optimize-id.sh ram --force-zram
     ```

### Debugging Tips
- Check ZRAM status:
  ```bash
  zramctl
  cat /proc/swaps
  ```
- Monitor memory:
  ```bash
  free -h
  ```
- View kernel logs:
  ```bash
  sudo dmesg | grep zram
  ```
- Check kernel config:
  ```bash
  zcat /boot/config-$(uname -r) | grep CONFIG_ZRAM
  ```

## Contributing
Contributions are welcome! Please:
1. Fork the repository.
2. Create a feature branch (`git checkout -b feature-name`).
3. Commit changes (`git commit -m "Add feature"`).
4. Push to the branch (`git push origin feature-name`).
5. Open a Pull Request.

Report issues at `https://github.com/oalalif/SystemOptimizer-ZRAM/issues`.

## License
This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
