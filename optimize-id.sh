#!/bin/bash
# System Optimizer Script - ZRAM FIXED VERSION
# Optimasi RAM, CPU, dan cleanup sistem
# Version: 2.9.7 - Fixed zramctl failure, robust ZRAM cleanup, detailed debug logging
set -euo pipefail

# Warna untuk logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Periksa apakah dijalankan sebagai root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Script ini harus dijalankan sebagai root!${NC}"
    echo "Gunakan: sudo $0"
    exit 1
fi

# Periksa dependensi
check_dependencies() {
    local missing_deps=()
    for cmd in bc zramctl swapon swapoff; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "${RED}❌ Dependensi berikut tidak ditemukan: ${missing_deps[*]}${NC}"
        log "Install dengan: sudo apt install ${missing_deps[*]}  # Untuk Debian/Ubuntu"
        log "Atau: sudo dnf install ${missing_deps[*]}  # Untuk Fedora"
        log "Atau: sudo pacman -S ${missing_deps[*]}  # Untuk Arch"
        exit 1
    fi
}

# Tampilkan bantuan
show_help() {
    cat << EOF
🚀 System Optimizer Script

USAGE:
    sudo ./optimize.sh [MODE] [OPTIONS]

MODES:
    (none)          - Optimasi lengkap (RAM + CPU + Cleanup)
    ram             - Hanya optimasi RAM dan ZRAM
    cpu             - Hanya optimasi CPU
    cleanup         - Hanya cleanup sistem
    
OPTIONS:
    --zram PERCENT     - Ukuran ZRAM (0.1-1.5, default: 0.5)
    --swappiness N     - Swappiness value (0-100, default: 10)
    --no-zram          - Skip ZRAM setup
    --force-zram       - Force ZRAM reset dan setup ulang
    --help, -h         - Tampilkan bantuan

EXAMPLES:
    sudo ./optimize.sh ram                  # RAM dengan ZRAM default (50%)
    sudo ./optimize.sh ram --no-zram        # RAM tanpa ZRAM
    sudo ./optimize.sh ram --zram 0.75      # ZRAM 75%
    sudo ./optimize.sh ram --force-zram     # Force ZRAM reset
EOF
}

# Parsing argumen
MODE="all"
ZRAM_PERCENT=0.5
SWAPPINESS=10
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
            log "❌ Opsi tidak dikenal: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validasi parameter ZRAM
validate_zram() {
    local value="$1"
    if ! [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log "❌ Persentase ZRAM harus berupa angka desimal atau bulat (misalnya, 0.5 atau 1)"
        return 1
    fi
    if (( $(echo "$value < 0.1 || $value > 1.5" | bc -l) )); then
        log "❌ Persentase ZRAM harus antara 0.1-1.5"
        return 1
    fi
    return 0
}

# Validasi swappiness
validate_swappiness() {
    local value="$1"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 100 ]]; then
        log "❌ Swappiness harus antara 0-100"
        return 1
    fi
    return 0
}

# Periksa dukungan ZRAM
check_zram_support() {
    log "🔍 Mengecek dukungan ZRAM..."
    if [[ -f /proc/config.gz ]] && zcat /proc/config.gz | grep -q "CONFIG_ZRAM="; then
        log "✅ ZRAM built-in di kernel"
        return 0
    elif [[ -f /boot/config-$(uname -r) ]] && grep -q "CONFIG_ZRAM" /boot/config-$(uname -r); then
        log "✅ ZRAM tersedia di kernel"
        return 0
    elif modinfo zram >/dev/null 2>&1; then
        log "✅ Modul ZRAM tersedia"
        return 0
    else
        log "❌ ZRAM tidak didukung oleh kernel"
        return 1
    fi
}

# Periksa memori tersedia
check_available_memory() {
    local zram_size=$1
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local free_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    local zram_size_kb=$((zram_size / 1024))
    local required_mem_kb=$((zram_size_kb * 11 / 10))  # 1.1x
    if [[ $free_mem_kb -lt $required_mem_kb ]]; then
        log "⚠️ Memori tersedia ($((free_mem_kb/1024))MB) terlalu rendah untuk ZRAM ($((zram_size_kb/1024))MB, diperlukan $((required_mem_kb/1024))MB)"
        return 1
    fi
    log "✅ Memori tersedia cukup: $((free_mem_kb/1024))MB untuk ZRAM $((zram_size_kb/1024))MB"
    return 0
}

