#!/bin/bash
# fs_stress_test.sh - Advanced Filesystem Stress Tester
# This script runs various high-stress filesystem tests for LVM RAID0 over SSDs with 3-run statistical analysis
# It also reports drive configuration details like write cache, NCQ, IO scheduler, and readahead
# Results are stored in SQLite database for comparison between runs

set -e

# Immediately elevate process priority to minimize system interference
if [ "$(id -u)" -eq 0 ]; then
    # Root can do everything
    ionice -c 1 -n 0 -p $$ >/dev/null 2>&1 || true  # Real-time I/O class
    renice -n -20 -p $$ >/dev/null 2>&1 || true     # Highest CPU priority
    ulimit -n 1048576 >/dev/null 2>&1 || true       # 1M file descriptors
    echo "Running with elevated process priority (root privileges)"
else
    # Non-root - try best effort
    ionice -c 2 -n 0 -p $$ >/dev/null 2>&1 || true  # Highest best-effort class
    renice -n -10 -p $$ >/dev/null 2>&1 || true     # Higher CPU priority
    ulimit -n 16384 >/dev/null 2>&1 || true         # Larger but limited FD count
    echo "Note: Run with sudo for maximum performance priority"
fi

# Ensure sufficient file descriptors and heap size for SQLite
SQLITE_FD_MAX="$(ulimit -n)"  # Current file descriptor limit

# Function to display help information
show_help() {
    echo "Usage: $0 [TEST_DIR] [TEST_SIZE] [DB_FILE]"
    echo ""
    echo "Parameters:"
    echo "  TEST_DIR  - Directory for test files (default: ./fs_test)"
    echo "  TEST_SIZE - Size for test files, auto-scaled if not provided"
    echo "  DB_FILE   - Path to SQLite database (default: filesystem-specific location)"
    echo ""
    echo "Examples:"
    echo "  $0                      # Run with defaults"
    echo "  $0 /mnt/test           # Use custom test directory"
    echo "  $0 /mnt/test 8G        # Use 8GB test size"
    echo "  $0 /mnt/test 8G db.sqlite # Use custom database file"
    echo ""
    exit 0
}

# Parse command-line arguments
[[ "$1" == "--help" || "$1" == "-h" ]] && show_help

# Configuration - optimized for LVM RAID0 over SSDs
TEST_DIR="${1:-./fs_test}"
NUM_JOBS=6       # Simulate a busy system with 6 concurrent jobs
RUNTIME_EACH=30  # Minimized runtime (30 seconds per test run)
RUNS=3           # Run each test 3 times
SCHEDULER="none" # IO scheduler set to none

# Smart defaults for test size based on free space
if [ -z "$2" ]; then
    # Get available space in test directory (in KB)
    if [ -d "$TEST_DIR" ]; then
        FREE_SPACE_KB=$(df -k "$TEST_DIR" | awk 'NR==2 {print $4}')
    else
        FREE_SPACE_KB=$(df -k "$(dirname "$TEST_DIR")" | awk 'NR==2 {print $4}')
    fi
    
    # Use 10% of free space but no more than 8GB and no less than 512MB
    TEST_SIZE_KB=$((FREE_SPACE_KB / 10))
    MIN_SIZE_KB=$((512 * 1024))  # 512MB
    MAX_SIZE_KB=$((8 * 1024 * 1024))  # 8GB
    
    if [ $TEST_SIZE_KB -lt $MIN_SIZE_KB ]; then
        TEST_SIZE_KB=$MIN_SIZE_KB
    elif [ $TEST_SIZE_KB -gt $MAX_SIZE_KB ]; then
        TEST_SIZE_KB=$MAX_SIZE_KB
    fi
    
    # Convert to GB or MB for better readability
    if [ $TEST_SIZE_KB -ge $((1024 * 1024)) ]; then
        TEST_SIZE="$((TEST_SIZE_KB / 1024 / 1024))G"
    else
        TEST_SIZE="$((TEST_SIZE_KB / 1024))M"
    fi
    
    echo "Auto-sized test file to $TEST_SIZE based on available space"
else
    TEST_SIZE="$2"
fi

# Smart default for database location
if [ -z "$3" ]; then
    # Determine best location for database
    if [ -w "/var/log" ]; then
        # If /var/log is writable, store there for persistence
        DB_DIR="/var/log/fs_benchmarks"
    elif [ -w "/tmp" ]; then
        # Use /tmp if available (less persistent but usually works)
        DB_DIR="/tmp/fs_benchmarks"
    else
        # Fall back to user's home directory
        DB_DIR="$HOME/.fs_benchmarks"
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$DB_DIR" 2>/dev/null || true
    
    # If we couldn't create the directory, use current directory
    if [ ! -d "$DB_DIR" ]; then
        DB_DIR="."
    fi
    
    # Create filesystem-specific database name (based on mount point)
    FS_ID=$(df -P "$TEST_DIR" | awk 'NR==2 {print $1}' | sed 's|/|_|g')
    DB_FILE="$DB_DIR/fs_benchmark_${FS_ID}.db"
