#!/bin/bash
# Enhanced Storage Configuration Collector
# This script captures storage, I/O, filesystem, CPU, and chipset settings to provide context for fsync performance analysis

OUTPUT_FILE="storage_config_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"

echo "=============================================" | tee "$OUTPUT_FILE"
echo "Enhanced Storage Configuration Collector" | tee -a "$OUTPUT_FILE"
echo "Date: $(date)" | tee -a "$OUTPUT_FILE"
echo "Hostname: $(hostname)" | tee -a "$OUTPUT_FILE"
echo "Kernel: $(uname -r)" | tee -a "$OUTPUT_FILE"
echo "=============================================" | tee -a "$OUTPUT_FILE"

# Function to add section headers
section() {
    echo -e "\n\n=== $1 ===" | tee -a "$OUTPUT_FILE"
}

# System hardware information
section "System Hardware Information"
echo "CPU Model:" | tee -a "$OUTPUT_FILE"
cat /proc/cpuinfo | grep -m 1 "model name" | sed 's/model name\s*: //' | tee -a "$OUTPUT_FILE"

echo -e "\nCPU Details:" | tee -a "$OUTPUT_FILE"
lscpu | tee -a "$OUTPUT_FILE"

echo -e "\nChipset Model:" | tee -a "$OUTPUT_FILE"
if command -v dmidecode &> /dev/null; then
    dmidecode -t baseboard | grep -E 'Manufacturer|Product Name|Version' | tee -a "$OUTPUT_FILE"
else
    echo "dmidecode not installed" | tee -a "$OUTPUT_FILE"
fi

# Kernel command line parameters
section "Kernel Command Line"
cat /proc/cmdline | tee -a "$OUTPUT_FILE"

# CPU Governors
section "CPU Governor Configuration"
echo "Current CPU Governors:" | tee -a "$OUTPUT_FILE"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    if [[ -f "$cpu/cpufreq/scaling_governor" ]]; then
        echo "$(basename $cpu): $(cat $cpu/cpufreq/scaling_governor)" | tee -a "$OUTPUT_FILE"
    fi
done

