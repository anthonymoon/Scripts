#!/bin/bash
#
# snapshot-file-restore.sh - Efficient file restoration from snapshots
#
# This script searches for files from a file list, efficiently locates them in snapshots,
# and restores them to the production filesystem with proper directory structure.

set -euo pipefail

# Default number of parallel jobs
PARALLEL_JOBS=4

# Track start time
start_time=$(date +%s)

# Trap for cleanup on exit
trap cleanup EXIT INT TERM

# Temporary files
TMP_FILE_LIST="$(mktemp -t snapshot_restore.XXXXXX)" || exit 1
TMP_RESULTS="$(mktemp -t snapshot_results.XXXXXX)" || exit 1
TMP_FOUND_FILES="$(mktemp -t snapshot_found.XXXXXX)" || exit 1

# Cleanup function
cleanup() {
    # Clear progress line
    echo -ne "\033[K"
    
    rm -f "$TMP_FILE_LIST" "$TMP_RESULTS" "$TMP_FOUND_FILES"
    
    # Print a message if we're exiting due to an interrupt
    if [ "$?" -ne 0 ]; then
        echo "Operation interrupted. Temporary files cleaned up."
    fi
}

# Default snapshot directory
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/mnt/storage/.snapshots}"
SNAPSHOT_DATE=""
MOUNT_POINT="storage"
SEARCH_PATH=""  # Search path within snapshot for finding files
DRY_RUN=false
MAX_DEPTH=3  # Default depth for initial quick search

# Print usage information
usage() {
    echo "Usage: $0 [options] -f file_list"
    echo
    echo "Options:"
    echo "  -s, --snapshot-dir DIR   Specify snapshots directory (default: $SNAPSHOT_DIR)"
    echo "  -d, --date DATE          Specify snapshot date (e.g., @GMT-2025.05.14-00.00.00)"
    echo "  -m, --mount MOUNT        Specify mount point name (default: $MOUNT_POINT)"
    echo "  -S, --search-path PATH   Specify search path within snapshot (default: snapshot root)"
    echo "  -f, --file-list FILE     Read list of files to restore from FILE (one file per line)"
    echo "  -r, --dry-run            Show what would be done without making any changes"
    echo "  -p, --parallel N         Number of parallel jobs (default: auto-detected)"
    echo "  -D, --max-depth N        Maximum search depth for quick search (default: $MAX_DEPTH)"
    echo "  -h, --help               Show this help message"
    echo
    exit 1
}

# Check if required commands exist
check_requirements() {
    local missing=0
    for cmd in find rsync mkdir dirname basename xargs sort grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' command not found"
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        exit 1
    fi

    # Set number of parallel processes based on CPU count
    # Use nproc if available, otherwise try processors in /proc/cpuinfo, fallback to default
    if command -v nproc >/dev/null 2>&1; then
        PARALLEL_JOBS=$(nproc 2>/dev/null || echo 4)
    elif [ -f /proc/cpuinfo ]; then
        PARALLEL_JOBS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
    else
        PARALLEL_JOBS=4
    fi
}

# Find a file in the snapshot with optimized search strategy
find_file_in_snapshot() {
    local snapshot_root="$1"
    local filename="$2"
    local original_path="$3"
    local results_file="$4"
    
    # Determine the base search path
    local search_base="$snapshot_root"
    if [ -n "$SEARCH_PATH" ]; then
        search_base="$snapshot_root/$SEARCH_PATH"
        # Ensure the search path exists
        if [ ! -d "$search_base" ]; then
            echo "  Warning: Search path '$SEARCH_PATH' not found in snapshot. Falling back to snapshot root."
            search_base="$snapshot_root"
        else
            echo "  Using search path: $SEARCH_PATH"
        fi
    fi
    
    # Step 1: Try a targeted search in directories similar to the original path
    if [ -n "$original_path" ]; then
        local dir_path=$(dirname "$original_path")
        if [ "$dir_path" != "." ]; then
            # Try to find the file in a path similar to the original
            find "$search_base" -path "*$dir_path*" -name "$filename" -type f -print > "$results_file" 2>/dev/null || true
            
            # If we found matches, we're done
            if [ -s "$results_file" ]; then
                return 0
            fi
        fi
    fi
    
    # Step 2: Try a faster limited-depth search first to find common files
    find "$search_base" -maxdepth "$MAX_DEPTH" -name "$filename" -type f -print > "$results_file" 2>/dev/null || true
    
    # If we found matches at shallow depth, we're done
    if [ -s "$results_file" ]; then
        return 0
    fi
    
    # Step 3: If the file wasn't found in common locations, use parallel deep search
    echo "  Performing deep search for '$filename'..."
    
    # Use find with parallel processing for better performance
    # Split the search across multiple subdirectories in parallel
    for top_dir in $(find "$search_base" -maxdepth 1 -type d 2>/dev/null | tail -n +2); do
        if [ -d "$top_dir" ]; then
            find "$top_dir" -name "$filename" -type f -print &
        fi
    done | head -n 10 > "$results_file"  # Limit to first 10 matches for speed
    
    wait  # Wait for all parallel searches to complete
    
    # If still no matches, try one final deep search on the root
    if [ ! -s "$results_file" ]; then
        echo "  Last resort search in specified search path..."
        find "$search_base" -name "$filename" -type f -print | head -n 1 > "$results_file" 2>/dev/null || true
    fi
    
    if [ -s "$results_file" ]; then
        return 0
    else
        return 1
    fi
}

