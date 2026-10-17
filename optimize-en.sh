#!/bin/bash
# ==============================================================================
# System Optimizer Script - Modern Edition & Ubuntu Architecture Synchronization
# RAM (ZRAM zstd/Generator), CPU Scheduler, Disk I/O, and System Cleanup
# Version: 3.2.1 - systemd-zram-generator integration, zstd 4x compression,
#                  conflict resolution (zswap/zram-config/zramswap),
#                  safe swap priority detection, anti-thrash kernel tuning
# ==============================================================================
set -euo pipefail

# Logging colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Verify running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root!${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Dependency checks
check_dependencies() {
    local missing_deps=()
    for cmd in bc swapon swapoff; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "${RED}❌ Missing required dependencies: ${missing_deps[*]}${NC}"
        log "Install via: sudo apt install ${missing_deps[*]}  # Debian/Ubuntu"
        log "Or: sudo dnf install ${missing_deps[*]}           # Fedora"
        log "Or: sudo pacman -S ${missing_deps[*]}           # Arch"
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
    ram             - RAM and ZRAM optimization only
    cpu             - CPU and I/O Scheduler optimization only
    cleanup         - Safe system cleanup only (APT, logs, temporary files)
    
OPTIONS:
    --zram PERCENT     - ZRAM size as fraction of RAM (0.1-1.5, default: 1.0 = 100% RAM)
    --swappiness N     - Kernel swappiness value (0-200, default: 180 for ZRAM)
    --algorithm ALGO   - Compression algorithm (zstd, lz4, lzo-rle, default: zstd)
    --no-zram          - Skip ZRAM configuration
    --force-zram       - Force reset and reinitialize ZRAM device
    --help, -h         - Show this help message

EXAMPLES:
    sudo ./optimize-en.sh                   # Standard full modern optimization
    sudo ./optimize-en.sh ram               # RAM & ZRAM (100% RAM, zstd, swappiness 180)
    sudo ./optimize-en.sh ram --zram 0.5    # ZRAM 50% RAM
    sudo ./optimize-en.sh ram --no-zram     # RAM without ZRAM (conservative swappiness 60)
    sudo ./optimize-en.sh cleanup           # Safe temporary and cache cleanup only
EOF
}

# Argument parsing
MODE="all"
ZRAM_PERCENT=1.0
SWAPPINESS=180
SWAPPINESS_CUSTOM=false
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
            SWAPPINESS_CUSTOM=true
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
            log "${RED}❌ Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Validate ZRAM parameter
validate_zram() {
    local value="$1"
    if ! [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log "${RED}❌ ZRAM percentage must be a valid number (e.g., 0.5, 1.0, 1.25)${NC}"
        return 1
    fi
    if (( $(echo "$value < 0.1 || $value > 1.5" | bc -l) )); then
        log "${RED}❌ ZRAM percentage must be between 0.1 and 1.5${NC}"
        return 1
    fi
    return 0
}

# Validate swappiness
validate_swappiness() {
    local value="$1"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 200 ]]; then
        log "${RED}❌ Swappiness must be an integer between 0 and 200${NC}"
        return 1
    fi
    return 0
}

# Check kernel ZRAM support
check_zram_support() {
    log "🔍 Checking kernel ZRAM support..."
    if [[ -f /proc/config.gz ]] && zcat /proc/config.gz | grep -q "CONFIG_ZRAM="; then
        log "${GREEN}✅ ZRAM supported (built-in kernel)${NC}"
        return 0
    elif [[ -f /boot/config-"$(uname -r)" ]] && grep -q "CONFIG_ZRAM" /boot/config-"$(uname -r)"; then
        log "${GREEN}✅ ZRAM supported (kernel config)${NC}"
        return 0
    elif modinfo zram >/dev/null 2>&1; then
        log "${GREEN}✅ ZRAM kernel module available${NC}"
        return 0
    elif [[ -d /sys/module/zram ]]; then
        log "${GREEN}✅ ZRAM module active${NC}"
        return 0
    else
        log "${RED}❌ ZRAM not supported by current kernel${NC}"
        return 1
    fi
}

