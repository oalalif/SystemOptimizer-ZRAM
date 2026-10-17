#!/bin/bash
# ==============================================================================
# System Optimizer Script - Versi Modern & Sinkronisasi Arsitektur Ubuntu
# Optimasi RAM (ZRAM zstd/Generator), CPU Scheduler, Disk I/O, dan Cleanup Sistem
# Version: 3.2.1 - systemd-zram-generator integration, zstd 4x compression,
#                  conflict resolution (zswap/zram-config/zramswap),
#                  safe swap priority detection, anti-thrash kernel tuning
# ==============================================================================
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
    for cmd in bc swapon swapoff; do
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
🚀 System Optimizer Script (Modern ZRAM & Kernel Tuning)

USAGE:
    sudo ./optimize-id.sh [MODE] [OPTIONS]

MODES:
    (none)          - Optimasi lengkap (RAM + CPU + Cleanup)
    ram             - Hanya optimasi RAM dan ZRAM
    cpu             - Hanya optimasi CPU dan I/O Scheduler
    cleanup         - Hanya cleanup sistem (APT, log, temp)
    
OPTIONS:
    --zram PERCENT     - Ukuran ZRAM terhadap RAM (0.1-1.5, default: 1.0 = 100% RAM)
    --swappiness N     - Nilai swappiness kernel (0-200, default: 180 untuk ZRAM)
    --algorithm ALGO   - Algoritma kompresi (zstd, lz4, lzo-rle, default: zstd)
    --no-zram          - Lewati konfigurasi ZRAM
    --force-zram       - Paksa reset dan inisialisasi ulang ZRAM
    --help, -h         - Tampilkan bantuan ini

EXAMPLES:
    sudo ./optimize-id.sh                   # Optimasi penuh standar modern
    sudo ./optimize-id.sh ram               # RAM & ZRAM (100% RAM, zstd, swappiness 180)
    sudo ./optimize-id.sh ram --zram 0.5    # ZRAM 50% RAM
    sudo ./optimize-id.sh ram --no-zram     # RAM tanpa ZRAM (swappiness konservatif 60)
    sudo ./optimize-id.sh cleanup           # Hanya pembersihan cache & temporary
EOF
}

# Parsing argumen
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
            log "${RED}❌ Opsi tidak dikenal: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Validasi parameter ZRAM
validate_zram() {
    local value="$1"
    if ! [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log "${RED}❌ Persentase ZRAM harus berupa angka desimal atau bulat (misalnya: 0.5, 1.0, 1.25)${NC}"
        return 1
    fi
    if (( $(echo "$value < 0.1 || $value > 1.5" | bc -l) )); then
        log "${RED}❌ Persentase ZRAM harus berada di antara 0.1 s/d 1.5${NC}"
        return 1
    fi
    return 0
}

# Validasi swappiness (modern Linux kernel mendukung hingga 200 untuk zram/swap)
validate_swappiness() {
    local value="$1"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 200 ]]; then
        log "${RED}❌ Swappiness harus berupa angka bulat di antara 0 s/d 200${NC}"
        return 1
    fi
    return 0
}

# Periksa dukungan ZRAM di kernel
check_zram_support() {
    log "🔍 Mengecek dukungan ZRAM di kernel..."
    if [[ -f /proc/config.gz ]] && zcat /proc/config.gz | grep -q "CONFIG_ZRAM="; then
        log "${GREEN}✅ ZRAM didukung (built-in kernel)${NC}"
        return 0
    elif [[ -f /boot/config-"$(uname -r)" ]] && grep -q "CONFIG_ZRAM" /boot/config-"$(uname -r)"; then
        log "${GREEN}✅ ZRAM didukung (konfigurasi kernel)${NC}"
        return 0
    elif modinfo zram >/dev/null 2>&1; then
        log "${GREEN}✅ ZRAM modul kernel tersedia${NC}"
        return 0
    elif [[ -d /sys/module/zram ]]; then
        log "${GREEN}✅ Modul ZRAM aktif${NC}"
        return 0
    else
        log "${RED}❌ ZRAM tidak didukung oleh kernel saat ini${NC}"
        return 1
    fi
}