# Pembersihan ZRAM
cleanup_zram() {
    log "===== Membersihkan ZRAM ====="
    
    # Nonaktifkan layanan ZRAM
    for service in zram-swap zram zram-unit; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            systemctl stop "$service" 2>/dev/null && log "✅ Menghentikan layanan: $service" || log "⚠️ Gagal menghentikan layanan: $service"
        fi
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            systemctl disable "$service" 2>/dev/null && log "✅ Menonaktifkan layanan: $service" || true
        fi
    done

    # Nonaktifkan swap ZRAM
    if swapon --show=NAME --noheadings >/dev/null 2>&1; then
        while read -r swap_dev; do
            if [[ "$swap_dev" =~ /dev/zram[0-5] ]]; then
                if [[ -b "$swap_dev" ]]; then
                    if command -v fuser >/dev/null 2>&1 && fuser "$swap_dev" >/dev/null 2>&1; then
                        log "⚠ $swap_dev sedang digunakan, mencoba terminate proses"
                        fuser -k "$swap_dev" >/dev/null 2>&1 || true
                        sleep 1
                    fi
                    swapoff "$swap_dev" >/dev/null 2>&1 && log "✅ Matikan swap: $(basename "$swap_dev")" || log "⚠ Gagal mematikan swap: $(basename "$swap_dev")"
                fi
            fi
        done < <(swapon --show=NAME --noheadings)
    fi

    # Reset perangkat ZRAM
    if command -v zramctl >/dev/null 2>&1; then
        local zram_devices=$(zramctl --noheadings --output NAME 2>/dev/null || true)
        if [[ -n "$zram_devices" ]]; then
            echo "$zram_devices" | while read -r zram_dev; do
                if [[ -n "$zram_dev" && -b "$zram_dev" ]]; then
                    zramctl --reset "$zram_dev" 2>/dev/null && log "✅ Reset: $(basename "$zram_dev")" || log "⚠ Gagal reset: $(basename "$zram_dev")"
                fi
            done
        else
            log "ℹ Tidak ada perangkat ZRAM aktif terdeteksi oleh zramctl"
        fi
    fi

    # Periksa /sys/block
    local sys_zram_found=false
    for zram_sys in /sys/block/zram[0-5]; do
        if [[ -d "$zram_sys" ]]; then
            sys_zram_found=true
            local zram_id=$(basename "$zram_sys")
            log "⚠ ZRAM device found in /sys/block: $zram_id"
            if [[ -b "/dev/$zram_id" ]]; then
                zramctl --reset "/dev/$zram_id" 2>/dev/null && log "✅ Reset sys: $zram_id" || log "⚠ Gagal reset sys: $zram_id"
            fi
        fi
    done

    # Unload modul ZRAM
    if lsmod | grep -E "^zram[[:space:]]+" >/dev/null; then
        rmmod zram 2>/dev/null && log "✅ Unload zram module" || log "⚠ Gagal unload zram module"
    else
        log "ℹ Modul zram tidak dimuat"
    fi

    # Pastikan hanya satu perangkat ZRAM
    modprobe zram num_devices=1 2>/dev/null && log "✅ Modul ZRAM dimuat dengan num_devices=1" || log "⚠ Gagal memuat modul ZRAM"
    sleep 5
}

# Setup ZRAM
setup_zram() {
    local zram_size=$1
    
    log "===== Menyiapkan ZRAM ====="
    
    if ! check_zram_support; then
        return 1
    fi
    
    if ! check_available_memory "$zram_size"; then
        log "❌ Gagal menyiapkan ZRAM karena memori tidak cukup"
        return 1
    fi
    
    if (( $(echo "$ZRAM_PERCENT > 0.75" | bc -l) )); then
        log "⚠️ Peringatan: ZRAM di atas 75% RAM mungkin memengaruhi performa"
    fi
    
    cleanup_zram
    
    # Konfigurasi ZRAM
    local zram_size_mb=$((zram_size / 1024 / 1024))
    local zram_dev=""
    local error_msg=$(zramctl --find --size "${zram_size_mb}M" --algorithm lz4 2>&1)
    if [[ $? -eq 0 ]]; then
        zram_dev=$(echo "$error_msg" | grep -o "/dev/zram[0-9]*" || true)
    fi
    if [[ -z "$zram_dev" ]]; then
        log "❌ Gagal membuat perangkat ZRAM dengan zramctl: $error_msg"
        return 1
    fi
    log "✅ ZRAM device created: $zram_dev"
    
    sleep 1
    
    if [[ ! -b "$zram_dev" ]]; then
        log "❌ Perangkat $zram_dev tidak ditemukan"
        return 1
    fi
    
    mkswap "$zram_dev" >/dev/null 2>&1 || { log "❌ mkswap gagal pada $zram_dev"; return 1; }
    swapon -p 100 "$zram_dev" >/dev/null 2>&1 || { log "❌ swapon gagal pada $zram_dev"; return 1; }
    
    log "✅ ZRAM aktif: ${zram_size_mb}MB pada $zram_dev"
    
    zramctl "$zram_dev" 2>/dev/null | while read -r line; do
        if [[ "$line" != "NAME"* ]]; then
            log "📖 $line"
        fi
    done
    
    return 0
}

