#!/bin/bash

# Script to output the image name for all instances with names matching "ws-*"

# Set up error handling
set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

echo "Fetching all 'ws-*' instances..."
INSTANCES=$(gcloud compute instances list --filter="name~^ws-.*" --format="json" | jq -r '.[].name')

# Check if any instances were found
if [ -z "$INSTANCES" ]; then
  echo "No instances matching 'ws-*' were found."
  exit 0
fi

# Print header
printf "%-30s %-20s %-50s\n" "INSTANCE_NAME" "ZONE" "IMAGE_NAME"
printf "%-30s %-20s %-50s\n" "-------------" "----" "----------"

# Process each instance
echo "$INSTANCES" | while read -r INSTANCE; do
  # Get zone of the instance
  ZONE=$(gcloud compute instances list --filter="name=$INSTANCE" --format="value(zone)")

  # Get disk source URI for the boot disk
  DISK_SOURCE_URI=$(gcloud compute instances describe "$INSTANCE" --zone="$ZONE" --format="json" | \
                    jq -r '.disks[] | select(.boot==true) | .source')

  # Get the disk name from the URI
  DISK_NAME=$(echo "$DISK_SOURCE_URI" | awk -F'/' '{print $NF}')

  # Get source image for the disk
  IMAGE_INFO=$(gcloud compute disks describe "$DISK_NAME" --zone="$ZONE" --format="json" | \
               jq -r '.sourceImage // "Custom image (no source)"')

  # Get just the image name from the full path
  IMAGE_NAME=$(echo "$IMAGE_INFO" | awk -F'/' '{print $NF}')

  # Print the result
  printf "%-30s %-20s %-50s\n" "$INSTANCE" "$ZONE" "$IMAGE_NAME"
done