# Periksa memori tersedia (hanya perlindungan OOM ekstrem)
check_available_memory() {
    local zram_size=$1
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local free_mem_kb
    free_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [[ $free_mem_kb -lt 65536 ]]; then
        log "${YELLOW}⚠️ Memori tersedia ($((free_mem_kb/1024))MB) sangat kritis. Tidak aman menginisialisasi ZRAM.${NC}"
        return 1
    fi
    log "${GREEN}✅ Memori mencukupi untuk inisialisasi ZRAM (tersedia: $((free_mem_kb/1024))MB, target pool virtual: $((zram_size/1024/1024))MB)${NC}"
    return 0
}

# Deteksi ketersediaan systemd-zram-generator
is_systemd_zram_generator_present() {
    if [[ -x /usr/lib/systemd/system-generators/zram-generator || -x /lib/systemd/system-generators/zram-generator ]] || \
       systemctl list-unit-files 2>/dev/null | grep -q "systemd-zram-setup"; then
        return 0
    fi
    return 1
}

# Resolusi konflik ZRAM: nonaktifkan paket/layanan lawas & zswap yang saling bertabrakan
resolve_zram_conflicts() {
    log "🛡 Memeriksa dan menyelesaikan konflik layanan ZRAM & zswap..."

    # 1. Nonaktifkan kernel zswap jika aktif (mencegah double-compression thrashing dengan ZRAM)
    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        local zswap_state
        zswap_state=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
        if [[ "$zswap_state" == "Y" || "$zswap_state" == "1" ]]; then
            echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
            log "  -> ${YELLOW}Kernel zswap dinonaktifkan (eliminasi double-compression dengan ZRAM).${NC}"
        fi
    fi

    # 2. Hentikan dan masking layanan zram lama yang sering bertabrakan
    local conflicting_services=("zram-config.service" "zramswap.service" "zram-unit.service")
    for svc in "${conflicting_services[@]}"; do
        if systemctl is-active "$svc" >/dev/null 2>&1 || systemctl is-enabled "$svc" >/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
            log "  -> ${YELLOW}Layanan konflik '$svc' telah dihentikan dan dimasking.${NC}"
        fi
    done

    # 3. Bersihkan entri statis di /etc/fstab yang memicu timeout booting 90 detik
    local FSTAB="/etc/fstab"
    if grep -q "^/dev/zram0" "$FSTAB" 2>/dev/null; then
        sed -i 's|^/dev/zram0|# /dev/zram0 (dikelola otomatis oleh systemd-zram-generator)|g' "$FSTAB"
        log "  -> ${GREEN}Entri statis /dev/zram0 dinonaktifkan dari fstab (mencegah delay booting 90s).${NC}"
    fi
}

