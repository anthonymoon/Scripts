#!/bin/bash
#
# snapshot-restore.sh - Restore files from snapshots using hard links
#
# This script allows users to restore files from snapshots by creating hard links.
# The user can choose which snapshot to restore from and whether to recreate the 
# original path structure or restore to a new location.

set -euo pipefail

# Default snapshot directory
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/snapshots}"

# Auto-detect flag
AUTO_DETECT_SNAPSHOTS=false

# Dry-run flag - show what would be done without actually doing it
DRY_RUN=false

# Print usage information
usage() {
    echo "Usage: $0 [options] file1 [file2 ...]"
    echo
    echo "Options:"
    echo "  -s, --snapshot-dir DIR   Specify snapshots directory (default: auto-detected)"
    echo "  -d, --destination DIR    Specify destination directory for restored files"
    echo "  -f, --file-list FILE     Read list of files to restore from FILE (one file per line)"
    echo "  -a, --auto-detect        Automatically detect snapshot directories on all mounts"
    echo "  -r, --dry-run            Show what would be done without making any changes"
    echo "  -h, --help               Show this help message"
    echo
    echo "Examples:"
    echo "  Snapshot path format:    /mnt/storage/.snapshots/@GMT-2025.05.14-00.00.00/path/to/file.txt"
    echo "  Original file path:      /mnt/storage/path/to/file.txt"
    echo
    echo "If destination is not specified, files will be restored to their original paths."
    exit 1
}

