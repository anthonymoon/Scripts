#!/bin/bash
# disk-optimize.sh - Script to optimize disk drive parameters for performance
# Author: Claude
#
# Usage: sudo ./disk-optimize.sh [device]
# Example: sudo ./disk-optimize.sh /dev/sda
#          sudo ./disk-optimize.sh /dev/nvme0n1
#          sudo ./disk-optimize.sh all
#
# Path for udev rule: /etc/udev/rules.d/60-disk-optimizations.rules

set -e

# Global configuration variables
# Default scheduler for different drive types
# Options typically include: none, mq-deadline, deadline, bfq, kyber
DEFAULT_SCHEDULER="none"          # Default for most SSDs
HDD_SCHEDULER="mq-deadline"       # Good for HDDs
NVME_SCHEDULER="none"             # Best for NVMe
LVM_SCHEDULER="none"              # Best for LVM volumes
RAID_SCHEDULER="none"             # Best for RAID arrays

# Read-ahead settings (in KB)
DEFAULT_READAHEAD=4096
LVM_READAHEAD=4096                # Default for LVM volumes
RAID_READAHEAD=8192               # Higher for RAID arrays
DB_READAHEAD=1024                 # Lower for databases
TORRENT_READAHEAD=8192            # Higher for torrents/streaming