# Pembersihan ZRAM aman standalone tanpa memicu crash kernel / freeze
cleanup_zram_standalone() {
    log "===== Membersihkan ZRAM (Standalone Mode) ====="
    
    # Matikan swap zram yang aktif
    if swapon --show=NAME --noheadings >/dev/null 2>&1; then
        while read -r swap_dev; do
            if [[ "$swap_dev" =~ /dev/zram[0-9]* ]]; then
                if [[ -b "$swap_dev" ]]; then
                    if swapoff "$swap_dev" 2>/dev/null; then
                        log "✅ Matikan swap: $(basename "$swap_dev")"
                    else
                        log "⚠ Gagal swapoff: $(basename "$swap_dev")"
                    fi
                fi
            fi
        done < <(swapon --show=NAME --noheadings)
    fi

    # Reset perangkat via zramctl jika tersedia
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

# Setup ZRAM modern
setup_zram() {
    local zram_size=$1
    local zram_size_mb=$((zram_size / 1024 / 1024))
    
    log "===== Menyiapkan ZRAM ====="
    
    if ! check_zram_support; then
        return 1
    fi
    
    if ! check_available_memory "$zram_size"; then
        log "${RED}❌ Gagal menyiapkan ZRAM karena memori fisik kritis${NC}"
        return 1
    fi

    # Selesaikan konflik sebelum inisialisasi
    resolve_zram_conflicts

    # Jika --force-zram diaktifkan, lakukan pembersihan total perangkat & unit
    if [[ "$FORCE_ZRAM" == "true" ]]; then
        log "🔄 Menjalankan Force Reset ZRAM..."
        systemctl stop dev-zram0.swap 2>/dev/null || true
        systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
        cleanup_zram_standalone
    fi

    # 1. METODE UTAMA: systemd-zram-generator (Standar Modern Ubuntu / Fedora / Debian)
    if is_systemd_zram_generator_present; then
        log "⚙ Menggunakan arsitektur modern: systemd-zram-generator"
        
        # Susun konfigurasi generator
        local gen_conf="/etc/systemd/zram-generator.conf"
        mkdir -p /etc/systemd
        cat << EOF > "$gen_conf"
[zram0]
zram-size = ${zram_size_mb}
compression-algorithm = ${PREFERRED_ALGO}
swap-priority = 100
EOF
        log "  -> Menulis konfigurasi: $gen_conf (${zram_size_mb}MB, ${PREFERRED_ALGO}, priority 100)"
        
        systemctl daemon-reload
        if systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || systemctl restart dev-zram0.swap 2>/dev/null || systemctl start /dev/zram0 2>/dev/null; then
            log "${GREEN}✅ Layanan systemd-zram-setup@zram0 berhasil diaktifkan${NC}"
            sleep 1
            if swapon --show=NAME --noheadings | grep -q "/dev/zram0"; then
                log "${GREEN}✅ /dev/zram0 aktif sebagai swap utama${NC}"
                if command -v zramctl >/dev/null 2>&1; then
                    zramctl /dev/zram0 2>/dev/null | while read -r line; do log "   $line"; done
                fi
                return 0
            fi
        fi
        log "${YELLOW}⚠️ systemd-zram-generator restart gagal, mencoba fallback manual...${NC}"
    fi

    # 2. METODE FALLBACK: Standalone zramctl / modprobe
    log "⚙ Menggunakan arsitektur fallback: zramctl standalone"
    if ! lsmod | grep -q "^zram"; then
        modprobe zram num_devices=1 >/dev/null 2>&1 || modprobe zram >/dev/null 2>&1 || true
    fi

    if ! command -v zramctl >/dev/null 2>&1; then
        log "${RED}❌ Perintah zramctl tidak ditemukan untuk mode fallback${NC}"
        return 1
    fi

    # Tentukan algoritma kompresi yang didukung kernel
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
            log "${BLUE}ℹ Algoritma ${PREFERRED_ALGO} tidak didukung, menggunakan fallback: ${chosen_algo}${NC}"
        fi
    fi

    local zram_dev
    zram_dev=$(zramctl --find --size "${zram_size_mb}M" --algorithm "${chosen_algo}" 2>/dev/null || true)
    if [[ -z "$zram_dev" || ! -b "$zram_dev" ]]; then
        # Coba reset zram0 jika find gagal
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
        log "${GREEN}✅ ZRAM aktif: ${zram_size_mb}MB (${chosen_algo}) pada $zram_dev (Prioritas 100)${NC}"
        zramctl "$zram_dev" 2>/dev/null | while read -r line; do log "   $line"; done
        return 0
    fi

    log "${RED}❌ Gagal menginisialisasi ZRAM melalui mode standalone${NC}"
    return 1
}

# Kelola prioritas swap aman (DILARANG scan liar blok disk yang bisa memicu I/O thrashing)
manage_swap_priorities() {
    log "===== Mengatur Prioritas Swap Non-ZRAM (Aman) ====="
    local swap_devices=()

    # 1. Daftarkan swap yang aktif di /proc/swaps
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

    # 2. Daftarkan swap sah yang aktif di /etc/fstab (mountpoint bisa 'none' atau 'swap')
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

    # Atur prioritas swap cadangan agar berada di bawah ZRAM (ZRAM = 100)
    for s_dev in "${swap_devices[@]}"; do
        if [[ -b "$s_dev" || -f "$s_dev" ]]; then
            local target_prio=10
            if [[ "$s_dev" =~ /dev/sd[a-z][0-9] || "$s_dev" =~ /dev/nvme ]]; then
                target_prio=5
            fi

            # Cek apakah sudah aktif
            if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^$s_dev"; then
                # Cek prioritas saat ini
                local cur_prio
                cur_prio=$(swapon --show=NAME,PRIO --noheadings 2>/dev/null | awk -v d="$s_dev" '$1 == d {print $2}')
                # Hanya sesuaikan jika prioritasnya bersaing dengan atau melebihi ZRAM (>=100)
                if [[ -n "$cur_prio" && "$cur_prio" -ge 100 ]]; then
                    log "  -> Menurunkan prioritas $s_dev ($cur_prio -> $target_prio)..."
                    swapoff "$s_dev" 2>/dev/null || true
                    swapon -p "$target_prio" "$s_dev" 2>/dev/null || true
                else
                    log "📍 Swap cadangan $s_dev sudah aktif dengan prioritas aman ($cur_prio < 100)"
                fi
            else
                # Belum aktif, aktifkan langsung dengan prioritas rendah
                if swapon -p "$target_prio" "$s_dev" 2>/dev/null; then
                    log "${GREEN}✅ Mengaktifkan swap cadangan: $s_dev (Prioritas: $target_prio)${NC}"
                fi
            fi
        fi
    done
}

# Optimasi RAM & Kernel VM
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
    
    log "🖌 RAM Fisik Total: ${total_ram_gb}GB"

    if [[ "$SKIP_ZRAM" == "true" ]]; then
        if [[ "$SWAPPINESS_CUSTOM" == "false" ]]; then
            swappiness=60
            log "${BLUE}ℹ ZRAM dilewati (--no-zram); swappiness disetel ke default konservatif (60) untuk mencegah thrashing disk swap.${NC}"
        fi
    fi
    
    log "🔧 Menetapkan Swappiness: $swappiness"
    sysctl vm.swappiness="$swappiness" >/dev/null
    
    if [[ "$SKIP_ZRAM" == "true" ]]; then
        log "⏩ Konfigurasi ZRAM dilewati (--no-zram)"
    else
        local zram_size
        zram_size=$(echo "$total_ram_kb * 1024 * $zram_percent" | bc -l | cut -d. -f1)
        local zram_size_mb=$(( zram_size / 1024 / 1024 ))
        local zram_percent_int
        zram_percent_int=$(echo "$zram_percent * 100" | bc -l | cut -d. -f1)
        log "📏 Target Kapasitas Pool ZRAM: ${zram_size_mb}MB (${zram_percent_int}% dari RAM fisik)"
        
        if setup_zram "$zram_size"; then
            log "${GREEN}✅ Pool kompresi ZRAM beroperasi sempurna${NC}"
        else
            log "${YELLOW}⚠ Setup ZRAM gagal, melanjutkan optimasi subsistem memori lainnya${NC}"
        fi
    fi
    
    manage_swap_priorities
    
    # Kernel VM Tuning (High-Throughput, Zero-Thrash & Anti-Freeze)
    log "🚀 Menerapkan parameter kernel VM anti-freeze..."
    {
        # Menjaga cache direktori & dentry tetap di RAM
        echo 50 > /proc/sys/vm/vfs_cache_pressure
        # 0 = Baca 1 halaman (4KB) tanpa cluster read-ahead (ZRAM tidak butuh disk seek)
        echo 0 > /proc/sys/vm/page-cluster 2>/dev/null || true
        # Dirty page flushing halus mencegah lockup saat file write besar
        echo 10 > /proc/sys/vm/dirty_ratio
        echo 5 > /proc/sys/vm/dirty_background_ratio
        # Cegah kernel mendadak panik membuang cache
        echo 0 > /proc/sys/vm/watermark_boost_factor 2>/dev/null || true
        echo 125 > /proc/sys/vm/watermark_scale_factor 2>/dev/null || true
        # Kompaksi memori aktif
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    } 2>/dev/null || true
    
    # Simpan konfigurasi sysctl permanen jika direktori tersedia
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
        log "${GREEN}💾 Konfigurasi permanen tersimpan di /etc/sysctl.d/99-zram-performance.conf${NC}"
    fi

    log "${GREEN}✅ Optimasi RAM & VM selesai${NC}"
}