# Check if required commands exist
check_requirements() {
    local missing=0
    for cmd in find ln realpath df; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' command not found"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

# Discover snapshot directories on all mounted filesystems
discover_snapshots() {
    local snapshot_dirs=()
    local counter=1
    
    echo "Searching for snapshot directories on all mounted filesystems..."
    
    # Get a list of mounted filesystems
    local mounts
    mounts=$(df -T | awk 'NR>1 {print $7}')
    
    for mount in $mounts; do
        # Check different snapshot directory patterns
        local snapshot_paths=()
        
        # NetApp style snapshots (prioritize these)
        snapshot_paths+=("$mount/.snapshots")
        snapshot_paths+=("$mount/.snapshot")
        
        # Mount pattern variations
        local mount_name
        mount_name=$(basename "$mount")
        snapshot_paths+=("/mnt/$mount_name/.snapshots")
        snapshot_paths+=("/mnt/$mount_name/.snapshot")
        
        for path in "${snapshot_paths[@]}"; do
            if [[ -d "$path" && ! " ${snapshot_dirs[*]:-} " =~ " $path " ]]; then
                echo "Found snapshot directory: $path"
                snapshot_dirs+=("$path")
            fi
        done
    done
    
    if [ ${#snapshot_dirs[@]} -eq 0 ]; then
        echo "No snapshot directories found on mounted filesystems."
        exit 1
    fi
    
    # Display and let user select a snapshot directory
    echo
    echo "Available snapshot directories:"
    counter=1
    for dir in "${snapshot_dirs[@]}"; do
        echo "$counter) $dir"
        ((counter++))
    done
    
    echo
    echo -n "Select snapshot directory number (1-${#snapshot_dirs[@]}): "
    read -r selection
    
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#snapshot_dirs[@]} ]; then
        echo "Error: Invalid selection."
        exit 1
    fi
    
    SNAPSHOT_DIR="${snapshot_dirs[$((selection-1))]}"
    echo "Selected snapshot directory: $SNAPSHOT_DIR"
    
    # Ensure we're working with the correct snapshot path format
    if [[ "$SNAPSHOT_DIR" != *".snapshots" ]] && [[ "$SNAPSHOT_DIR" != *".snapshot" ]]; then
        echo "Warning: Selected directory doesn't follow the expected snapshot naming pattern."
        echo "Expected patterns: /path/.snapshots or /path/.snapshot"
    fi
}

# List available snapshots
list_snapshots() {
    if [ "$AUTO_DETECT_SNAPSHOTS" = true ]; then
        discover_snapshots
    fi
    
    if [ ! -d "$SNAPSHOT_DIR" ]; then
        echo "Error: Snapshot directory '$SNAPSHOT_DIR' does not exist."
        exit 1
    fi
    
    echo "Available snapshots:"
    
    local snapshots=()
    local counter=1
    
    # Check if we're at the .snapshots or .snapshot level
    # If so, we need to look for @GMT-* directories
    if [[ "$(basename "$SNAPSHOT_DIR")" == ".snapshots" ]] || [[ "$(basename "$SNAPSHOT_DIR")" == ".snapshot" ]]; then
        echo "Looking for NetApp-style snapshots (@GMT-*)..."
        
        # Use find to locate snapshot directories and sort them by name
        while IFS= read -r snapshot; do
            # Only include directories matching NetApp naming pattern
            if [[ "$(basename "$snapshot")" =~ ^@GMT-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}$ ]]; then
                snapshots+=("$snapshot")
                echo "$counter) $(basename "$snapshot")"
                ((counter++))
            fi
        done < <(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
        
        # If no NetApp snapshots found, try all directories
        if [ ${#snapshots[@]} -eq 0 ]; then
            echo "No NetApp-style snapshots found, listing all directories..."
            while IFS= read -r snapshot; do
                snapshots+=("$snapshot")
                echo "$counter) $(basename "$snapshot")"
                ((counter++))
            done < <(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
        fi
    else
        # Standard directory listing
        while IFS= read -r snapshot; do
            snapshots+=("$snapshot")
            echo "$counter) $(basename "$snapshot")"
            ((counter++))
        done < <(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    fi
    
    if [ ${#snapshots[@]} -eq 0 ]; then
        echo "No snapshots found in '$SNAPSHOT_DIR'."
        exit 1
    fi
    
    # Let user select snapshot
    local selection
    echo
    echo -n "Select snapshot number (1-${#snapshots[@]}): "
    read -r selection
    
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#snapshots[@]} ]; then
        echo "Error: Invalid selection."
        exit 1
    fi
    
    SELECTED_SNAPSHOT="${snapshots[$((selection-1))]}"
    echo "Selected snapshot: $(basename "$SELECTED_SNAPSHOT")"
}

# Construct NetApp-style path for a file
get_netapp_path() {
    local file="$1"
    local mount_point
    local rel_path
    
    # Find the mount point for this file
    mount_point=$(df -P "$file" 2>/dev/null | awk 'NR==2 {print $6}')
    
    if [ -z "$mount_point" ]; then
        # If file doesn't exist, try to find the closest parent directory
        local parent_dir="$file"
        while [ ! -d "$parent_dir" ] && [ "$parent_dir" != "/" ]; do
            parent_dir=$(dirname "$parent_dir")
        done
        
        if [ "$parent_dir" = "/" ]; then
            echo "Error: Could not determine mount point for '$file'"
            return 1
        fi
        
        mount_point=$(df -P "$parent_dir" 2>/dev/null | awk 'NR==2 {print $6}')
        
        if [ -z "$mount_point" ]; then
            echo "Error: Could not determine mount point for '$file'"
            return 1
        fi
    fi
    
    # Get the relative path from the mount point
    rel_path=${file#"$mount_point"}
    
    # Return source file path in NetApp format
    echo "${SELECTED_SNAPSHOT}${rel_path}"
    
    return 0
}

# Restore files
restore_files() {
    local files=("$@")
    local file_count=0
    local success_count=0
    
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Showing what would be done without making changes"
        echo "===========================================================" 
    fi
    
    for file in "${files[@]}"; do
        local source_file
        local target_file
        
        ((file_count++))
        
        if [[ "$file" = /* ]]; then
            # Handle absolute paths using NetApp-style path mapping
            source_file=$(get_netapp_path "$file")
            if [ $? -ne 0 ]; then
                echo "$source_file"  # Error message from get_netapp_path
                continue
            fi
            
            if [ -n "$DEST_DIR" ]; then
                target_file="${DEST_DIR}${file}"
            else
                target_file="$file"
            fi
        else
            # Handle relative paths
            local abs_file
            abs_file="$(pwd)/${file}"
            
            # Use NetApp-style snapshots with relative paths
            source_file=$(get_netapp_path "$abs_file")
            if [ $? -ne 0 ]; then
                echo "$source_file"  # Error message from get_netapp_path
                continue
            fi
            
            if [ -n "$DEST_DIR" ]; then
                target_file="${DEST_DIR}/$(realpath --relative-to=/ "$(pwd)")/${file}"
            else
                target_file="$(pwd)/${file}"
            fi
        fi
        
        # Check if source file exists
        if [ ! -f "$source_file" ]; then
            echo "Error: File '$file' not found in selected snapshot at: $source_file"
            continue
        fi
        
        # Handle target directory creation
        target_dir=$(dirname "$target_file")
        if [ ! -d "$target_dir" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo "Would create directory: $target_dir"
            else
                mkdir -p "$target_dir"
                echo "Created directory: $target_dir"
            fi
        fi
        
        # Alert if file exists but never remove it
        if [ -f "$target_file" ]; then
            echo "WARNING: File already exists at: $target_file"
            echo "         Skipping restoration for this file."
            continue
        fi
        
        # Create hard link or show what would be done
        if [ "$DRY_RUN" = true ]; then
            echo "Would restore: $file"
            echo "  From: $source_file"
            echo "  To:   $target_file"
            ((success_count++))
        else
            # Actually create the hard link
            if ln "$source_file" "$target_file"; then
                echo "Restored: $file -> $target_file"
                ((success_count++))
            else
                echo "Failed to restore: $file"
            fi
        fi
    done
    
    echo
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN Summary:"
        echo "  Total files that would be processed: $file_count"
        echo "  Files that would be successfully restored: $success_count"
        echo "  Files that would fail: $((file_count - success_count))"
        echo
        echo "No changes were made to your filesystem."
    else
        echo "Restoration summary:"
        echo "  Total files: $file_count"
        echo "  Successfully restored: $success_count"
        echo "  Failed: $((file_count - success_count))"
    fi
}

# Read file list from file
read_file_list() {
    local file_list="$1"
    local files=()
    
    if [ ! -f "$file_list" ]; then
        echo "Error: File list '$file_list' not found."
        exit 1
    fi
    
    # Get snapshot parent directory to use for relative paths
    local snapshot_parent=""
    if [[ "$SNAPSHOT_DIR" == *"/.snapshots"* ]] || [[ "$SNAPSHOT_DIR" == *"/.snapshot"* ]]; then
        snapshot_parent=$(dirname "$(dirname "$SNAPSHOT_DIR")")
    fi
    
    while IFS= read -r line || [ -n "${line:-}" ]; do
        # Skip empty lines and comments
        if [ -n "${line:-}" ] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
            # If path doesn't start with / and we have a snapshot parent, prepend it
            if [[ ! "$line" = /* ]] && [ -n "$snapshot_parent" ]; then
                line="${snapshot_parent}/${line}"
                echo "Auto-corrected path to: $line"
            # If path doesn't include the snapshot parent (but has /) and we know the parent, add it
            elif [[ "$line" = /* ]] && [ -n "$snapshot_parent" ] && [[ ! "$line" = ${snapshot_parent}/* ]]; then
                # Get just the path component after the first directory
                local no_leading_path="${line#/*/}"
                if [[ "$no_leading_path" != "$line" ]]; then
                    line="${snapshot_parent}/${no_leading_path}"
                    echo "Auto-corrected path to: $line"
                fi
            fi
            files+=("$line")
        fi
    done < "$file_list"
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "Error: No files found in file list '$file_list'."
        exit 1
    fi
    
    echo "Read ${#files[@]} files from '$file_list'."
    FILES+=("${files[@]}")
    # Keep track of which files came from the file list
    read_files+=("${files[@]}")
}

# Main script execution
main() {
    # Parse command line arguments
    DEST_DIR=""
    FILES=()
    read_files=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--snapshot-dir)
                SNAPSHOT_DIR="$2"
                shift 2
                ;;
            -d|--destination)
                DEST_DIR="$2"
                shift 2
                ;;
            -f|--file-list)
                read_file_list "$2"
                shift 2
                ;;
            -a|--auto-detect)
                AUTO_DETECT_SNAPSHOTS=true
                shift
                ;;
            -r|--dry-run)
                DRY_RUN=true
                echo "Dry run mode enabled - no changes will be made"
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                echo "Error: Unknown option $1"
                usage
                ;;
            *)
                FILES+=("$1")
                shift
                ;;
        esac
    done

    check_requirements

    if [ ${#FILES[@]} -eq 0 ]; then
        echo "Error: No files specified."
        usage
    fi
    
    # Auto-correct file paths for command line arguments
    # Get snapshot parent directory to use for relative paths
    if [ -z "$SNAPSHOT_DIR" ] || [[ ! "$SNAPSHOT_DIR" = /* ]]; then
        echo "Error: Invalid snapshot directory path. Must be an absolute path."
        exit 1
    fi
    
    local snapshot_parent=""
    if [[ "$SNAPSHOT_DIR" == *"/.snapshots"* ]] || [[ "$SNAPSHOT_DIR" == *"/.snapshot"* ]]; then
        snapshot_parent=$(dirname "$(dirname "$SNAPSHOT_DIR")")
    fi
    
    if [ -n "$snapshot_parent" ]; then
        local corrected_files=()
        for file in "${FILES[@]}"; do
            # Skip files from file list, they've already been processed
            # Only correct command-line arguments
            if [[ " ${read_files[*]:-} " != *" $file "* ]]; then
                # If path doesn't start with / and we have a snapshot parent, prepend it
                if [[ ! "$file" = /* ]] && [ -n "$snapshot_parent" ]; then
                    file="${snapshot_parent}/${file}"
                    echo "Auto-corrected path to: $file"
                # If path doesn't include the snapshot parent (but has /) and we know the parent, add it
                elif [[ "$file" = /* ]] && [ -n "$snapshot_parent" ] && [[ ! "$file" = ${snapshot_parent}/* ]]; then
                    # Get just the path component after the first directory
                    local no_leading_path="${file#/*/}"
                    if [[ "$no_leading_path" != "$file" ]]; then
                        file="${snapshot_parent}/${no_leading_path}"
                        echo "Auto-corrected path to: $file"
                    fi
                fi
            fi
            corrected_files+=("$file")
        done
        # Replace original file list with corrected ones
        FILES=("${corrected_files[@]}")
    fi

    list_snapshots

    # If destination directory is specified, verify it's on the same filesystem as the snapshot directory
    if [ -n "$DEST_DIR" ]; then
        # Extract the parent path from the snapshot directory (one level up from .snapshots/@GMT-*)
        SNAPSHOT_PARENT=$(dirname "$(dirname "$SNAPSHOT_DIR")")
        
        # Check if destination is on the same filesystem
        SNAPSHOT_FSID=$(stat -f -c "%i" "$SNAPSHOT_PARENT" 2>/dev/null || stat -f "%i" "$SNAPSHOT_PARENT" 2>/dev/null)
        DEST_FSID=$(stat -f -c "%i" "$DEST_DIR" 2>/dev/null || stat -f "%i" "$DEST_DIR" 2>/dev/null)
        
        if [ -z "$SNAPSHOT_FSID" ] || [ -z "$DEST_FSID" ]; then
            echo "Error: Could not determine filesystem ID for one of the directories."
            echo "This could mean the directory doesn't exist or is not accessible."
            exit 1
        fi
        
        if [ "$SNAPSHOT_FSID" != "$DEST_FSID" ]; then
            echo "Error: Destination directory is on a different filesystem than the snapshot directory."
            echo "Cannot create hard links across different filesystems."
            echo "Snapshot parent: $SNAPSHOT_PARENT (fs id: $SNAPSHOT_FSID)"
            echo "Destination: $DEST_DIR (fs id: $DEST_FSID)"
            exit 1
        fi
        
        if [ ! -d "$DEST_DIR" ] && [ "$DRY_RUN" = false ]; then
            echo "Creating destination directory: $DEST_DIR"
            mkdir -p "$DEST_DIR"
        elif [ ! -d "$DEST_DIR" ] && [ "$DRY_RUN" = true ]; then
            echo "Would create destination directory: $DEST_DIR"
        fi
        echo "Files will be restored to: $DEST_DIR"
    else
        echo "Files will be restored to their original paths."
    fi

    echo
    echo "The following files will be restored:"
    for file in "${FILES[@]}"; do
        echo "  $file"
    done

    if [ "$DRY_RUN" = true ]; then
        # In dry-run mode, proceed without confirmation
        echo
        echo "Running in dry-run mode - showing what would happen without making changes"
        restore_files "${FILES[@]}"
    else
        # In normal mode, ask for confirmation
        echo
        echo -n "Proceed with restoration? (y/n): "
        read -r confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            restore_files "${FILES[@]}"
        else
            echo "Restoration cancelled."
            exit 0
        fi
    fi
}

# Call main with all script arguments
main "$@"