# Kelola prioritas swap
manage_swap_priorities() {
    log "===== Mengatur prioritas swap ===="
    local swap_devices=()
    if [[ -f /etc/fstab ]]; then
        while read -r line; do
            if [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+)[[:space:]]+swap[[:space:]]+swap[[:space:]]+ ]]; then
                swap_devices+=("${BASH_REMATCH[1]}")
            fi
        done < /etc/fstab
    fi

    if [[ -f /proc/swaps ]]; then
        while read -r line; do
            if [[ "$line" =~ ^/[^[:space:]]+ ]]; then
                local swap_dev=$(echo "$line" | awk '{print $1}')
                if [[ ! "$swap_dev" =~ /dev/zram[0-5] && ! " ${swap_devices[*]} " =~ $swap_dev ]]; then
                    swap_devices+=("$swap_dev")
                fi
            fi
        done < /proc/swaps
    fi

    for dev in /dev/sd*[0-9]; do
        if [[ -b "$dev" ]] && blkid "$dev" | grep -q "TYPE=\"swap\""; then
            if [[ ! " ${swap_devices[*]} " =~ $dev ]]; then
                swap_devices+=("$dev")
            fi
        fi
    done

    for swap_dev in "${swap_devices[@]}"; do
        if [[ -b "$swap_dev" || -f "$swap_dev" ]]; then
            if ! swapon --show=NAME --noheadings | grep -q "^$swap_dev"; then
                swapon "$swap_dev" 2>/dev/null && log "✅ Mengaktifkan swap: $swap_dev" || log "⚠ Gagal mengaktifkan swap: $swap_dev"
            fi
            if [[ "$swap_dev" =~ /swapfile[0-9]* ]]; then
                swapoff "$swap_dev" 2>/dev/null && swapon -p 10 "$swap_dev" 2>/dev/null && log "📍 Prioritas $swap_dev: 10" || log "⚠ Gagal set prioritas $swap_dev"
            elif [[ "$swap_dev" =~ /dev/sd[a-z][0-9] ]]; then
                swapoff "$swap_dev" 2>/dev/null && swapon -p 5 "$swap_dev" 2>/dev/null && log "📍 Prioritas $swap_dev: 5" || log "⚠ Gagal set prioritas $swap_dev"
            fi
        fi
    done
}

# Optimasi RAM
optimize_ram() {
    local zram_percent=${ZRAM_PERCENT}
    local swappiness=${SWAPPINESS}
    
    log "===== Tuning RAM ====="
    
    if ! validate_zram "$zram_percent" || ! validate_swappiness "$swappiness"; then
        exit 1
    fi
    
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$(( total_ram_kb / 1024 / 1024 ))
    
    log "🖌 RAM Total: ${total_ram_gb}GB"
    
    log "🔧 Swappiness: $swappiness"
    sysctl vm.swappiness="$swappiness" >/dev/null
    
    if [[ "$SKIP_ZRAM" == "true" ]]; then
        log "⏩ ZRAM dilewati (--no-zram)"
    else
        local zram_size=$(echo "$total_ram_kb * 1024 * $zram_percent" | bc -l | cut -d. -f1)
        local zram_size_mb=$(( zram_size / 1024 / 1024 ))
        local zram_percent_int=$(echo "$zram_percent * 100" | bc -l | cut -d. -f1)
        log "📏 ZRAM target: ${zram_size_mb}MB (${zram_percent_int}% dari RAM)"
        
        if setup_zram "$zram_size"; then
            log "✅ ZRAM berhasil dikonfigurasi"
        else
            log "⚠ ZRAM setup gagal, melanjutkan tanpa ZRAM"
            log "💡 Coba gunakan --force-zram atau --no-zram"
        fi
    fi
    
    manage_swap_priorities
    
    {
        echo 100 > /proc/sys/vm/vfs_cache_pressure
        echo 1 > /proc/sys/vm/oom_kill_allocating_task
        echo 0 > /proc/sys/vm/oom_dump_tasks
        echo 1 > /proc/sys/vm/overcommit_memory
        echo 32 > /proc/sys/vm/watermark_boost_factor 2>/dev/null || true
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    } 2>/dev/null || true
    
    log "✅ Optimasi RAM selesai"
}