# Check available memory
check_available_memory() {
    local zram_size=$1
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local free_mem_kb
    free_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [[ $free_mem_kb -lt 65536 ]]; then
        log "${YELLOW}⚠️ Available memory ($((free_mem_kb/1024))MB) critically low. Unsafe to initialize ZRAM pool.${NC}"
        return 1
    fi
    log "${GREEN}✅ Memory sufficient for ZRAM initialization (available: $((free_mem_kb/1024))MB, target virtual pool: $((zram_size/1024/1024))MB)${NC}"
    return 0
}

# Detect systemd-zram-generator presence
is_systemd_zram_generator_present() {
    if [[ -x /usr/lib/systemd/system-generators/zram-generator || -x /lib/systemd/system-generators/zram-generator ]] || \
       systemctl list-unit-files 2>/dev/null | grep -q "systemd-zram-setup"; then
        return 0
    fi
    return 1
}

# Resolve ZRAM conflicts: disable legacy services & zswap
resolve_zram_conflicts() {
    log "🛡 Checking and resolving ZRAM service & kernel zswap conflicts..."

    # 1. Disable kernel zswap to prevent double compression thrashing
    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        local zswap_state
        zswap_state=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
        if [[ "$zswap_state" == "Y" || "$zswap_state" == "1" ]]; then
            echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
            log "  -> ${YELLOW}Kernel zswap disabled (eliminates redundant double-compression with ZRAM).${NC}"
        fi
    fi

    # 2. Stop and mask conflicting legacy zram services
    local conflicting_services=("zram-config.service" "zramswap.service" "zram-unit.service")
    for svc in "${conflicting_services[@]}"; do
        if systemctl is-active "$svc" >/dev/null 2>&1 || systemctl is-enabled "$svc" >/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
            log "  -> ${YELLOW}Conflicting legacy service '$svc' stopped and masked.${NC}"
        fi
    done

    # 3. Clean static /dev/zram0 entries in /etc/fstab to prevent 90-second boot hang
    local FSTAB="/etc/fstab"
    if grep -q "^/dev/zram0" "$FSTAB" 2>/dev/null; then
        sed -i 's|^/dev/zram0|# /dev/zram0 (managed automatically by systemd-zram-generator)|g' "$FSTAB"
        log "  -> ${GREEN}Static /dev/zram0 disabled in fstab (prevents 90s boot timeout).${NC}"
    fi
}

# Safe standalone ZRAM cleanup
cleanup_zram_standalone() {
    log "===== Cleaning ZRAM (Standalone Mode) ====="
    
    # Deactivate active zram swaps
    if swapon --show=NAME --noheadings >/dev/null 2>&1; then
        while read -r swap_dev; do
            if [[ "$swap_dev" =~ /dev/zram[0-9]* ]]; then
                if [[ -b "$swap_dev" ]]; then
                    if swapoff "$swap_dev" 2>/dev/null; then
                        log "✅ Disabled swap: $(basename "$swap_dev")"
                    else
                        log "⚠ Failed to disable swap: $(basename "$swap_dev")"
                    fi
                fi
            fi
        done < <(swapon --show=NAME --noheadings)
    fi

    # Reset devices via zramctl
    if command -v zramctl >/dev/null 2>&1; then
        local zram_devices
        zram_devices=$(zramctl --noheadings --output NAME 2>/dev/null || true)
        if [[ -n "$zram_devices" ]]; then
            echo "$zram_devices" | while read -r zram_dev; do
                if [[ -n "$zram_dev" && -b "$zram_dev" ]]; then
                    zramctl --reset "$zram_dev" 2>/dev/null || true
                    log "✅ Reset: $(basename "$zram_dev")"
                fi
            done
        fi
    fi
}