# LVM volume-specific optimizations
# Format: "volume_name:read_ahead_value"
LVM_VOLUME_SETTINGS=(
  "qbt:8192"    # BitTorrent - high read-ahead
  "db:1024"     # Database - lower read-ahead
  "bak:4096"    # Backups - default
  "pods:4096"   # Containers - default
  "scratch:4096"  # Scratch space - default
)

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Function to detect drive type
get_drive_type() {
    local device="$1"
    local dev_name=${device##*/}
    
    # Check if it's an NVMe drive
    if [[ "$device" == *"nvme"* ]]; then
        echo "nvme"
        return
    fi
    
    # Check if it's a logical volume (LVM)
    if [[ "$device" == *"dm-"* ]] || [[ "$device" == *"mapper"* ]]; then
        echo "lvm"
        return
    fi
    
    # Check if it's a RAID device
    if [[ "$device" == *"md"* ]]; then
        echo "raid"
        return
    fi
    
    # Check if it's a SCSI device
    if [[ "$device" == *"sd"* ]]; then
        # Check if it's an SSD or HDD (rotational = 0 means SSD)
        if [ -e "/sys/block/$dev_name/queue/rotational" ]; then
            if [ "$(cat /sys/block/$dev_name/queue/rotational)" -eq 0 ]; then
                echo "ssd_sata"
                return
            else
                echo "sata"
                return
            fi
        fi
        
        # If we can't determine from rotational flag, check with hdparm
        if command -v hdparm &>/dev/null; then
            if hdparm -I "$device" 2>/dev/null | grep -q "Solid State Device"; then
                echo "ssd_sata"
                return
            else
                echo "sata"
                return
            fi
        fi
    fi
    
    # Check if it's a SCSI device
    if [[ "$device" == *"scsi"* ]]; then
        # Try to determine if it's an SSD
        if [ -e "/sys/block/$dev_name/queue/rotational" ]; then
            if [ "$(cat /sys/block/$dev_name/queue/rotational)" -eq 0 ]; then
                echo "ssd_scsi"
                return
            else
                echo "scsi"
                return
            fi
        fi
    fi
    
    # Default to unknown
    echo "unknown"
}

# Function to set the I/O scheduler
set_scheduler() {
    local dev_name="$1"
    local preferred_scheduler="$2"
    
    if [ ! -e "/sys/block/$dev_name/queue/scheduler" ]; then
        echo "Scheduler file not found for $dev_name, skipping scheduler setting"
        return
    fi
    
    # Get available schedulers
    local available_schedulers=$(cat "/sys/block/$dev_name/queue/scheduler" | tr -d "[]" | tr " " "\n")
    
    # Check if preferred scheduler is available
    if echo "$available_schedulers" | grep -q "^$preferred_scheduler$"; then
        echo "Setting scheduler to $preferred_scheduler"
        echo "$preferred_scheduler" > "/sys/block/$dev_name/queue/scheduler"
    else
        echo "Preferred scheduler $preferred_scheduler not available"
        echo "Available schedulers: $(cat /sys/block/$dev_name/queue/scheduler)"
        
        # Try fallback schedulers in order of preference
        for scheduler in none mq-deadline deadline kyber bfq cfq; do
            if echo "$available_schedulers" | grep -q "^$scheduler$"; then
                echo "Using fallback scheduler: $scheduler"
                echo "$scheduler" > "/sys/block/$dev_name/queue/scheduler"
                break
            fi
        done
    fi
}

# Function to optimize a single LVM volume
optimize_lvm() {
    local device="$1"
    echo "Optimizing LVM device: $device"
    
    local dev_name=${device##*/}
    
    # Apply settings to the DM device
    if [ -e "/sys/block/$dev_name/queue/scheduler" ]; then
        set_scheduler "$dev_name" "$LVM_SCHEDULER"
    fi
    
    # Enable nomerges for better performance
    if [ -e "/sys/block/$dev_name/queue/nomerges" ]; then
        echo "Enabling nomerges..."
        echo 1 > "/sys/block/$dev_name/queue/nomerges"
    fi
    
    # Optimize queue settings
    if [ -e "/sys/block/$dev_name/queue/nr_requests" ]; then
        echo "Setting request queue depth..."
        echo 1024 > "/sys/block/$dev_name/queue/nr_requests"
    fi
    
    # Set read-ahead
    echo "Setting read-ahead to ${LVM_READAHEAD}KB..."
    blockdev --setra $LVM_READAHEAD "$device"
    
    echo "LVM device $device optimized successfully."
}

# Function to optimize LVM volumes
optimize_lvm_volumes() {
    echo "Optimizing LVM volumes..."
    
    # Check if we have LVM
    if ! command -v lvs &>/dev/null; then
        echo "LVM not found, skipping LVM optimizations"
        return
    fi
    
    # Find all LVM volumes
    lvm_volumes=$(lvs --noheadings -o lv_path 2>/dev/null | tr -d ' ' || echo "")
    
    if [ -z "$lvm_volumes" ]; then
        echo "No LVM volumes found, skipping LVM optimizations"
        return
    fi
    
    echo "Found LVM volumes: $lvm_volumes"
    
    for lvm_vol in $lvm_volumes; do
        if [ -b "$lvm_vol" ]; then
            # Check if we have specific settings for this volume name
            vol_name=$(basename "$lvm_vol")
            custom_readahead=""
            
            for setting in "${LVM_VOLUME_SETTINGS[@]}"; do
                setting_name="${setting%%:*}"
                if [[ "$vol_name" == *"$setting_name"* ]]; then
                    custom_readahead="${setting#*:}"
                    break
                fi
            done
            
            if [ -n "$custom_readahead" ]; then
                echo "Using custom readahead for $vol_name: $custom_readahead"
                LVM_READAHEAD=$custom_readahead
            else
                # Reset to default
                LVM_READAHEAD=4096
            fi
            
            optimize_lvm "$lvm_vol"
        fi
    done
}

# Function to optimize a single RAID device
optimize_raid() {
    local device="$1"
    echo "Optimizing RAID device: $device"
    
    local dev_name=${device##*/}
    
    # Set stripe cache size if available
    if [ -e "/sys/block/$dev_name/md/stripe_cache_size" ]; then
        echo "Setting stripe cache size to 8192KB..."
        echo 8192 > "/sys/block/$dev_name/md/stripe_cache_size"
    fi
    
    # Set read-ahead for RAID
    echo "Setting read-ahead to ${RAID_READAHEAD}KB..."
    blockdev --setra $RAID_READAHEAD "$device"
    
    # Set I/O scheduler
    if [ -e "/sys/block/$dev_name/queue/scheduler" ]; then
        set_scheduler "$dev_name" "$RAID_SCHEDULER"
    fi
    
    # Maximize request queue depth
    if [ -e "/sys/block/$dev_name/queue/nr_requests" ]; then
        echo "Setting request queue depth..."
        echo 1024 > "/sys/block/$dev_name/queue/nr_requests"
    fi
    
    # Additional RAID optimizations based on RAID level
    if command -v mdadm &>/dev/null; then
        raid_level=$(mdadm --detail "$device" 2>/dev/null | grep "Raid Level" | awk '{print $4}' || echo "unknown")
        echo "Detected RAID level: $raid_level"
        
        case "$raid_level" in
            raid0|0)
                # For RAID0, maximize performance
                echo "Applying RAID0-specific optimizations..."
                # Disable add_random for RAID0
                if [ -e "/sys/block/$dev_name/queue/add_random" ]; then
                    echo 0 > "/sys/block/$dev_name/queue/add_random"
                fi
                ;;
        esac
    fi
    
    echo "RAID device $device optimized successfully."
}

# Function to optimize MD RAID devices
optimize_raid_devices() {
    echo "Optimizing MD RAID devices..."
    
    # Check if mdadm is installed
    if ! command -v mdadm &>/dev/null; then
        echo "mdadm not found, skipping RAID optimizations"
        return
    fi
    
    # Find all MD devices
    md_devices=$(ls -1 /dev/md* 2>/dev/null | grep -v 'p[0-9]' || echo "")
    
    if [ -z "$md_devices" ]; then
        echo "No MD RAID devices found, skipping RAID optimizations"
        return
    fi
    
    echo "Found RAID devices: $md_devices"
    
    for md_dev in $md_devices; do
        if [ -b "$md_dev" ]; then
            echo "Optimizing RAID device: $md_dev"
            md_name=$(basename "$md_dev")
            
            # Set stripe cache size if available
            if [ -e "/sys/block/$md_name/md/stripe_cache_size" ]; then
                echo "Setting stripe cache size to 8192KB..."
                echo 8192 > "/sys/block/$md_name/md/stripe_cache_size"
            fi
            
            # Set read-ahead for RAID
            echo "Setting read-ahead to ${RAID_READAHEAD}KB..."
            blockdev --setra $RAID_READAHEAD "$md_dev"
            
            # Set I/O scheduler
            if [ -e "/sys/block/$md_name/queue/scheduler" ]; then
                set_scheduler "$md_name" "$RAID_SCHEDULER"
            fi
            
            # Maximize request queue depth
            if [ -e "/sys/block/$md_name/queue/nr_requests" ]; then
                echo "Setting request queue depth..."
                echo 1024 > "/sys/block/$md_name/queue/nr_requests"
            fi
            
            # Additional RAID optimizations based on RAID level
            raid_level=$(mdadm --detail "$md_dev" 2>/dev/null | grep "Raid Level" | awk '{print $4}' || echo "unknown")
            echo "Detected RAID level: $raid_level"
            
            case "$raid_level" in
                raid0|0)
                    # For RAID0, maximize performance
                    echo "Applying RAID0-specific optimizations..."
                    # Disable add_random for RAID0
                    if [ -e "/sys/block/$md_name/queue/add_random" ]; then
                        echo 0 > "/sys/block/$md_name/queue/add_random"
                    fi
                    ;;
                raid1|1)
                    # For RAID1, balance read performance and write durability
                    echo "Applying RAID1-specific optimizations..."
                    ;;
                raid5|5)
                    # For RAID5, focus on write performance
                    echo "Applying RAID5-specific optimizations..."
                    if [ -e "/sys/block/$md_name/md/sync_speed_min" ]; then
                        echo "Setting minimum sync speed to 50000 KB/s..."
                        echo 50000 > "/sys/block/$md_name/md/sync_speed_min"
                    fi
                    ;;
                raid6|6|raid10|10)
                    # For RAID6/10, similar to RAID5 but with different performance characteristics
                    echo "Applying RAID6/10-specific optimizations..."
                    ;;
            esac
            
            echo "RAID device $md_dev optimized successfully."
        fi
    done
}