# Optimasi CPU & I/O Scheduler
optimize_cpu() {
    log "===== Tuning CPU & Disk I/O ====="
    
    log "⚡ Mengoptimalkan CPU Frequency Governor..."
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        local available_governors
        available_governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
        
        if echo "$available_governors" | grep -q "schedutil"; then
            echo "schedutil" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor disetel ke: schedutil (Responsif & Efisien Energi)"
        elif echo "$available_governors" | grep -q "ondemand"; then
            echo "ondemand" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor disetel ke: ondemand"
        elif echo "$available_governors" | grep -q "performance"; then
            echo "performance" > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
            log "🎯 CPU Governor disetel ke: performance"
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
    
    log "${GREEN}✅ Optimasi CPU & Disk I/O selesai${NC}"
}

# Pembersihan cache & file sisa
cleanup_system() {
    log "===== Cleanup Sistem Aman ====="
    
    sync
    log "🧹 Sinkronisasi & pembersihan buffer file..."
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    log "🗑 Membersihkan paket & arsip package manager..."
    if command -v apt-get >/dev/null 2>&1; then
        if apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean >/dev/null 2>&1 && apt-get clean >/dev/null 2>&1; then
            log "${GREEN}✅ APT cleanup selesai${NC}"
        fi
    fi
    
    if command -v dnf >/dev/null 2>&1; then
        if dnf autoremove -y >/dev/null 2>&1 && dnf clean all >/dev/null 2>&1; then
            log "${GREEN}✅ DNF cleanup selesai${NC}"
        fi
    fi
    
    if command -v pacman >/dev/null 2>&1; then
        if pacman -Sc --noconfirm >/dev/null 2>&1; then
            log "${GREEN}✅ Pacman cleanup selesai${NC}"
        fi
    fi
    
    log "📂 Membersihkan file sementara & vacuum systemd journal..."
    {
        find /tmp -type f -atime +7 -delete 2>/dev/null || true
        find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true
        journalctl --vacuum-size=50M >/dev/null 2>&1 || true
    } || true
    log "${GREEN}✅ Cleanup selesai${NC}"
}

# Tampilkan status ringkasan
show_status() {
    log "===== Status Sistem Pasca-Optimasi ====="
    
    local mem_info
    mem_info=$(free -h | grep "^Mem:")
    local mem_used
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_total
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    log "💾 Memori Fisik: $mem_used / $mem_total"
    
    if swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings >/dev/null 2>&1; then
        log "🔍 Swap Aktif:"
        while read -r name type size used prio; do
            log "   $(basename "$name") ($type): ${used} / ${size} (Prioritas: $prio)"
        done < <(swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings)
    else
        log "🔍 Tidak ada swap aktif"
    fi
    
    if command -v zramctl >/dev/null 2>&1 && [[ -n "$(zramctl --noheadings 2>/dev/null)" ]]; then
        log "📊 Status Kompresi ZRAM:"
        zramctl 2>/dev/null | while read -r line; do log "   $line"; done
    fi
    
    local load_avg
    load_avg=$(cut -d' ' -f1-3 /proc/loadavg)
    log "📈 Load Average: $load_avg"
}

# Eksekusi Utama
check_dependencies
log "🚀 Memulai System Optimizer [Mode: $MODE]"

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
log "${GREEN}🎉 Seluruh proses optimasi berhasil dieksekusi!${NC}"
