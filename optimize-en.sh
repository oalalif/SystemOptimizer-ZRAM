#!/bin/bash
# ==============================================================================
# System Optimizer Script - Modern & Ubuntu-Architecture Synchronized
# Optimizes RAM (ZRAM zstd/Generator), CPU Scheduler, Disk I/O, & System Cleanup
# Version: 3.2.0 - systemd-zram-generator integration, zstd 4x compression,
#                  safe swap detection, anti-thrash kernel tuning
# ==============================================================================
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root!${NC}"
    echo "Use: sudo $0"
    exit 1
fi

# Check dependencies
check_dependencies() {
    local missing_deps=()
    for cmd in bc swapon swapoff; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "${RED}❌ Missing dependencies: ${missing_deps[*]}${NC}"
        log "Install with: sudo apt install ${missing_deps[*]}  # For Debian/Ubuntu"
        log "Or: sudo dnf install ${missing_deps[*]}  # For Fedora"
        log "Or: sudo pacman -S ${missing_deps[*]}  # For Arch"
        exit 1
    fi
}

# Display help
show_help() {
    cat << EOF
🚀 System Optimizer Script (Modern ZRAM & Kernel Tuning)

USAGE:
    sudo ./optimize-en.sh [MODE] [OPTIONS]

MODES:
    (none)          - Full optimization (RAM + CPU + Cleanup)
    ram             - Optimize RAM and ZRAM only
    cpu             - Optimize CPU and I/O Scheduler only
    cleanup         - System cleanup only (package manager caches, logs, temp)
    
OPTIONS:
    --zram PERCENT     - ZRAM size relative to RAM (0.1-1.5, default: 1.0 = 100% RAM)
    --swappiness N     - Swappiness value (0-200, default: 180 for ZRAM)
    --algorithm ALGO   - Compression algorithm (zstd, lz4, lzo-rle, default: zstd)
    --no-zram          - Skip ZRAM setup
    --force-zram       - Force reset and re-setup ZRAM
    --help, -h         - Show this help

EXAMPLES:
    sudo ./optimize-en.sh                   # Standard full modern optimization
    sudo ./optimize-en.sh ram               # RAM & ZRAM (100% RAM, zstd, swappiness 180)
    sudo ./optimize-en.sh ram --zram 0.5    # ZRAM 50% RAM
    sudo ./optimize-en.sh ram --no-zram     # RAM without ZRAM
    sudo ./optimize-en.sh cleanup           # Temporary and cache cleanup only
EOF
}

# Parse arguments
MODE="all"
ZRAM_PERCENT=1.0
SWAPPINESS=180
PREFERRED_ALGO="zstd"
SKIP_ZRAM=false
FORCE_ZRAM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        ram|cpu|cleanup)
            MODE="$1"
            shift
            ;;
        --zram)
            ZRAM_PERCENT="$2"
            shift 2
            ;;
        --swappiness)
            SWAPPINESS="$2"
            shift 2
            ;;
        --algorithm)
            PREFERRED_ALGO="$2"
            shift 2
            ;;
        --no-zram)
            SKIP_ZRAM=true
            shift
            ;;
        --force-zram)
            FORCE_ZRAM=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log "❌ Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate ZRAM parameter
validate_zram() {
    local value="$1"
    if ! [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log "❌ ZRAM percentage must be a decimal or integer (e.g.: 0.5, 1.0, 1.25)"
        return 1
    fi
    if (( $(echo "$value < 0.1 || $value > 1.5" | bc -l) )); then
        log "❌ ZRAM percentage must be between 0.1 and 1.5"
        return 1
    fi
    return 0
}

# Validate swappiness (modern Linux kernels support up to 200 for zram/swap)
validate_swappiness() {
    local value="$1"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 200 ]]; then
        log "❌ Swappiness must be an integer between 0 and 200"
        return 1
    fi
    return 0
}

# Check ZRAM kernel support
check_zram_support() {
    log "🔍 Checking ZRAM kernel support..."
    if [[ -f /proc/config.gz ]] && zcat /proc/config.gz | grep -q "CONFIG_ZRAM="; then
        log "✅ ZRAM supported (built-in kernel)"
        return 0
    elif [[ -f /boot/config-$(uname -r) ]] && grep -q "CONFIG_ZRAM" /boot/config-$(uname -r); then
        log "✅ ZRAM supported (kernel config)"
        return 0
    elif modinfo zram >/dev/null 2>&1; then
        log "✅ ZRAM kernel module available"
        return 0
    elif [[ -d /sys/module/zram ]]; then
        log "✅ ZRAM kernel module loaded"
        return 0
    else
        log "❌ ZRAM is not supported by current kernel"
        return 1
    fi
}