# Function to optimize NVMe drives
optimize_nvme() {
    local device="$1"
    echo "Optimizing NVMe drive: $device"
    
    # Apply NVMe specific optimizations
    # Set power saving to lowest (0 = max performance)
    echo "Setting power management to maximum performance..."
    nvme set-feature "$device" -f 2 -v 0
    
    # Disable APST (Autonomous Power State Transition) for max performance
    if nvme id-ctrl "$device" | grep -q "APST"; then
        echo "Disabling APST for maximum performance..."
        nvme set-feature "$device" -f 0x0C -v 0
    fi
    
    # Set IO queue depth and scheduler
    local nvme_name=${device##*/}
    
    # Set the scheduler
    set_scheduler "$nvme_name" "$NVME_SCHEDULER"
    
    # Set queue depth
    echo "Optimizing queue depth..."
    echo 1024 > "/sys/block/$nvme_name/queue/nr_requests"
    
    # Set read ahead
    echo "Setting read-ahead to ${DEFAULT_READAHEAD}KB..."
    echo $DEFAULT_READAHEAD > "/sys/block/$nvme_name/queue/read_ahead_kb"
    
    echo "NVMe drive $device optimized successfully."
}

# Function to optimize SATA drives
optimize_sata() {
    local device="$1"
    echo "Optimizing SATA drive: $device"
    
    local dev_name=${device##*/}
    
    # Enable DMA
    if [ -e "/sys/block/$dev_name/device/dma" ]; then
        echo "Enabling DMA..."
        echo "1" > "/sys/block/$dev_name/device/dma"
    fi
    
    # Enable write caching
    echo "Enabling write caching..."
    hdparm -W1 "$device"
    
    # Set APM to 254 (highest performance, lowest power saving)
    echo "Setting Advanced Power Management to maximum performance..."
    hdparm -B254 "$device"
    
    # Disable power management (standby) timer
    echo "Disabling standby timer..."
    hdparm -S0 "$device"
    
    # Set readahead
    echo "Setting read-ahead to ${DEFAULT_READAHEAD}KB..."
    blockdev --setra $DEFAULT_READAHEAD "$device"
    
    # Enable DMA for multi-sector operations
    echo "Enabling multi-sector I/O and DMA settings..."
    hdparm -m16 "$device" 2>/dev/null || true
    
    # Set max sectors for safer large transfers
    if [ -e "/sys/block/$dev_name/queue/max_sectors_kb" ]; then
        echo "Setting max sectors for transfer..."
        echo 1024 > "/sys/block/$dev_name/queue/max_sectors_kb"
    fi
    
    # Enable UDMA if available
    # Be cautious with this as it can be risky on some hardware
    # hdparm -X udma6 "$device" 2>/dev/null || true
    
    # Set scheduler
    set_scheduler "$dev_name" "$HDD_SCHEDULER"
    
    # Disable NCQ autosense if available (can cause overhead)
    if [ -e "/sys/block/$dev_name/device/queue_depth" ]; then
        echo "Setting queue depth..."
        cat "/sys/block/$dev_name/device/queue_depth" > "/sys/block/$dev_name/device/queue_depth"
    fi
    
    # Additional optimizations for newer kernels
    if [ -e "/sys/block/$dev_name/queue/nr_requests" ]; then
        echo "Setting maximum queue requests..."
        echo 1024 > "/sys/block/$dev_name/queue/nr_requests"
    fi
    
    # For rotational drives, set entropy contribution
    if [ -e "/sys/block/$dev_name/queue/add_random" ]; then
        echo "Disabling entropy contribution..."
        echo 0 > "/sys/block/$dev_name/queue/add_random"
    fi
    
    echo "SATA drive $device optimized successfully."
}

# Function to optimize SCSI drives
optimize_scsi() {
    local device="$1"
    echo "Optimizing SCSI drive: $device"
    
    local dev_name=${device##*/}
    
    # Use sdparm for SCSI-specific optimizations if available
    if command -v sdparm &>/dev/null; then
        echo "Using sdparm for SCSI optimizations..."
        
        # Enable write caching
        echo "Enabling write caching..."
        sdparm --set WCE=1 "$device"
        
        # Disable power management features
        echo "Disabling power management features..."
        
        # Disable Standby timer
        sdparm --set STANDBY=0 "$device" 2>/dev/null || true
        
        # Disable Start-Stop Cycle
        sdparm --clear STSOP "$device" 2>/dev/null || true
        
        # Set to highest performance mode
        sdparm --set DPOFUA=0 "$device" 2>/dev/null || true
    else
        # Fallback to more generic methods if sdparm not available
        echo "sdparm not available, using fallback methods..."
        
        # Enable write caching on SCSI if possible
        echo "Enabling write caching..."
        if [ -e "/sys/block/$dev_name/device/scsi_disk/*/cache_type" ]; then
            echo "write back" > "/sys/block/$dev_name/device/scsi_disk/*/cache_type"
        else
            # Try hdparm, might work on some SCSI devices
            hdparm -W1 "$device" 2>/dev/null || true
        fi
        
        # Disable power management
        echo "Disabling power management features..."
        if [ -e "/sys/block/$dev_name/device/scsi_disk/*/manage_start_stop" ]; then
            echo "0" > "/sys/block/$dev_name/device/scsi_disk/*/manage_start_stop"
        fi
    fi
    
    # Set readahead
    echo "Setting read-ahead to ${DEFAULT_READAHEAD}KB..."
    blockdev --setra $DEFAULT_READAHEAD "$device"
    
    # Set scheduler
    set_scheduler "$dev_name" "$HDD_SCHEDULER"
    
    echo "SCSI drive $device optimized successfully."
}

# Function to optimize SSD (non-NVMe)
optimize_ssd_sata() {
    local device="$1"
    echo "Optimizing SATA SSD drive: $device"
    
    local dev_name=${device##*/}
    
    # Enable write caching with hdparm
    echo "Enabling write caching..."
    hdparm -W1 "$device"
    
    # Disable power management
    echo "Disabling power management..."
    hdparm -B254 "$device" 2>/dev/null || true
    hdparm -S0 "$device"
    
    # Set readahead
    echo "Setting read-ahead to ${DEFAULT_READAHEAD}KB..."
    blockdev --setra $DEFAULT_READAHEAD "$device"
    
    # Set I/O scheduler
    set_scheduler "$dev_name" "$DEFAULT_SCHEDULER"
    
    # Additional SSD optimizations
    # Maximum request queue
    echo "Setting queue optimizations..."
    echo 4096 > "/sys/block/$dev_name/queue/nr_requests" 2>/dev/null || true
    
    # Reduce I/O latency
    echo 0 > "/sys/block/$dev_name/queue/add_random" 2>/dev/null || true
    
    echo "SATA SSD drive $device optimized successfully."
}

# Function to optimize SCSI SSD
optimize_ssd_scsi() {
    local device="$1"
    echo "Optimizing SCSI SSD drive: $device"
    
    local dev_name=${device##*/}
    
    # Use sdparm for SCSI-specific optimizations if available
    if command -v sdparm &>/dev/null; then
        echo "Using sdparm for SCSI SSD optimizations..."
        
        # Enable write caching
        echo "Enabling write caching..."
        sdparm --set WCE=1 "$device"
        
        # Disable power management
        echo "Disabling power management..."
        sdparm --clear STANDBY "$device" 2>/dev/null || true
    else
        # Fallback to hdparm
        echo "sdparm not available, using fallback methods..."
        hdparm -W1 "$device" 2>/dev/null || true
        hdparm -S0 "$device" 2>/dev/null || true
    fi
    
    # For all SSDs regardless of type
    # Set readahead
    echo "Setting read-ahead to ${DEFAULT_READAHEAD}KB..."
    blockdev --setra $DEFAULT_READAHEAD "$device"
    
    # Set I/O scheduler
    set_scheduler "$dev_name" "$DEFAULT_SCHEDULER"
    
    # Additional SSD optimizations
    # Maximum request queue
    echo "Setting queue optimizations..."
    echo 4096 > "/sys/block/$dev_name/queue/nr_requests" 2>/dev/null || true
    
    # Reduce I/O latency
    echo 0 > "/sys/block/$dev_name/queue/add_random" 2>/dev/null || true
    
    echo "SCSI SSD drive $device optimized successfully."
}

# Main logic
if [ "$1" = "all" ]; then
    echo "Optimizing all disk drives..."
    
    # Optimize all physical drives
    for device in /dev/sd? /dev/sd?? /dev/nvme?n? /dev/xvd?; do
        if [ -b "$device" ]; then
            drive_type=$(get_drive_type "$device")
            case "$drive_type" in
                nvme)
                    optimize_nvme "$device"
                    ;;
                sata)
                    optimize_sata "$device"
                    ;;
                scsi)
                    optimize_scsi "$device"
                    ;;
                ssd_sata)
                    optimize_ssd_sata "$device"
                    ;;
                ssd_scsi)
                    optimize_ssd_scsi "$device"
                    ;;
                *)
                    echo "Unknown drive type for $device, skipping..."
                    ;;
            esac
        fi
    done
    
    # Optimize all LVM volumes
    optimize_lvm_volumes
    
    # Optimize all RAID devices
    optimize_raid_devices
    