# Setup modern ZRAM
setup_zram() {
    local zram_size=$1
    local zram_size_mb=$((zram_size / 1024 / 1024))
    
    log "===== Setting up ZRAM ====="
    
    if ! check_zram_support; then
        return 1
    fi
    
    if ! check_available_memory "$zram_size"; then
        log "${RED}❌ Failed to set up ZRAM due to critical physical memory${NC}"
        return 1
    fi

    # Resolve conflicts before starting
    resolve_zram_conflicts

    # Force reset if requested
    if [[ "$FORCE_ZRAM" == "true" ]]; then
        log "🔄 Executing ZRAM Force Reset..."
        systemctl stop dev-zram0.swap 2>/dev/null || true
        systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
        cleanup_zram_standalone
    fi

    # 1. PRIMARY METHOD: systemd-zram-generator
    if is_systemd_zram_generator_present; then
        log "⚙ Using modern architecture: systemd-zram-generator"
        
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
        if systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || systemctl restart dev-zram0.swap 2>/dev/null || systemctl start /dev/zram0 2>/dev/null; then
            log "${GREEN}✅ systemd-zram-setup@zram0 service successfully activated${NC}"
            sleep 1
            if swapon --show=NAME --noheadings | grep -q "/dev/zram0"; then
                log "${GREEN}✅ /dev/zram0 active as primary swap${NC}"
                if command -v zramctl >/dev/null 2>&1; then
                    zramctl /dev/zram0 2>/dev/null | while read -r line; do log "   $line"; done
                fi
                return 0
            fi
        fi
        log "${YELLOW}⚠️ systemd-zram-generator restart failed, attempting manual fallback...${NC}"
    fi

    # 2. FALLBACK METHOD: Standalone zramctl / modprobe
    log "⚙ Using fallback architecture: zramctl standalone"
    if ! lsmod | grep -q "^zram"; then
        modprobe zram num_devices=1 >/dev/null 2>&1 || modprobe zram >/dev/null 2>&1 || true
    fi

    if ! command -v zramctl >/dev/null 2>&1; then
        log "${RED}❌ zramctl command not found for fallback mode${NC}"
        return 1
    fi

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
            log "${BLUE}ℹ Algorithm ${PREFERRED_ALGO} not supported, falling back to: ${chosen_algo}${NC}"
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
        log "${GREEN}✅ ZRAM active: ${zram_size_mb}MB (${chosen_algo}) on $zram_dev (Priority 100)${NC}"
        zramctl "$zram_dev" 2>/dev/null | while read -r line; do log "   $line"; done
        return 0
    fi

    log "${RED}❌ Failed to initialize ZRAM via standalone mode${NC}"
    return 1
}

# Manage non-ZRAM swap priorities safely
manage_swap_priorities() {
    log "===== Managing Non-ZRAM Swap Priorities (Safe Mode) ====="
    local swap_devices=()

    # 1. Swaps active in /proc/swaps
    if [[ -f /proc/swaps ]]; then
        while read -r line; do
            if [[ "$line" =~ ^/[^[:space:]]+ ]]; then
                local dev_name
                dev_name=$(echo "$line" | awk '{print $1}')
                if [[ ! "$dev_name" =~ /dev/zram[0-9]* ]]; then
                    local already=false
                    for existing in "${swap_devices[@]}"; do
                        if [[ "$existing" == "$dev_name" ]]; then
                            already=true
                            break
                        fi
                    done
                    if [[ "$already" == "false" ]]; then
                        swap_devices+=("$dev_name")
                    fi
                fi
            fi
        done < /proc/swaps
    fi

    # 2. Legitimate swaps in /etc/fstab (mount point 'none' or 'swap')
    if [[ -f /etc/fstab ]]; then
        while read -r line; do
            if [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+)[[:space:]]+(none|swap)[[:space:]]+swap ]]; then
                local fstab_dev="${BASH_REMATCH[1]}"
                if [[ ! "$fstab_dev" =~ /dev/zram[0-9]* ]]; then
                    local already=false
                    for existing in "${swap_devices[@]}"; do
                        if [[ "$existing" == "$fstab_dev" ]]; then
                            already=true
                            break
                        fi
                    done
                    if [[ "$already" == "false" ]]; then
                        swap_devices+=("$fstab_dev")
                    fi
                fi
            fi
        done < /etc/fstab
    fi

    # Configure secondary swap priorities below ZRAM (ZRAM = 100)
    for s_dev in "${swap_devices[@]}"; do
        if [[ -b "$s_dev" || -f "$s_dev" ]]; then
            local target_prio=10
            if [[ "$s_dev" =~ /dev/sd[a-z][0-9] || "$s_dev" =~ /dev/nvme ]]; then
                target_prio=5
            fi

            if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^$s_dev"; then
                local cur_prio
                cur_prio=$(swapon --show=NAME,PRIO --noheadings 2>/dev/null | awk -v d="$s_dev" '$1 == d {print $2}')
                if [[ -n "$cur_prio" && "$cur_prio" -ge 100 ]]; then
                    log "  -> Lowering priority of $s_dev ($cur_prio -> $target_prio)..."
                    swapoff "$s_dev" 2>/dev/null || true
                    swapon -p "$target_prio" "$s_dev" 2>/dev/null || true
                else
                    log "📍 Secondary swap $s_dev already active with safe priority ($cur_prio < 100)"
                fi
            else
                if swapon -p "$target_prio" "$s_dev" 2>/dev/null; then
                    log "${GREEN}✅ Enabled secondary swap: $s_dev (Priority: $target_prio)${NC}"
                fi
            fi
        fi
    done
}