# Optimasi CPU
optimize_cpu() {
    log "===== Tuning CPU ====="
    
    log "⚡ Mengoptimalkan CPU scheduler..."
    
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        local available_governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
        
        if echo "$available_governors" | grep -q "schedutil"; then
            echo "schedutil" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor: schedutil"
        elif echo "$available_governors" | grep -q "ondemand"; then
            echo "ondemand" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor: ondemand"
        elif echo "$available_governors" | grep -q "performance"; then
            echo "performance" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor: performance"
        fi
    fi
    
    {
        echo 1000000 > /proc/sys/kernel/sched_latency_ns
        echo 100000 > /proc/sys/kernel/sched_min_granularity_ns
        echo 25000000 > /proc/sys/kernel/sched_migration_cost_ns
        echo 4000000 > /proc/sys/kernel/sched_wakeup_granularity_ns 2>/dev/null || true
        echo 950000 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null
        echo 1000000 > /proc/sys/kernel/sched_rt_period_us 2>/dev/null
    } 2>/dev/null || true
    
    for disk in /sys/block/sd* /sys/block/nvme* /sys/block/mmcblk*; do
        if [[ -f "$disk/queue/scheduler" ]]; then
            local available=$(cat "$disk/queue/scheduler" 2>/dev/null || echo "")
            local disk_name=$(basename "$disk")
            
            if [[ "$disk_name" =~ ^nvme ]] && echo "$available" | grep -q "none"; then
                echo "none" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): none (NVMe optimized)"
            elif echo "$available" | grep -q "mq-deadline" && [[ "$disk_name" =~ ^(sd|nvme) ]]; then
                echo "mq-deadline" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): mq-deadline"
            elif echo "$available" | grep -q "kyber" && [[ "$disk_name" =~ ^nvme ]]; then
                echo "kyber" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): kyber"
            elif echo "$available" | grep -q "deadline"; then
                echo "deadline" > "$disk/queue/scheduler" 2>/dev/null || true
                log "💾 I/O Scheduler ($disk_name): deadline"
            fi
        fi
    done 2>/dev/null || true
    
    log "✅ Optimasi CPU selesai"
}

# Pembersihan sistem
cleanup_system() {
    log "===== Cleanup Sistem ====="
    
    sync
    
    log "🧹 Drop caches..."
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    log "🗑 Membersihkan paket..."
    if command -v apt >/dev/null 2>&1; then
        apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1 && log "✅ APT cleanup selesai" || true
    fi
    
    if command -v dnf >/dev/null 2>&1; then
        dnf autoremove -y >/dev/null 2>&1 && dnf clean all >/dev/null 2>&1 && log "✅ DNF cleanup selesai" || true
    fi
    
    if command -v pacman >/dev/null 2>&1; then
        pacman -Sc --noconfirm >/dev/null 2>&1 && pacman -Rns $(pacman -Qtdq) --noconfirm >/dev/null 2>&1 && log "✅ Pacman cleanup selesai" || true
    fi
    
    log "📂 Membersihkan file sementara..."
    {
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/log -type f \( -name "*.log" -o -name "*.log.*" \) -mtime +30 -delete 2>/dev/null || true
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true
        journalctl --vacuum-size=50M >/dev/null 2>&1 || true
    } || true
    log "✅ Cleanup selesai"
}

# Tampilkan status
show_status() {
    log "===== Status Sistem ====="
    
    local mem_info=$(free -h | grep "^Mem:")
    local mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_total=$(echo "$mem_info" | awk '{print $2}')
    log "💾 Memori: $mem_used / $mem_total"
    
    if swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings >/dev/null 2>&1; then
        log "🔍 Swap aktif:"
        while read -r name type size used prio; do
            log "   $(basename "$name") ($type): ${used} / ${size} (Prioritas: $prio)"
        done < <(swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings)
    else
        log "🔍 Tidak ada swap aktif"
    fi
    
    local load_avg=$(cat /proc/loadavg | cut -d' ' -f1-3)
    log "📈 Load average: $load_avg"
}

# Eksekusi utama
check_dependencies
log "🚀 Memulai optimasi mode: $MODE"
if [[ "$SKIP_ZRAM" == "false" ]]; then
    zram_percent_int=$(echo "$ZRAM_PERCENT * 100" | bc -l | cut -d. -f1)
    log "📊 Parameter: ZRAM=${ZRAM_PERCENT} (${zram_percent_int}% dari RAM), Swappiness=${SWAPPINESS}"
else
    log "📊 Parameter: ZRAM=disabled, Swappiness=${SWAPPINESS}"
fi

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

log "🎉 Optimasi selesai!"
log "💡 Tips:"
log "   - Jalankan 'free -h' untuk cek memori"
log "   - Jalankan 'swapon --show' untuk cek swap"
log "   - Jalankan 'zramctl' untuk cek status ZRAM"
log "   - Gunakan --no-zram atau --force-zram jika ZRAM bermasalah"