else
    DB_FILE="$3"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
ORANGE='\033[0;33m'
NC='\033[0m'

# Check for required tools
if ! command -v fio &> /dev/null; then
    echo -e "${RED}Error: fio is required but not installed.${NC}"
    echo "Install with: apt-get install fio (Debian/Ubuntu) or yum install fio (RHEL/CentOS)"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo -e "${RED}Error: bc is required for calculations but not installed.${NC}"
    echo "Install with: apt-get install bc (Debian/Ubuntu) or yum install bc (RHEL/CentOS)"
    exit 1
fi

if ! command -v sqlite3 &> /dev/null; then
    echo -e "${RED}Error: sqlite3 is required but not installed.${NC}"
    echo "Install with: apt-get install sqlite3 (Debian/Ubuntu) or yum install sqlite3 (RHEL/CentOS)"
    exit 1
fi

# Check for optional tools
if ! command -v ionice &> /dev/null; then
    echo -e "${YELLOW}Warning: ionice not found. I/O priority optimization will be disabled.${NC}"
fi 

if ! command -v nice &> /dev/null; then
    echo -e "${YELLOW}Warning: nice not found. CPU priority optimization will be disabled.${NC}"
fi

# Create test directory if it doesn't exist
mkdir -p "$TEST_DIR"

# Function to initialize SQLite database
init_database() {
    echo -e "${BLUE}Initializing benchmark database...${NC}"
    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS test_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    kernel_version TEXT,
    cpu_info TEXT,
    filesystem_type TEXT,
    mount_options TEXT,
    test_dir TEXT NOT NULL,
    test_size TEXT NOT NULL,
    num_jobs INTEGER NOT NULL,
    run_time INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS test_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL,
    test_name TEXT NOT NULL,
    iops REAL NOT NULL,
    latency_ms REAL NOT NULL,
    bandwidth_kbs REAL NOT NULL,
    FOREIGN KEY (run_id) REFERENCES test_runs(id)
);

CREATE TABLE IF NOT EXISTS device_info (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL,
    device_path TEXT NOT NULL,
    device_type TEXT,
    write_cache TEXT,
    ncq_status TEXT,
    io_scheduler TEXT,
    readahead_kb TEXT,
    FOREIGN KEY (run_id) REFERENCES test_runs(id)
);
EOF
    echo "Database initialized at: $DB_FILE"
}

# Function to save run metadata to database
save_run_metadata() {
    local kernel cpu_info fs_type mount_opts
    
    kernel=$(uname -r)
    cpu_info=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string)
    fs_type=$(df -Th "$TEST_DIR" 2>/dev/null | tail -n1 | awk '{print $2}' || df -T "$TEST_DIR" | tail -n1 | awk '{print $2}')
    mount_opts=$(grep "$mount_point" /proc/mounts 2>/dev/null | awk '{print $4}' || mount | grep "$mount_point" | awk '{$1=$2=""; print $0}')
    
    echo -e "${BLUE}Saving run metadata to database...${NC}"
    
    # Insert run metadata and get the run_id
    RUN_ID=$(sqlite3 "$DB_FILE" <<EOF
INSERT INTO test_runs 
    (timestamp, kernel_version, cpu_info, filesystem_type, mount_options, test_dir, test_size, num_jobs, run_time)
VALUES 
    (datetime('now'), '$kernel', '$cpu_info', '$fs_type', '$mount_opts', '$TEST_DIR', '$TEST_SIZE', $NUM_JOBS, $RUNTIME_EACH);
SELECT last_insert_rowid();
EOF
)
    
    echo "Run metadata saved with ID: $RUN_ID"
}

# Function to save device info to database
save_device_info() {
    local device="$1"
    local device_type="$2"
    local write_cache="$3"
    local ncq_status="$4"
    local io_scheduler="$5"
    local readahead="$6"
    
    # Escape single quotes in all values
    device=$(echo "$device" | sed "s/'/''/g")
    device_type=$(echo "$device_type" | sed "s/'/''/g")
    write_cache=$(echo "$write_cache" | sed "s/'/''/g")
    ncq_status=$(echo "$ncq_status" | sed "s/'/''/g")
    io_scheduler=$(echo "$io_scheduler" | sed "s/'/''/g")
    readahead=$(echo "$readahead" | sed "s/'/''/g")
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO device_info 
    (run_id, device_path, device_type, write_cache, ncq_status, io_scheduler, readahead_kb)
VALUES 
    ($RUN_ID, '$device', '$device_type', '$write_cache', '$ncq_status', '$io_scheduler', '$readahead');
EOF
}