# Restore a file from snapshot to destination
restore_file() {
    local source_file="$1"
    local dest_path="$2"
    local dest_file="/mnt/$MOUNT_POINT/$dest_path"
    local dest_dir=$(dirname "$dest_file")
    
    # Check if target file already exists
    if [ -f "$dest_file" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "# SKIPPED: File already exists at $dest_file"
        else
            echo "  SKIPPED: File already exists at $dest_file"
        fi
        return 2  # Skipped
    fi
    
    # Create target directory if it doesn't exist
    if [ ! -d "$dest_dir" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "# mkdir -pv \"$dest_dir\""
        else
            if ! mkdir -pv "$dest_dir"; then
                echo "  ERROR: Failed to create directory: $dest_dir"
                return 1  # Error
            fi
            echo "  Created directory: $dest_dir"
        fi
    fi
    
    # Check directory permissions
    if [ "$DRY_RUN" = false ] && [ ! -w "$dest_dir" ]; then
        echo "  ERROR: No write permission in directory: $dest_dir"
        return 1  # Error
    fi
    
    # Copy file using rsync instead of hardlink
    if [ "$DRY_RUN" = true ]; then
        echo "# rsync -a \"$source_file\" \"$dest_file\""
        return 0  # Success in dry run
    else
        # Check if source is readable
        if [ ! -r "$source_file" ]; then
            echo "  ERROR: Cannot read source file: $source_file"
            return 1  # Error
        fi
        
        if rsync -a "$source_file" "$dest_file"; then
            echo "  Restored to: $dest_file"
            return 0  # Success
        else
            echo "  FAILED to restore to: $dest_file"
            return 1  # Error
        fi
    fi
}

# Main function to check and restore files
restore_files() {
    local file_list="$1"
    local found_count=0
    local not_found_count=0
    local restored_count=0
    local skipped_count=0
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
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "# DRY RUN: The following commands would be executed"
        echo "# =================================================="
        echo "# Processing files from '$file_list' in snapshot '$full_snapshot_path'..."
    else
        echo "Processing files from '$file_list' in snapshot '$full_snapshot_path'..."
        echo "Files will be restored to /mnt/$MOUNT_POINT/..."
        echo
    fi
    
    # Create a file list with cleaned paths - handle empty files properly
    grep -v '^[[:space:]]*$' "$file_list" 2>/dev/null | grep -v '^[[:space:]]*#' > "$TMP_FILE_LIST" || true
    
    # Check if file list is empty after filtering
    if [ ! -s "$TMP_FILE_LIST" ]; then
        echo "Error: No valid file paths found in '$file_list' after filtering comments and empty lines."
        exit 1
    fi
    
    local total_files=$(wc -l < "$TMP_FILE_LIST")
    
    echo "Processing $total_files files..."
    
    # Process each file in the list
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines explicitly
        [ -z "$line" ] && continue
        
        total_count=$((total_count + 1))
        
        # Show progress percentage
        if [ $((total_count % 10)) -eq 0 ] || [ $total_count -eq 1 ]; then
            local percent=$((total_count * 100 / total_files))
            echo -ne "Progress: $percent% ($total_count/$total_files)\r"
        fi
        
        # Clean up path (remove leading slash if present)
        local clean_path="${line#/}"
        
        # Check if file exists in expected snapshot location
        local snapshot_file="$full_snapshot_path/$clean_path"
        
        if [ -f "$snapshot_file" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo "# FOUND: $clean_path (exact path match)"
            else
                echo "FOUND: $clean_path (exact path match)"
            fi
            found_count=$((found_count + 1))
            
            # Restore the file
            restore_file "$snapshot_file" "$clean_path"
            
            case $? in
                0) restored_count=$((restored_count + 1)) ;;
                2) skipped_count=$((skipped_count + 1)) ;;
            esac
        else
            if [ "$DRY_RUN" = true ]; then
                echo "# NOT FOUND at exact path: $clean_path"
                echo "# Searching for filename in snapshot..."
            else
                echo "NOT FOUND at exact path: $clean_path"
                echo "  Searching for filename in snapshot..."
            fi
            
            # Extract filename and search for it
            local filename=$(basename "$clean_path")
            
            # Try to find the file in the snapshot using optimized search
            if find_file_in_snapshot "$full_snapshot_path" "$filename" "$clean_path" "$TMP_FOUND_FILES"; then
                # Get the first match as the source file
                local source_file=$(head -1 "$TMP_FOUND_FILES")
                
                if [ -n "$source_file" ]; then
                    found_count=$((found_count + 1))
                    
                    if [ "$DRY_RUN" = true ]; then
                        echo "# FOUND: $filename in alternate location"
                        echo "# Source: $source_file"
                    else
                        echo "FOUND: $filename in alternate location"
                        echo "  Source: $source_file"
                        
                        # Show other matches if more than one
                        if [ "$(wc -l < "$TMP_FOUND_FILES")" -gt 1 ]; then
                            echo "  Other possible matches:"
                            tail -n +2 "$TMP_FOUND_FILES" | sed 's/^/    /'
                        fi
                    fi
                    
                    # Restore the file
                    restore_file "$source_file" "$clean_path"
                    
                    case $? in
                        0) restored_count=$((restored_count + 1)) ;;
                        2) skipped_count=$((skipped_count + 1)) ;;
                    esac
                fi
            else
                not_found_count=$((not_found_count + 1))
                if [ "$DRY_RUN" = true ]; then
                    echo "# NOT FOUND: $filename in entire snapshot"
                else
                    echo "  NOT FOUND: $filename in entire snapshot"
                fi
            fi
        fi
    done < "$TMP_FILE_LIST"
    
    # Clear progress line
    echo -ne "\033[K"
    
    # Print summary
    echo
    if [ "$DRY_RUN" = true ]; then
        echo "# DRY RUN Summary:"
        echo "# Total files processed: $total_count"
        echo "# Files found: $found_count"
        echo "# Files not found: $not_found_count"
        echo "# Files that would be restored: $restored_count"
        echo "# Files that would be skipped (already exist): $skipped_count"
        echo "#"
        echo "# No changes were made to your filesystem."
    else
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        
        echo "Restoration Summary:"
        echo "  Total files processed: $total_count"
        echo "  Files found: $found_count"
        echo "  Files not found: $not_found_count"
        echo "  Files successfully restored: $restored_count"
        echo "  Files skipped (already exist): $skipped_count"
        echo "  Time elapsed: ${elapsed}s"
        
        # Calculate percentages if total count is non-zero
        if [ "$total_count" -gt 0 ]; then
            local found_percent=$((found_count * 100 / total_count))
            local restored_percent=$((restored_count * 100 / total_count))
            echo "  Found percentage: ${found_percent}%"
            echo "  Restored percentage: ${restored_percent}%"
            
            # Calculate throughput
            if [ $elapsed -gt 0 ]; then
                echo "  Throughput: approximately $((total_count / elapsed)) files/second"
            fi
        fi
        
        # Log the results
        local log_file="snapshot-restore-$(date +%Y%m%d-%H%M%S).log"
        {
            echo "Restoration Summary"
            echo "  Date: $(date)"
            echo "  Total files processed: $total_count"
            echo "  Files found: $found_count"
            echo "  Files not found: $not_found_count"
            echo "  Files successfully restored: $restored_count"
            echo "  Files skipped (already exist): $skipped_count"
            echo "  Time elapsed: ${elapsed}s"
        } > "$log_file"
        
        echo "Results saved to $log_file"
    fi
}

# Parse command line arguments
main() {
    local file_list=""
    
    check_requirements
    
    while [ $# -gt 0 ]; do
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
            -S|--search-path)
                SEARCH_PATH="$2"
                shift 2
                ;;
            -f|--file-list)
                file_list="$2"
                shift 2
                ;;
            -p|--parallel)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            -D|--max-depth)
                MAX_DEPTH="$2"
                shift 2
                ;;
            -r|--dry-run)
                DRY_RUN=true
                shift
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
    
    # Confirmation prompt unless in dry-run mode
    if [ "$DRY_RUN" = false ]; then
        echo "This will attempt to restore files from snapshot to /mnt/$MOUNT_POINT/"
        echo -n "Continue? (y/n): "
        read -r confirm
        if [ ! "$confirm" = "y" ] && [ ! "$confirm" = "Y" ]; then
            echo "Operation cancelled."
            exit 0
        fi
    fi
    
    restore_files "$file_list"
}

# Call main with all script arguments
main "$@"