# Check available memory (extreme OOM safeguard only)
check_available_memory() {
    local zram_size=$1
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local free_mem_kb
    free_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [[ $free_mem_kb -lt 65536 ]]; then
        log "⚠️ Available memory ($((free_mem_kb/1024))MB) is critically low. Unsafe to initialize ZRAM."
        return 1
    fi
    log "✅ Sufficient memory for ZRAM initialization (available: $((free_mem_kb/1024))MB, target pool: $((zram_size/1024/1024))MB)"
    return 0
}

# Detect systemd-zram-generator presence
is_systemd_zram_generator_present() {
    if [[ -x /usr/lib/systemd/system-generators/zram-generator ]] || \
       systemctl list-unit-files 2>/dev/null | grep -q "systemd-zram-setup"; then
        return 0
    fi
    return 1
}

# Safe standalone ZRAM cleanup without triggering kernel freeze
cleanup_zram_standalone() {
    log "===== Cleaning Up ZRAM (Standalone Mode) ====="
    
    # Deactivate active ZRAM swap devices
    if swapon --show=NAME --noheadings >/dev/null 2>&1; then
        while read -r swap_dev; do
            if [[ "$swap_dev" =~ /dev/zram[0-9]* ]]; then
                if [[ -b "$swap_dev" ]]; then
                    swapoff "$swap_dev" 2>/dev/null && log "✅ Deactivated swap: $(basename "$swap_dev")" || log "⚠ Failed to swapoff: $(basename "$swap_dev")"
                fi
            fi
        done < <(swapon --show=NAME --noheadings)
    fi

    # Reset devices via zramctl if available
    if command -v zramctl >/dev/null 2>&1; then
        local zram_devices
        zram_devices=$(zramctl --noheadings --output NAME 2>/dev/null || true)
        if [[ -n "$zram_devices" ]]; then
            echo "$zram_devices" | while read -r zram_dev; do
                if [[ -n "$zram_dev" && -b "$zram_dev" ]]; then
                    zramctl --reset "$zram_dev" 2>/dev/null && log "✅ Reset device: $(basename "$zram_dev")" || true
                fi
            done
        fi
    fi
}

