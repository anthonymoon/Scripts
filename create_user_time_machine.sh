#!/bin/bash

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Check if the user provided an argument
if [ -z "$1" ]; then
    echo "Usage: $0 <username>" >&2
    exit 1
fi

# Check if the user exists
if ! id "$1" &>/dev/null; then
    echo "User '$1' does not exist" >&2
    exit 1
fi

# Define the backup directory
backup_dir="/tank/timemachine/$1"

# Check if the backup directory exists
if [ ! -e "$backup_dir" ]; then
    # Create the backup directory
    mkdir -p "$backup_dir"

    # Set the ownership and permissions
    chown "$1:$1" "$backup_dir"
    chmod 700 "$backup_dir"
else
    echo "Backup directory already exists for user '$1': $backup_dir" >&2
    exit 1
fi

exit 0