# Function to save test results to database
save_test_results() {
    local test_name="$1"
    local iops="$2"
    local latency="$3"
    local bandwidth="$4"
    
    # Escape single quotes in test_name
    test_name=$(echo "$test_name" | sed "s/'/''/g")
    
    # Set default values for empty metrics
    iops=${iops:-0}
    latency=${latency:-0}
    bandwidth=${bandwidth:-0}
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO test_results 
    (run_id, test_name, iops, latency_ms, bandwidth_kbs)
VALUES 
    ($RUN_ID, '$test_name', $iops, $latency, $bandwidth);
EOF
}

# Function to get the last run results for comparison
get_previous_results() {
    local test_name="$1"
    
    # Escape single quotes in test_name
    test_name=$(echo "$test_name" | sed "s/'/''/g")
    
    # Get the previous run's results for this test
    PREV_RUN_DATA=$(sqlite3 "$DB_FILE" <<EOF
SELECT r.iops, r.latency_ms, r.bandwidth_kbs 
FROM test_results r
JOIN test_runs tr ON r.run_id = tr.id
WHERE r.test_name = '$test_name'
  AND tr.id < $RUN_ID
ORDER BY tr.id DESC
LIMIT 1;
EOF
)

    if [ -n "$PREV_RUN_DATA" ]; then
        PREV_IOPS=$(echo "$PREV_RUN_DATA" | cut -d'|' -f1)
        PREV_LATENCY=$(echo "$PREV_RUN_DATA" | cut -d'|' -f2)
        PREV_BANDWIDTH=$(echo "$PREV_RUN_DATA" | cut -d'|' -f3)
        return 0
    else
        return 1
    fi
}

# Function to calculate percentage change
calc_percentage_change() {
    local current="$1"
    local previous="$2"
    
    if [ "$previous" = "0" ] || [ -z "$previous" ]; then
        echo "N/A"  # Avoid division by zero
    else
        local change
        change=$(echo "scale=2; (($current - $previous) / $previous) * 100" | bc)
        if [[ "$change" = -* ]]; then
            # For IOPS and bandwidth, negative is worse
            echo -e "${RED}${change}%${NC}"
        else
            echo -e "${GREEN}+${change}%${NC}"
        fi
    fi
}

# Function to calculate percentage change for latency (lower is better)
calc_percentage_change_latency() {
    local current="$1"
    local previous="$2"
    
    if [ "$previous" = "0" ] || [ -z "$previous" ]; then
        echo "N/A"  # Avoid division by zero
    else
        local change
        change=$(echo "scale=2; (($current - $previous) / $previous) * 100" | bc)
        if [[ "$change" = -* ]]; then
            # For latency, negative is better
            echo -e "${GREEN}${change}%${NC}"
        else
            echo -e "${RED}+${change}%${NC}"
        fi
    fi
}

# Function to detect underlying physical devices for a given directory
get_underlying_devices() {
    local dir="$1"
    local mount_point fs_device
    
    # Get the mount point for the directory
    mount_point=$(df -P "$dir" | tail -n1 | awk '{print $6}')
    
    # Get the device for this mount point
    fs_device=$(df -P "$dir" | tail -n1 | awk '{print $1}')
    
    # Check if it's an LVM volume
    if echo "$fs_device" | grep -q "/dev/mapper"; then
        # Get LVM details
        echo -e "${YELLOW}LVM detected:${NC} $fs_device"
        if command -v lvs &> /dev/null && command -v vgs &> /dev/null && command -v pvs &> /dev/null; then
            echo -e "${BLUE}LVM Configuration:${NC}"
            echo -e "${CYAN}Logical Volumes:${NC}"
            lvs 2>/dev/null | grep -v "No volume" || echo "  Unable to retrieve LV information"
            
            echo -e "${CYAN}Volume Groups:${NC}"
            vgs 2>/dev/null | grep -v "No volume" || echo "  Unable to retrieve VG information"
            
            echo -e "${CYAN}Physical Volumes:${NC}"
            pvs 2>/dev/null | grep -v "No volume" || echo "  Unable to retrieve PV information"
            
            # Get the underlying physical devices
            lv_name=$(echo "$fs_device" | sed 's/.*\///')
            vg_name=$(lvs --noheadings 2>/dev/null | grep "$lv_name" | awk '{print $2}')
            
            if [ -n "$vg_name" ]; then
                echo -e "${CYAN}Underlying Physical Devices:${NC}"
                pvs --noheadings 2>/dev/null | grep "$vg_name" | awk '{print $1}' || echo "  Unable to determine physical devices"
                
                # Save physical devices for further inspection
                PHYSICAL_DEVICES=($(pvs --noheadings 2>/dev/null | grep "$vg_name" | awk '{print $1}'))
            fi
        else
            echo "LVM tools not available. Unable to determine underlying devices."
            # Try to get actual device from /dev/mapper
            if [ -e "$fs_device" ]; then
                PHYSICAL_DEVICES=("$fs_device")
            fi
        fi
    elif echo "$fs_device" | grep -q "md"; then
        # Software RAID
        echo -e "${YELLOW}Software RAID detected:${NC} $fs_device"
        if [ -f /proc/mdstat ]; then
            echo -e "${BLUE}RAID Configuration:${NC}"
            cat /proc/mdstat | grep -A 1 $(basename "$fs_device") || echo "  Unable to retrieve RAID information"
            
            # Get the underlying devices
            echo -e "${CYAN}Underlying Physical Devices:${NC}"
            mdadm --detail "$fs_device" 2>/dev/null | grep "/dev/" | awk '{print $7}' || echo "  Unable to determine physical devices"
            
            # Save physical devices for further inspection
            PHYSICAL_DEVICES=($(mdadm --detail "$fs_device" 2>/dev/null | grep "/dev/" | awk '{print $7}'))
        else
            echo "RAID tools or /proc/mdstat not available. Unable to determine underlying devices."
            PHYSICAL_DEVICES=("$fs_device")
        fi
    else
        # Regular block device
        echo -e "${YELLOW}Storage device:${NC} $fs_device"
        PHYSICAL_DEVICES=("$fs_device")
    fi
}

