#!/bin/bash
#
# snapshot-file-check.sh - Simple file checker for snapshots
#
# This script searches for files from a file list and counts matches,
# reconstructing paths from snapshot directory to production filesystem.

set -euo pipefail

# Default snapshot directory
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/mnt/storage/.snapshots}"
SNAPSHOT_DATE=""
MOUNT_POINT="storage"

# Print usage information
usage() {
    echo "Usage: $0 [options] -f file_list"
    echo
    echo "Options:"
    echo "  -s, --snapshot-dir DIR   Specify snapshots directory (default: $SNAPSHOT_DIR)"
    echo "  -d, --date DATE          Specify snapshot date (e.g., @GMT-2025.05.14-00.00.00)"
    echo "  -m, --mount MOUNT        Specify mount point name (default: $MOUNT_POINT)"
    echo "  -f, --file-list FILE     Read list of files to check from FILE (one file per line)"
    echo "  -h, --help               Show this help message"
    echo
    exit 1
}

# Main function to check files
check_files() {
    local file_list="$1"
    local found_count=0
    local not_found_count=0
    local total_count=0
    
    if [ ! -f "$file_list" ]; then
        echo "Error: File list '$file_list' not found."
        exit 1
    fi
    
    if [ ! -d "$SNAPSHOT_DIR" ]; then
        echo "Error: Snapshot directory '$SNAPSHOT_DIR' not found."
        exit 1
    fi
    
    if [ -z "$SNAPSHOT_DATE" ]; then
        echo "Error: Snapshot date not specified. Use -d option."
        exit 1
    fi
    
    # Full path to snapshot directory
    local full_snapshot_path="$SNAPSHOT_DIR/$SNAPSHOT_DATE"
    
    if [ ! -d "$full_snapshot_path" ]; then
        echo "Error: Snapshot directory '$full_snapshot_path' not found."
        exit 1
    }
    
    echo "Checking files from '$file_list' in snapshot '$full_snapshot_path'..."
    echo "Results will show reconstructed paths to /mnt/$MOUNT_POINT/..."
    echo
    
    # Process each file in the list
    while IFS= read -r line || [ -n "${line:-}" ]; do
        # Skip empty lines and comments
        if [ -z "${line:-}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        ((total_count++))
        
        # Check if file exists in snapshot
        local snapshot_file="$full_snapshot_path/$line"
        local dest_file="/mnt/$MOUNT_POINT/$line"
        
        if [ -f "$snapshot_file" ]; then
            echo "FOUND: $line"
            echo "  Source: $snapshot_file"
            echo "  Target: $dest_file"
            ((found_count++))
        else
            echo "NOT FOUND: $line"
            ((not_found_count++))
        fi
    done < "$file_list"
    
    # Print summary
    echo
    echo "Summary:"
    echo "  Total files checked: $total_count"
    echo "  Files found: $found_count"
    echo "  Files not found: $not_found_count"
    
    # Calculate percentages if total count is non-zero
    if [ "$total_count" -gt 0 ]; then
        local found_percent=$((found_count * 100 / total_count))
        local not_found_percent=$((not_found_count * 100 / total_count))
        echo "  Found percentage: ${found_percent}%"
        echo "  Not found percentage: ${not_found_percent}%"
    fi
}

# Parse command line arguments
main() {
    local file_list=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--snapshot-dir)
                SNAPSHOT_DIR="$2"
                shift 2
                ;;
            -d|--date)
                SNAPSHOT_DATE="$2"
                shift 2
                ;;
            -m|--mount)
                MOUNT_POINT="$2"
                shift 2
                ;;
            -f|--file-list)
                file_list="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Error: Unknown option $1"
                usage
                ;;
        esac
    done
    
    if [ -z "$file_list" ]; then
        echo "Error: No file list specified. Use -f option."
        usage
    fi
    
    check_files "$file_list"
}

# Call main with all script arguments
main "$@"