# RAM & VM Subsystem Tuning
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

    if [[ "$SKIP_ZRAM" == "true" ]]; then
        if [[ "$SWAPPINESS_CUSTOM" == "false" ]]; then
            swappiness=60
            log "${BLUE}ℹ ZRAM skipped (--no-zram); swappiness set to conservative default (60) to prevent disk swap thrashing.${NC}"
        fi
    fi
    
    log "🔧 Setting Swappiness: $swappiness"
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
            log "${GREEN}✅ ZRAM compression pool operating smoothly${NC}"
        else
            log "${YELLOW}⚠ ZRAM setup failed, continuing with remaining memory optimizations${NC}"
        fi
    fi
    
    manage_swap_priorities
    
    # Kernel VM Anti-Freeze Tuning
    log "🚀 Applying anti-freeze kernel VM parameters..."
    {
        echo 50 > /proc/sys/vm/vfs_cache_pressure
        echo 0 > /proc/sys/vm/page-cluster 2>/dev/null || true
        echo 10 > /proc/sys/vm/dirty_ratio
        echo 5 > /proc/sys/vm/dirty_background_ratio
        echo 0 > /proc/sys/vm/watermark_boost_factor 2>/dev/null || true
        echo 125 > /proc/sys/vm/watermark_scale_factor 2>/dev/null || true
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    } 2>/dev/null || true
    
    if [[ -d /etc/sysctl.d ]]; then
        cat << EOF > /etc/sysctl.d/99-zram-performance.conf
# ==============================================================================
# Anti-Freeze & ZRAM High-Throughput Memory Settings
# ==============================================================================
vm.swappiness = ${swappiness}
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
EOF
        log "${GREEN}💾 Permanent configuration saved to /etc/sysctl.d/99-zram-performance.conf${NC}"
    fi

    log "${GREEN}✅ RAM & VM optimization complete${NC}"
}

# CPU & Disk I/O Tuning
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
    
    log "${GREEN}✅ CPU & Disk I/O optimization complete${NC}"
}

# System cleanup
cleanup_system() {
    log "===== Safe System Cleanup ====="
    
    sync
    log "🧹 Syncing & dropping filesystem page caches..."
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    log "🗑 Cleaning package manager archives and unused packages..."
    if command -v apt-get >/dev/null 2>&1; then
        if apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1; then
            log "${GREEN}✅ APT cleanup completed${NC}"
        fi
    fi
    
    if command -v dnf >/dev/null 2>&1; then
        if dnf autoremove -y >/dev/null 2>&1 && dnf clean all >/dev/null 2>&1; then
            log "${GREEN}✅ DNF cleanup completed${NC}"
        fi
    fi
    
    if command -v pacman >/dev/null 2>&1; then
        if pacman -Sc --noconfirm >/dev/null 2>&1; then
            log "${GREEN}✅ Pacman cleanup completed${NC}"
        fi
    fi
    
    log "📂 Cleaning temporary files & vacuuming systemd journal logs..."
    {
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true
        journalctl --vacuum-size=50M >/dev/null 2>&1 || true
    } || true
    log "${GREEN}✅ Cleanup complete${NC}"
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
    load_avg=$(cut -d' ' -f1-3 /proc/loadavg)
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
log "${GREEN}🎉 All optimization routines executed successfully!${NC}"