# Modern ZRAM setup
setup_zram() {
    local zram_size=$1
    local zram_size_mb=$((zram_size / 1024 / 1024))
    
    log "===== Setting Up ZRAM ====="
    
    if ! check_zram_support; then
        return 1
    fi
    
    if ! check_available_memory "$zram_size"; then
        log "❌ Failed to setup ZRAM due to critical physical memory limit"
        return 1
    fi

    # 1. PRIMARY ARCHITECTURE: systemd-zram-generator (Ubuntu / Fedora / Debian modern standard)
    if is_systemd_zram_generator_present; then
        log "⚙ Using modern architecture: systemd-zram-generator"
        
        # Clean any static /dev/zram0 entry from /etc/fstab that causes 90s boot delay
        local FSTAB="/etc/fstab"
        if grep -q "^/dev/zram0" "$FSTAB" 2>/dev/null; then
            sed -i 's|^/dev/zram0|# /dev/zram0 (automatically managed by systemd-zram-generator)|g' "$FSTAB"
            log "  -> Commented out static /dev/zram0 in fstab (eliminates 90s boot delay)."
        fi

        # Generate generator configuration
        local gen_conf="/etc/systemd/zram-generator.conf"
        mkdir -p /etc/systemd
        cat << EOF > "$gen_conf"
[zram0]
zram-size = ${zram_size_mb}
compression-algorithm = ${PREFERRED_ALGO}
swap-priority = 100
EOF
        log "  -> Wrote configuration: $gen_conf (${zram_size_mb}MB, ${PREFERRED_ALGO}, priority 100)"
        
        systemctl daemon-reload
        if systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || systemctl start /dev/zram0 2>/dev/null; then
            log "✅ Service systemd-zram-setup@zram0 successfully started"
            sleep 1
            if swapon --show=NAME --noheadings | grep -q "/dev/zram0"; then
                log "✅ /dev/zram0 active as primary swap"
                if command -v zramctl >/dev/null 2>&1; then
                    zramctl /dev/zram0 2>/dev/null | while read -r line; do log "   $line"; done
                fi
                return 0
            fi
        fi
        log "⚠️ systemd-zram-generator restart failed, attempting standalone fallback..."
    fi

    # 2. FALLBACK ARCHITECTURE: Standalone zramctl / modprobe
    log "⚙ Using fallback architecture: standalone zramctl"
    if [[ "$FORCE_ZRAM" == "true" ]]; then
        cleanup_zram_standalone
    fi

    if ! lsmod | grep -q "^zram"; then
        modprobe zram num_devices=1 >/dev/null 2>&1 || modprobe zram >/dev/null 2>&1 || true
    fi

    if ! command -v zramctl >/dev/null 2>&1; then
        log "❌ Command zramctl not found for standalone mode"
        return 1
    fi

    # Determine supported compression algorithm
    local chosen_algo="${PREFERRED_ALGO}"
    if [[ -f /sys/block/zram0/comp_algorithm ]]; then
        local supported_algos
        supported_algos=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
        if ! echo "$supported_algos" | grep -q "${PREFERRED_ALGO}"; then
            if echo "$supported_algos" | grep -q "zstd"; then
                chosen_algo="zstd"
            elif echo "$supported_algos" | grep -q "lz4"; then
                chosen_algo="lz4"
            elif echo "$supported_algos" | grep -q "lzo-rle"; then
                chosen_algo="lzo-rle"
            fi
            log "ℹ Algorithm ${PREFERRED_ALGO} unsupported, using fallback: ${chosen_algo}"
        fi
    fi

    local zram_dev
    zram_dev=$(zramctl --find --size "${zram_size_mb}M" --algorithm "${chosen_algo}" 2>/dev/null || true)
    if [[ -z "$zram_dev" || ! -b "$zram_dev" ]]; then
        if [[ -b /dev/zram0 ]]; then
            swapoff /dev/zram0 2>/dev/null || true
            zramctl --reset /dev/zram0 2>/dev/null || true
            zramctl /dev/zram0 --size "${zram_size_mb}M" --algorithm "${chosen_algo}" 2>/dev/null || true
            zram_dev="/dev/zram0"
        fi
    fi

    if [[ -n "$zram_dev" && -b "$zram_dev" ]]; then
        mkswap "$zram_dev" >/dev/null 2>&1
        swapon -p 100 "$zram_dev" >/dev/null 2>&1
        log "✅ ZRAM active: ${zram_size_mb}MB (${chosen_algo}) on $zram_dev (Priority 100)"
        zramctl "$zram_dev" 2>/dev/null | while read -r line; do log "   $line"; done
        return 0
    fi

    log "❌ Failed to initialize ZRAM via standalone mode"
    return 1
}

# Safe swap priorities management (DO NOT blindly scan disk blocks which causes I/O thrashing)
manage_swap_priorities() {
    log "===== Managing Secondary Swap Priorities (Safe Mode) ====="
    local swap_devices=()

    # Only include swaps currently active in /proc/swaps
    if [[ -f /proc/swaps ]]; then
        while read -r line; do
            if [[ "$line" =~ ^/[^[:space:]]+ ]]; then
                local dev_name
                dev_name=$(echo "$line" | awk '{print $1}')
                if [[ ! "$dev_name" =~ /dev/zram[0-9]* && ! " ${swap_devices[*]} " =~ " $dev_name " ]]; then
                    swap_devices+=("$dev_name")
                fi
            fi
        done < /proc/swaps
    fi

    # And swaps legitimately uncommented in /etc/fstab
    if [[ -f /etc/fstab ]]; then
        while read -r line; do
            if [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+)[[:space:]]+swap[[:space:]]+swap ]]; then
                local fstab_dev="${BASH_REMATCH[1]}"
                if [[ ! "$fstab_dev" =~ /dev/zram[0-9]* && ! " ${swap_devices[*]} " =~ " $fstab_dev " ]]; then
                    swap_devices+=("$fstab_dev")
                fi
            fi
        done < /etc/fstab
    fi

    # Set secondary swap priority lower than ZRAM (ZRAM = 100)
    for s_dev in "${swap_devices[@]}"; do
        if [[ -b "$s_dev" || -f "$s_dev" ]]; then
            if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q "^$s_dev"; then
                swapon "$s_dev" 2>/dev/null && log "✅ Activated secondary swap: $s_dev" || true
            fi
            if [[ "$s_dev" =~ /swapfile[0-9]* ]]; then
                swapoff "$s_dev" 2>/dev/null && swapon -p 10 "$s_dev" 2>/dev/null && log "📍 Priority $s_dev: 10 (Secondary fallback)" || true
            elif [[ "$s_dev" =~ /dev/sd[a-z][0-9] ]]; then
                swapoff "$s_dev" 2>/dev/null && swapon -p 5 "$s_dev" 2>/dev/null && log "📍 Priority partition $s_dev: 5 (Secondary fallback)" || true
            fi
        fi
    done
}