else
    if [ -z "$1" ]; then
        echo "Usage: $0 [device|all]"
        echo "Example: $0 /dev/sda"
        echo "         $0 /dev/nvme0n1"
        echo "         $0 /dev/md0"
        echo "         $0 /dev/mapper/vg-lv"
        echo "         $0 all"
        exit 1
    fi
    
    if [ ! -b "$1" ]; then
        echo "Error: $1 is not a valid block device"
        exit 1
    fi
    
    drive_type=$(get_drive_type "$1")
    case "$drive_type" in
        nvme)
            optimize_nvme "$1"
            ;;
        sata)
            optimize_sata "$1"
            ;;
        scsi)
            optimize_scsi "$1"
            ;;
        ssd_sata)
            optimize_ssd_sata "$1"
            ;;
        ssd_scsi)
            optimize_ssd_scsi "$1"
            ;;
        lvm)
            optimize_lvm "$1"
            ;;
        raid)
            optimize_raid "$1"
            ;;
        *)
            echo "Unknown drive type for $1"
            echo "Trying to detect based on device name..."
            if [[ "$1" == *"nvme"* ]]; then
                optimize_nvme "$1"
            elif [[ "$1" == *"sd"* ]]; then
                # Try to determine if it's an SSD
                local dev_name=${1##*/}
                if [ -e "/sys/block/$dev_name/queue/rotational" ] && [ "$(cat /sys/block/$dev_name/queue/rotational)" -eq 0 ]; then
                    optimize_ssd_sata "$1"
                else
                    optimize_sata "$1"
                fi
            elif [[ "$1" == *"dm-"* ]] || [[ "$1" == *"mapper"* ]]; then
                optimize_lvm "$1"
            elif [[ "$1" == *"md"* ]]; then
                optimize_raid "$1"
            else
                echo "Cannot determine drive type. Please specify manually."
                exit 1
            fi
            ;;
    esac
fi

exit 0