# Function to check device parameters (write cache, NCQ, scheduler, readahead)
check_device_params() {
    local device="$1"
    local block_device short_name
    
    # Convert partition (e.g., /dev/sda1) to disk device (e.g., /dev/sda)
    if [[ "$device" =~ ^/dev/[a-zA-Z]+[0-9]+$ ]]; then
        block_device=$(echo "$device" | sed 's/[0-9]*$//')
    else
        block_device="$device"
    fi
    
    # Get just the device name without /dev/
    short_name=$(basename "$block_device")
    
    echo -e "${BLUE}Device parameters for ${device}:${NC}"
    
    # Check if device is an SSD
    local is_ssd=0
    local device_type="Unknown"
    if [ -d "/sys/block/$short_name" ]; then
        if [ -f "/sys/block/$short_name/queue/rotational" ]; then
            if [ "$(cat /sys/block/$short_name/queue/rotational)" -eq 0 ]; then
                echo -e "${YELLOW}Device type:${NC} SSD"
                is_ssd=1
                device_type="SSD"
            else
                echo -e "${YELLOW}Device type:${NC} HDD (rotational)"
                device_type="HDD (rotational)"
            fi
        fi
    fi
    
    # Check write cache status
    local write_cache_status="Unknown"
    if [ -f "/sys/block/$short_name/device/scsi_disk/${short_name}/cache_type" ]; then
        write_cache_status=$(cat "/sys/block/$short_name/device/scsi_disk/${short_name}/cache_type")
        echo -e "${YELLOW}Write cache:${NC} $write_cache_status"
    elif [ -f "/sys/block/$short_name/device/write_cache" ]; then
        write_cache=$(cat "/sys/block/$short_name/device/write_cache")
        if [ "$write_cache" = "1" ]; then
            write_cache_status="Enabled"
            echo -e "${YELLOW}Write cache:${NC} Enabled"
        else
            write_cache_status="Disabled"
            echo -e "${YELLOW}Write cache:${NC} Disabled"
        fi
    elif command -v hdparm &> /dev/null; then
        hdparm_output=$(hdparm -W "$block_device" 2>/dev/null | grep "write-caching" || echo "Unknown")
        write_cache_status="$hdparm_output"
        echo -e "${YELLOW}Write cache (via hdparm):${NC} $hdparm_output"
    else
        echo -e "${YELLOW}Write cache:${NC} Unable to determine"
    fi
    
    # Check NCQ status for SATA devices
    local ncq_status="Unknown"
    if [ "$is_ssd" -eq 1 ]; then
        if [ -f "/sys/block/$short_name/device/queue_depth" ]; then
            local queue_depth=$(cat "/sys/block/$short_name/device/queue_depth")
            if [ "$queue_depth" -gt 1 ]; then
                ncq_status="Enabled (queue depth: $queue_depth)"
                echo -e "${YELLOW}NCQ:${NC} Enabled (queue depth: $queue_depth)"
            else
                ncq_status="Disabled"
                echo -e "${YELLOW}NCQ:${NC} Disabled"
            fi
        elif command -v smartctl &> /dev/null; then
            smartctl_output=$(smartctl -i "$block_device" 2>/dev/null | grep "NCQ" || echo "Unable to determine")
            ncq_status="$smartctl_output"
            echo -e "${YELLOW}NCQ (via smartctl):${NC} $smartctl_output"
        else
            echo -e "${YELLOW}NCQ:${NC} Unable to determine"
        fi
    fi
    
    # Check I/O scheduler
    local io_scheduler="Unknown"
    if [ -f "/sys/block/$short_name/queue/scheduler" ]; then
        io_scheduler=$(cat "/sys/block/$short_name/queue/scheduler" | tr -d '[]')
        echo -e "${YELLOW}I/O scheduler:${NC} $io_scheduler"
    else
        echo -e "${YELLOW}I/O scheduler:${NC} Unable to determine"
    fi
    
    # Check readahead setting
    local readahead="Unknown"
    if [ -f "/sys/block/$short_name/queue/read_ahead_kb" ]; then
        readahead=$(cat "/sys/block/$short_name/queue/read_ahead_kb")
        echo -e "${YELLOW}Readahead:${NC} $readahead KB"
    elif command -v blockdev &> /dev/null; then
        blockdev_output=$(blockdev --getra "$block_device" 2>/dev/null || echo "Unable to determine")
        readahead="$blockdev_output KB"
        echo -e "${YELLOW}Readahead (via blockdev):${NC} $blockdev_output KB"
    else
        echo -e "${YELLOW}Readahead:${NC} Unable to determine"
    fi
    
    # Check for NVMe devices
    if [[ "$short_name" == nvme* ]]; then
        echo -e "${YELLOW}NVMe device details:${NC}"
        if command -v nvme &> /dev/null; then
            nvme_output=$(nvme list 2>/dev/null | grep "$block_device" || echo "Unable to retrieve NVMe device details")
            echo "$nvme_output"
            # Update device type
            device_type="NVMe SSD"
        else
            echo "  NVMe tools not available"
        fi
    fi
    
    # Save device info to database
    save_device_info "$device" "$device_type" "$write_cache_status" "$ncq_status" "$io_scheduler" "$readahead"
    
    echo ""
}