# RAM & Kernel Memory Subsystem Optimization
optimize_ram() {
    local zram_percent=${ZRAM_PERCENT}
    local swappiness=${SWAPPINESS}
    
    log "===== Tuning RAM & Kernel Memory Subsystem ====="
    
    if ! validate_zram "$zram_percent" || ! validate_swappiness "$swappiness"; then
        exit 1
    fi
    
    local total_ram_kb
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$(( total_ram_kb / 1024 / 1024 ))
    
    log "🖌 Total Physical RAM: ${total_ram_gb}GB"
    log "🔧 Setting Swappiness: $swappiness (High swappiness maximizes RAM in-memory compression)"
    sysctl vm.swappiness="$swappiness" >/dev/null
    
    if [[ "$SKIP_ZRAM" == "true" ]]; then
        log "⏩ ZRAM configuration skipped (--no-zram)"
    else
        local zram_size
        zram_size=$(echo "$total_ram_kb * 1024 * $zram_percent" | bc -l | cut -d. -f1)
        local zram_size_mb=$(( zram_size / 1024 / 1024 ))
        local zram_percent_int
        zram_percent_int=$(echo "$zram_percent * 100" | bc -l | cut -d. -f1)
        log "📏 Target ZRAM Pool Capacity: ${zram_size_mb}MB (${zram_percent_int}% of physical RAM)"
        
        if setup_zram "$zram_size"; then
            log "✅ ZRAM compression pool operating properly"
        else
            log "⚠ ZRAM setup failed, continuing with remaining memory subsystems"
        fi
    fi
    
    manage_swap_priorities
    
    # Kernel VM Tuning (High-Throughput, Zero-Thrash & Anti-Freeze)
    log "🚀 Applying anti-freeze kernel VM parameters..."
    {
        # Maintain directory and dentry cache in RAM
        echo 50 > /proc/sys/vm/vfs_cache_pressure
        # 0 = Read 1 page (4KB) without cluster read-ahead (ZRAM requires zero seek overhead)
        echo 0 > /proc/sys/vm/page-cluster 2>/dev/null || true
        # Smooth dirty page flushing prevents desktop lockups during heavy I/O
        echo 10 > /proc/sys/vm/dirty_ratio
        echo 5 > /proc/sys/vm/dirty_background_ratio
        # Prevent kernel watermark panic cache dumps
        echo 0 > /proc/sys/vm/watermark_boost_factor 2>/dev/null || true
        echo 125 > /proc/sys/vm/watermark_scale_factor 2>/dev/null || true
        # Compact memory smoothly
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    } 2>/dev/null || true
    
    # Persist sysctl parameters permanently if directory exists
    if [[ -d /etc/sysctl.d ]]; then
        cat << 'EOF' > /etc/sysctl.d/99-zram-performance.conf
# ==============================================================================
# Anti-Freeze & ZRAM High-Throughput Memory Settings
# ==============================================================================
vm.swappiness = 180
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
EOF
        log "💾 Permanent configuration saved to /etc/sysctl.d/99-zram-performance.conf"
    fi

    log "✅ RAM & VM optimization complete"
}