echo -e "\nAvailable CPU Governors:" | tee -a "$OUTPUT_FILE"
if [[ -f "/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors" ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors | tee -a "$OUTPUT_FILE"
else
    echo "Information not available" | tee -a "$OUTPUT_FILE"
fi

# Kernel and VM settings
section "Kernel VM Settings"
echo "Dirty Page Parameters:" | tee -a "$OUTPUT_FILE"
cat /proc/sys/vm/dirty_ratio /proc/sys/vm/dirty_background_ratio \
    /proc/sys/vm/dirty_expire_centisecs /proc/sys/vm/dirty_writeback_centisecs \
    | paste <(printf "vm.dirty_ratio:\nvm.dirty_background_ratio:\nvm.dirty_expire_centisecs:\nvm.dirty_writeback_centisecs:\n") - \
    | tee -a "$OUTPUT_FILE"

# File system info
section "Filesystem Configuration"
echo "Mount Points:" | tee -a "$OUTPUT_FILE"
mount | grep -E '(ext4|xfs|btrfs|zfs)' | tee -a "$OUTPUT_FILE"

echo -e "\nFilesystem Details:" | tee -a "$OUTPUT_FILE"
df -hT | tee -a "$OUTPUT_FILE"

# Block device information
section "Block Device Information"
echo "Available Block Devices:" | tee -a "$OUTPUT_FILE"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL | tee -a "$OUTPUT_FILE"

echo -e "\nSSD Models and Details:" | tee -a "$OUTPUT_FILE"

# For SATA SSDs using smartctl
if command -v smartctl &> /dev/null; then
    for drive in /dev/sd?; do
        if [[ -b "$drive" ]]; then
            echo -e "\nDisk Device: $drive" | tee -a "$OUTPUT_FILE"
            smartctl -i $drive | grep -E 'Model|Serial|Firmware|User Capacity|Rotation Rate|SMART support' | tee -a "$OUTPUT_FILE"
            # Check if it's an SSD (Rotation Rate: Solid State Device)
            if smartctl -i $drive | grep -q "Solid State Device"; then
                echo "  Device Type: SSD" | tee -a "$OUTPUT_FILE"
                smartctl -A $drive | grep -E 'Media_Wearout_Indicator|Wear_Leveling_Count|Reallocated_Sector_Ct|SSD_Life_Left' | tee -a "$OUTPUT_FILE"
            fi
        fi
    done
else
    echo "smartctl not installed" | tee -a "$OUTPUT_FILE"
fi

echo -e "\nBlock Device Parameters:" | tee -a "$OUTPUT_FILE"
for dev in $(lsblk -ndo NAME); do
    if [[ -d /sys/block/$dev ]]; then
        echo -e "\nDevice: $dev" | tee -a "$OUTPUT_FILE"
        
        if [[ -f /sys/block/$dev/queue/scheduler ]]; then
            echo "  Scheduler: $(cat /sys/block/$dev/queue/scheduler 2>/dev/null || echo 'N/A')" | tee -a "$OUTPUT_FILE"
        fi
        
        if [[ -f /sys/block/$dev/queue/nr_requests ]]; then
            echo "  Queue Depth: $(cat /sys/block/$dev/queue/nr_requests 2>/dev/null || echo 'N/A')" | tee -a "$OUTPUT_FILE"
        fi
        
        if [[ -f /sys/block/$dev/queue/read_ahead_kb ]]; then
            echo "  Read Ahead: $(cat /sys/block/$dev/queue/read_ahead_kb 2>/dev/null || echo 'N/A') KB" | tee -a "$OUTPUT_FILE"
        fi
        
        if [[ -f /sys/block/$dev/queue/rotational ]]; then
            rotational=$(cat /sys/block/$dev/queue/rotational 2>/dev/null || echo 'N/A')
            if [[ "$rotational" == "0" ]]; then
                echo "  Device Type: SSD/Flash" | tee -a "$OUTPUT_FILE"
            elif [[ "$rotational" == "1" ]]; then
                echo "  Device Type: Rotational HDD" | tee -a "$OUTPUT_FILE"
            else
                echo "  Device Type: Unknown" | tee -a "$OUTPUT_FILE"
            fi
        fi
        
        if [[ -f /sys/block/$dev/queue/nomerges ]]; then
            echo "  I/O Merging: $(cat /sys/block/$dev/queue/nomerges 2>/dev/null || echo 'N/A')" | tee -a "$OUTPUT_FILE"
        fi
    fi
done

# RAID information
section "RAID Configuration"
if [[ -f /proc/mdstat ]]; then
    echo "MD RAID Status:" | tee -a "$OUTPUT_FILE"
    cat /proc/mdstat | tee -a "$OUTPUT_FILE"
    
    echo -e "\nRAID Device Details:" | tee -a "$OUTPUT_FILE"
    for md in $(ls -d /dev/md* 2>/dev/null | grep -v "p"); do
        if [[ -b $md ]]; then
            echo -e "\nRAID Device: $md" | tee -a "$OUTPUT_FILE"
            mdadm --detail $md 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  No details available" | tee -a "$OUTPUT_FILE"
            
            # Check for stripe_cache_size
            md_name=$(basename $md)
            if [[ -f /sys/block/$md_name/md/stripe_cache_size ]]; then
                echo "  Stripe Cache Size: $(cat /sys/block/$md_name/md/stripe_cache_size 2>/dev/null || echo 'N/A')" | tee -a "$OUTPUT_FILE"
            fi
        fi
    done
fi

# Device Mapper configuration
section "Device Mapper Configuration"
echo "DM Devices:" | tee -a "$OUTPUT_FILE"
dmsetup ls | tee -a "$OUTPUT_FILE"

echo -e "\nDM Device Tables:" | tee -a "$OUTPUT_FILE"
for dm in $(dmsetup ls --noheadings | awk '{print $1}'); do
    echo -e "\nDevice: $dm" | tee -a "$OUTPUT_FILE"
    dmsetup table $dm | tee -a "$OUTPUT_FILE"
    dmsetup status $dm | tee -a "$OUTPUT_FILE"
    
    # Check if it's a cache device
    if dmsetup table $dm | grep -q "cache"; then
        echo "  Cache Settings:" | tee -a "$OUTPUT_FILE"
        dmsetup status $dm | tee -a "$OUTPUT_FILE"
    fi
done

# LVM configuration if present
section "LVM Configuration"
if command -v vgs &> /dev/null; then
    echo "Volume Groups:" | tee -a "$OUTPUT_FILE"
    vgs 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "No volume groups found" | tee -a "$OUTPUT_FILE"
    
    echo -e "\nLogical Volumes:" | tee -a "$OUTPUT_FILE"
    lvs -o lv_name,vg_name,lv_size,lv_attr 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "No logical volumes found" | tee -a "$OUTPUT_FILE"
fi

# Process I/O priorities
section "Process I/O Priorities"
echo "I/O Priorities for Key Processes:" | tee -a "$OUTPUT_FILE"
for proc in jbd2 kswapd flush; do
    echo -e "\nProcess: $proc" | tee -a "$OUTPUT_FILE"
    pids=$(pgrep -f $proc)
    if [[ -n "$pids" ]]; then
        for pid in $pids; do
            echo "PID: $pid" | tee -a "$OUTPUT_FILE"
            ionice -p $pid 2>&1 | tee -a "$OUTPUT_FILE"
            ps -p $pid -o pid,ppid,user,stat,pcpu,pmem,comm,wchan | tee -a "$OUTPUT_FILE"
        done
    else
        echo "No processes found" | tee -a "$OUTPUT_FILE"
    fi
done

# System I/O Statistics
section "Current I/O Statistics"
echo "iostat Output:" | tee -a "$OUTPUT_FILE"
iostat -x 1 2 | tail -n +$(iostat -x | wc -l) | tee -a "$OUTPUT_FILE" || echo "iostat not available" | tee -a "$OUTPUT_FILE"

# Collect FIO version
section "FIO Information"
fio --version | tee -a "$OUTPUT_FILE" || echo "FIO not found" | tee -a "$OUTPUT_FILE"

# Collect complete Sysctl Settings
section "Complete Sysctl Settings"
sysctl -a 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "Error collecting complete sysctl output" | tee -a "$OUTPUT_FILE"

# Kernel build information
section "Kernel Build Information"
echo "Kernel Version:" | tee -a "$OUTPUT_FILE"
uname -a | tee -a "$OUTPUT_FILE"

echo -e "\nKernel Build Information:" | tee -a "$OUTPUT_FILE"
if [[ -f /proc/version ]]; then
    cat /proc/version | tee -a "$OUTPUT_FILE"
else
    echo "Information not available" | tee -a "$OUTPUT_FILE"
fi

echo -e "\n\nConfiguration collected and saved to $OUTPUT_FILE"
echo "Please share this file to provide context for fsync performance tuning."