# Initialize the database
init_database

# Display system information
echo -e "${BLUE}=== System Information ===${NC}"
echo -e "${YELLOW}Kernel:${NC} $(uname -r)"
echo -e "${YELLOW}CPU:${NC} $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string)"
echo -e "${YELLOW}Memory:${NC} $(free -h 2>/dev/null | grep Mem | awk '{print $2}' || sysctl -n hw.memsize | awk '{print $1/1024/1024/1024 " GB"}')"
echo -e "${YELLOW}Filesystem:${NC} $(df -Th "$TEST_DIR" 2>/dev/null | tail -n1 | awk '{print $2}' || df -T "$TEST_DIR" | tail -n1 | awk '{print $2}')"
mount_point=$(df -P "$TEST_DIR" | tail -n1 | awk '{print $6}')
echo -e "${YELLOW}Mount options:${NC} $(grep "$mount_point" /proc/mounts 2>/dev/null | awk '{print $4}' || mount | grep "$mount_point" | awk '{$1=$2=""; print $0}')"
echo ""

# Save run metadata to get RUN_ID
save_run_metadata

# Detect underlying storage devices and check their parameters
echo -e "${BLUE}=== Storage Device Analysis ===${NC}"
get_underlying_devices "$TEST_DIR"

# Check parameters for all detected physical devices
if [ ${#PHYSICAL_DEVICES[@]} -gt 0 ]; then
    for device in "${PHYSICAL_DEVICES[@]}"; do
        if [ -n "$device" ] && [ -e "$device" ]; then
            check_device_params "$device"
        fi
    done
else
    echo -e "${RED}Unable to detect physical storage devices.${NC}"
    echo "The script will continue with performance testing, but storage parameters cannot be verified."
    echo ""
fi

# Display test parameters optimized for LVM RAID0 SSDs
echo -e "${BLUE}=== Test Parameters (Optimized for LVM RAID0 SSDs) ===${NC}"
echo -e "${YELLOW}Test directory:${NC} $TEST_DIR"
echo -e "${YELLOW}Test size:${NC} $TEST_SIZE ($(numfmt --from=iec --to=iec-i "${TEST_SIZE%[GMK]}${TEST_SIZE: -1}" 2>/dev/null || echo "${TEST_SIZE}"))"
echo -e "${YELLOW}Number of jobs:${NC} $NUM_JOBS (busy system simulation)"
echo -e "${YELLOW}Runtime per test:${NC} $RUNTIME_EACH seconds"
echo -e "${YELLOW}Number of runs per test:${NC} $RUNS (with geometric mean calculation)"
echo -e "${YELLOW}Database file:${NC} $DB_FILE"
echo ""

# Define SSD-optimized parameters
SSD_PARAMS="--direct=1 --ioengine=libaio --allow_file_create=1 --thread --verify=0 --norandommap --serialize_overlap=1"

# Function to calculate geometric mean of an array of values
calculate_geomean() {
    local product=1
    local size=${#RESULTS[@]}
    
    # Check if array is empty
    if [ $size -eq 0 ]; then
        echo "0"
        return
    fi
    
    for value in "${RESULTS[@]}"; do
        # Skip empty or non-numeric values
        if [[ -z "$value" || "$value" == *"avg="* ]]; then
            # Extract number from avg= format
            value=$(echo "$value" | sed 's/avg=//g')
        fi
        
        # Skip if still empty or non-numeric
        if [[ -z "$value" || ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            continue
        fi
        
        product=$(echo "$product * $value" | bc -l)
    done
    
    # Recount size based on valid elements processed
    local valid_size=0
    for value in "${RESULTS[@]}"; do
        if [[ -n "$value" && "$value" =~ ^[0-9]+(\.[0-9]+)?$ || "$value" == *"avg="* ]]; then
            valid_size=$((valid_size + 1))
        fi
    done
    
    # If no valid elements, return 0
    if [ $valid_size -eq 0 ]; then
        echo "0"
        return
    fi
    
    echo $(echo "e(l($product)/$valid_size)" | bc -l)
}

# Function to extract metrics from fio output
extract_metric() {
    local output=$1
    local metric=$2
    
    case "$metric" in
        "iops")
            echo "$output" | grep -E 'iops\s*=' | grep -v "drop" | head -1 | awk -F'=' '{print $2}' | awk '{print $1}' | sed 's/k/\*1000/' | bc
            ;;
        "lat")
            echo "$output" | grep -A2 "lat" | grep "avg" | head -1 | awk '{print $(NF-1)}' | sed 's/,//g'
            ;;
        "bw")
            # Try newer fio format first: "bw=7896KiB/s (8085kB/s)"
            bw=$(echo "$output" | grep -E 'bw=[0-9.]+[kKMG]?iB/s' | grep -v "drop" | head -1)
            if [[ -n "$bw" ]]; then
                echo "$bw" | awk -F'=' '{print $2}' | awk '{print $1}' | sed 's/\([0-9.]*\)\([kKMG]\)iB\/s.*/\1/' | \
                sed 's/[kK]/*1024/;s/M/*1048576/;s/G/*1073741824/' | bc
            else
                # Fall back to older format
                echo "$output" | grep -E 'bw\s*=' | grep -v "drop" | head -1 | awk -F'=' '{print $2}' | awk '{print $1}' | \
                sed 's/\([0-9.]*\)\([kKMG]\)\?B\/s.*/\1/' | sed 's/[kK]/*1024/;s/M/*1048576/;s/G/*1073741824/' | bc || echo "0"
            fi
            ;;
    esac
}

# Function to run fio test multiple times and calculate geometric mean
run_test() {
    local test_name=$1
    local fio_options=$2
    local description=$3
    
    echo -e "${GREEN}Running test: ${test_name}${NC}"
    echo -e "${YELLOW}Description:${NC} ${description}"
    
    # Arrays to store results
    declare -a RESULTS_IOPS
    declare -a RESULTS_LAT
    declare -a RESULTS_BW
    
    # Ensure we have enough file descriptors for FIO
    required_fds=$((NUM_JOBS * 100))
    if [ "$SQLITE_FD_MAX" -lt "$required_fds" ]; then
        echo -e "${YELLOW}Warning: Current file descriptor limit ($SQLITE_FD_MAX) may be too low for test with $NUM_JOBS jobs${NC}"
        echo -e "${YELLOW}Try: ulimit -n $((required_fds * 2)) before running this script${NC}"
    fi
    
    for run in $(seq 1 $RUNS); do
        echo -e "${BLUE}Run $run of $RUNS${NC}"
        echo -e "${YELLOW}Command:${NC} fio $SSD_PARAMS $fio_options"
        
        # Clear caches if possible before each run
        if [ "$(id -u)" -eq 0 ]; then
            echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
            sync
        fi
        
        # Elevate fio process priority
        if [ "$(id -u)" -eq 0 ]; then
            # Capture the output of fio with highest priority
            OUTPUT=$(ionice -c 1 -n 0 nice -n -20 fio $SSD_PARAMS $fio_options)
        else
            # Non-root - use best effort priority
            OUTPUT=$(ionice -c 2 -n 0 nice -n -10 fio $SSD_PARAMS $fio_options)
        fi
        
        # Extract metrics from the output
        IOPS=$(extract_metric "$OUTPUT" "iops")
        LAT=$(extract_metric "$OUTPUT" "lat")
        BW=$(extract_metric "$OUTPUT" "bw")
        
        echo -e "${PURPLE}Run $run Results: IOPS=$IOPS, Latency=$LAT ms, Bandwidth=$BW KB/s${NC}"
        
        # Store results
        RESULTS_IOPS+=($IOPS)
        RESULTS_LAT+=($LAT)
        RESULTS_BW+=($BW)
        
        # Short pause between runs to let system stabilize
        sleep 3
    done
    
    # Calculate geometric means
    RESULTS=("${RESULTS_IOPS[@]}")
    GEOMEAN_IOPS=$(calculate_geomean)
    
    RESULTS=("${RESULTS_LAT[@]}")
    GEOMEAN_LAT=$(calculate_geomean)
    
    RESULTS=("${RESULTS_BW[@]}")
    GEOMEAN_BW=$(calculate_geomean)
    
    # Save results to database
    save_test_results "$test_name" "$GEOMEAN_IOPS" "$GEOMEAN_LAT" "$GEOMEAN_BW"
    
    # Try to get previous results for comparison
    if get_previous_results "$test_name"; then
        # Calculate percentage changes
        IOPS_CHANGE=$(calc_percentage_change "$GEOMEAN_IOPS" "$PREV_IOPS")
        LAT_CHANGE=$(calc_percentage_change_latency "$GEOMEAN_LAT" "$PREV_LATENCY")
        BW_CHANGE=$(calc_percentage_change "$GEOMEAN_BW" "$PREV_BANDWIDTH")
        
        # Print results with comparisons
        echo ""
        echo -e "${GREEN}=== Geometric Mean Results for $test_name (with comparison) ===${NC}"
        echo -e "${YELLOW}IOPS:${NC}             $(printf "%.2f" $GEOMEAN_IOPS) \t[Previous: $(printf "%.2f" $PREV_IOPS) \tChange: $IOPS_CHANGE]"
        echo -e "${YELLOW}Average Latency:${NC}  $(printf "%.2f" $GEOMEAN_LAT) ms \t[Previous: $(printf "%.2f" $PREV_LATENCY) ms \tChange: $LAT_CHANGE]"
        echo -e "${YELLOW}Bandwidth:${NC}        $(printf "%.2f" $GEOMEAN_BW) KB/s \t[Previous: $(printf "%.2f" $PREV_BANDWIDTH) KB/s \tChange: $BW_CHANGE]"
    else
        # No previous results to compare against
        echo ""
        echo -e "${GREEN}=== Geometric Mean Results for $test_name ===${NC}"
        echo -e "${YELLOW}IOPS:${NC}             $(printf "%.2f" $GEOMEAN_IOPS)"
        echo -e "${YELLOW}Average Latency:${NC}  $(printf "%.2f" $GEOMEAN_LAT) ms"
        echo -e "${YELLOW}Bandwidth:${NC}        $(printf "%.2f" $GEOMEAN_BW) KB/s"
        echo -e "${BLUE}(No previous test data available for comparison)${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}Completed test: ${test_name}${NC}"
    echo "--------------------------------------------------------------"
    echo ""
}

# Create an empty file to pre-allocate space (avoids filesystem growth during tests)
echo -e "${BLUE}Pre-allocating test file...${NC}"
fallocate -l "$TEST_SIZE" "${TEST_DIR}/preallocated_file" 2>/dev/null || \
dd if=/dev/zero of="${TEST_DIR}/preallocated_file" bs=1M count=$((${TEST_SIZE%G} * 1024)) status=progress 2>/dev/null
echo ""

# 1. METADATA-INTENSIVE WORKLOAD (WORST CASE)
run_test "Metadata-Intensive Workload" "--directory=$TEST_DIR --name=metadata_stress --size=32M --nrfiles=1000 --rw=randwrite --bs=4k --sync=1 --fsync=1 --runtime=$RUNTIME_EACH --time_based --numjobs=$NUM_JOBS --group_reporting --iodepth=64 --file_service_type=random --ramp_time=5" \
"This worst-case scenario test creates thousands of small files with synchronous writes, stressing the filesystem's metadata operations, journal, and directory structure."

# 2. SYNCHRONOUS SMALL RANDOM WRITES
run_test "Synchronous Small Random Writes" "--directory=$TEST_DIR --name=sync_rand_write --size=$TEST_SIZE --rw=randwrite --bs=4k --sync=1 --runtime=$RUNTIME_EACH --time_based --numjobs=$NUM_JOBS --group_reporting --iodepth=64 --ramp_time=5" \
"Tests small random write performance with synchronous I/O, forcing all writes to hit the physical media."

# 3. FSYNC HEAVY WORKLOAD
run_test "FSyncHeavyWorkload" "--directory=$TEST_DIR --name=fsync_heavy --size=$TEST_SIZE --rw=write --bs=4k --fsync=8 --runtime=$RUNTIME_EACH --time_based --numjobs=$NUM_JOBS --group_reporting --iodepth=32 --ramp_time=5" \
"Simulates a database-like workload with frequent fsync operations, challenging the filesystem's ability to persist data quickly."

# 4. MULTIPLE FILE CREATION/DELETION
cat > "${TEST_DIR}/file_create_delete.fio" << EOF
[global]
directory=$TEST_DIR
runtime=$RUNTIME_EACH
time_based=1
ioengine=libaio
direct=1
group_reporting=1
allow_file_create=1
thread=1
ramp_time=5

[file-create-delete]
description=File create/delete benchmark
ioengine=filecreate
filesize=4k
nrfiles=10000
openfiles=2048
file_service_type=random
rw=randwrite
numjobs=$NUM_JOBS
dedupe_percentage=50
create_only=0
EOF

run_test "Multiple File Creation/Deletion" "--client=client.section=$TEST_DIR/file_create_delete.fio" \
"Creates and deletes thousands of small files, stressing inode allocation/deallocation and directory operations."

# 5. SMALL FILE SCATTERED IO
run_test "Small File Scattered IO" "--directory=$TEST_DIR --name=scattered_io --filesize=4k --nrfiles=10000 --rw=randrw --bs=4k --runtime=$RUNTIME_EACH --time_based --numjobs=$NUM_JOBS --group_reporting --iodepth=32 --ramp_time=5" \
"Performs random reads and writes across thousands of small files, creating scattered I/O patterns that stress disk seek times and caching."

# 6. MIXED READ/WRITE WORKLOAD WITH HIGH QUEUE DEPTH
run_test "Mixed ReadWrite High Queue" "--directory=$TEST_DIR --name=mixed_rw --size=$TEST_SIZE --rw=randrw --rwmixread=70 --bs=8k --runtime=$RUNTIME_EACH --time_based --numjobs=$NUM_JOBS --group_reporting --iodepth=128 --ramp_time=5" \
"Simulates mixed read/write workload with a high queue depth, typical of busy database or virtualization environments."

# Clean up
echo -e "${BLUE}Cleaning up test files...${NC}"
rm -f "${TEST_DIR}/preallocated_file" "${TEST_DIR}/file_create_delete.fio"
sync  # Ensure all data is flushed to disk
echo "Done!"

# Print overall comparison with previous run
echo -e "${BLUE}=== Overall Performance Comparison with Last Run ===${NC}"

# Get all tests from current run
TEST_NAMES=$(sqlite3 "$DB_FILE" "SELECT test_name FROM test_results WHERE run_id = $RUN_ID ORDER BY id;")

# Check if there's a previous run to compare with
PREV_RUN=$(sqlite3 "$DB_FILE" "SELECT id FROM test_runs WHERE id < $RUN_ID ORDER BY id DESC LIMIT 1;")

if [ -n "$PREV_RUN" ]; then
    echo -e "${ORANGE}Test Name                         IOPS Change        Latency Change      Bandwidth Change${NC}"
    echo "--------------------------------------------------------------------------------"
    
    # For each test, get current and previous metrics and calculate change
    for test in $TEST_NAMES; do
        # Get current metrics
        CURR_METRICS=$(sqlite3 "$DB_FILE" "SELECT iops, latency_ms, bandwidth_kbs FROM test_results WHERE run_id = $RUN_ID AND test_name = '$test';")
        CURR_IOPS=$(echo "$CURR_METRICS" | cut -d'|' -f1)
        CURR_LAT=$(echo "$CURR_METRICS" | cut -d'|' -f2)
        CURR_BW=$(echo "$CURR_METRICS" | cut -d'|' -f3)
        
        # Get previous metrics
        PREV_METRICS=$(sqlite3 "$DB_FILE" "SELECT iops, latency_ms, bandwidth_kbs FROM test_results WHERE run_id = $PREV_RUN AND test_name = '$test';")
        
        if [ -n "$PREV_METRICS" ]; then
            PREV_IOPS=$(echo "$PREV_METRICS" | cut -d'|' -f1)
            PREV_LAT=$(echo "$PREV_METRICS" | cut -d'|' -f2)
            PREV_BW=$(echo "$PREV_METRICS" | cut -d'|' -f3)
            
            # Calculate changes
            IOPS_CHANGE=$(calc_percentage_change "$CURR_IOPS" "$PREV_IOPS")
            LAT_CHANGE=$(calc_percentage_change_latency "$CURR_LAT" "$PREV_LAT")
            BW_CHANGE=$(calc_percentage_change "$CURR_BW" "$PREV_BW")
            
            # Print comparison line (padding for alignment)
            printf "%-32s %-18s %-18s %-18s\n" "$test" "$IOPS_CHANGE" "$LAT_CHANGE" "$BW_CHANGE"
        else
            printf "%-32s %-18s %-18s %-18s\n" "$test" "N/A" "N/A" "N/A"
        fi
    done
    
    echo ""
    echo "Performance interpretation:"
    echo "- IOPS: Higher is better, positive change is good"
    echo "- Latency: Lower is better, negative change is good"
    echo "- Bandwidth: Higher is better, positive change is good"
else
    echo "No previous test runs found for comparison."
fi

echo ""
echo -e "${GREEN}All filesystem stress tests completed!${NC}"
echo "Test results have been saved to the database at: $DB_FILE"
echo ""
echo "To view all test runs: sqlite3 $DB_FILE 'SELECT * FROM test_runs;'"
echo "To view results: sqlite3 $DB_FILE 'SELECT * FROM test_results WHERE run_id = $RUN_ID;'"
echo "For more advanced queries: sqlite3 $DB_FILE 'SELECT tr.test_name, tr.iops, tr.latency_ms, tr.bandwidth_kbs FROM test_results tr JOIN test_runs r ON tr.run_id = r.id ORDER BY r.id DESC, tr.test_name;'"
echo ""
echo "Pay special attention to the Metadata-Intensive and FSyncHeavyWorkload tests,"
echo "as these tend to reveal the most performance limitations in filesystem implementations."