# CPU & I/O Scheduler Optimization
optimize_cpu() {
    log "===== Tuning CPU & Disk I/O ====="
    
    log "⚡ Optimizing CPU Frequency Governor..."
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        local available_governors
        available_governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
        
        if echo "$available_governors" | grep -q "schedutil"; then
            echo "schedutil" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor set to: schedutil (Responsive & Energy Efficient)"
        elif echo "$available_governors" | grep -q "ondemand"; then
            echo "ondemand" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor set to: ondemand"
        elif echo "$available_governors" | grep -q "performance"; then
            echo "performance" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor set to: performance"
        fi
    fi
    
    # Kernel Scheduler Latency Tuning
    {
        echo 1000000 > /proc/sys/kernel/sched_latency_ns 2>/dev/null || true
        echo 100000 > /proc/sys/kernel/sched_min_granularity_ns 2>/dev/null || true
        echo 25000000 > /proc/sys/kernel/sched_migration_cost_ns 2>/dev/null || true
        echo 4000000 > /proc/sys/kernel/sched_wakeup_granularity_ns 2>/dev/null || true
    } 2>/dev/null || true
    
    # I/O Scheduler Tuning
    for disk in /sys/block/sd* /sys/block/nvme* /sys/block/mmcblk*; do
        if [[ -f "$disk/queue/scheduler" ]]; then
            local available
            available=$(cat "$disk/queue/scheduler" 2>/dev/null || echo "")
            local disk_name
            disk_name=$(basename "$disk")
            
            if [[ "$disk_name" =~ ^nvme ]] && echo "$available" | grep -q "none"; then
                echo "none" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): none (NVMe optimized)"
            elif echo "$available" | grep -q "mq-deadline" && [[ "$disk_name" =~ ^(sd|nvme) ]]; then
                echo "mq-deadline" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): mq-deadline (SSD/HDD optimized)"
            elif echo "$available" | grep -q "kyber" && [[ "$disk_name" =~ ^nvme ]]; then
                echo "kyber" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): kyber"
            elif echo "$available" | grep -q "deadline"; then
                echo "deadline" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): deadline"
            fi
        fi
    done 2>/dev/null || true
    
    log "✅ CPU & Disk I/O optimization complete"
}

# System cleanup
cleanup_system() {
    log "===== Safe System Cleanup ====="
    
    sync
    log "🧹 Syncing & dropping filesystem page caches..."
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    log "🗑 Cleaning package manager archives and unused packages..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1 && log "✅ APT cleanup completed" || true
    fi
    
    if command -v dnf >/dev/null 2>&1; then
        dnf autoremove -y >/dev/null 2>&1 && dnf clean all >/dev/null 2>&1 && log "✅ DNF cleanup completed" || true
    fi
    
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sc --noconfirm >/dev/null 2>&1 && log "✅ Pacman cleanup completed" || true
    fi
    
    log "📂 Cleaning temporary files & vacuuming systemd journal logs..."
    {
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true
        journalctl --vacuum-size=50M >/dev/null 2>&1 || true
    } || true
    log "✅ Cleanup complete"
}

# Display summary status
show_status() {
    log "===== Post-Optimization System Status ====="
    
    local mem_info
    mem_info=$(free -h | grep "^Mem:")
    local mem_used
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_total
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    log "💾 Physical Memory: $mem_used / $mem_total"
    
    if swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings >/dev/null 2>&1; then
        log "🔍 Active Swap:"
        while read -r name type size used prio; do
            log "   $(basename "$name") ($type): ${used} / ${size} (Priority: $prio)"
        done < <(swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings)
    else
        log "🔍 No active swap detected"
    fi
    
    if command -v zramctl >/dev/null 2>&1 && [[ -n "$(zramctl --noheadings 2>/dev/null)" ]]; then
        log "📊 ZRAM Compression Status:"
        zramctl 2>/dev/null | while read -r line; do log "   $line"; done
    fi
    
    local load_avg
    load_avg=$(cat /proc/loadavg | cut -d' ' -f1-3)
    log "📈 Load Average: $load_avg"
}

# Main Execution
check_dependencies
log "🚀 Starting System Optimizer [Mode: $MODE]"

case "$MODE" in
    ram)
        optimize_ram
        ;;
    cpu)
        optimize_cpu
        ;;
    cleanup)
        cleanup_system
        ;;
    all|*)
        optimize_ram
        optimize_cpu
        cleanup_system
        ;;
esac

show_status
log "🎉 All optimization routines executed successfully!"
