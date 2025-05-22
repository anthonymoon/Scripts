#!/bin/bash

# Script to terminate instances and change boot disk interfaces from NVME to SCSI
# For specific instances in the provided list

# Set up error handling
set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

# Define log file
LOGFILE="disk_conversion_$(date +%Y%m%d_%H%M%S).log"
echo "Starting disk conversion process at $(date)" > "$LOGFILE"

# Function to log messages
log() {
  echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1" | tee -a "$LOGFILE"
}

# Define the specific list of instances to process
# Define the list of instances directly
INSTANCES=(
"ws-01"
"ws-livestudio-10"
"ws-livstudio-01"
"ws-livstudio-02"
"ws-livstudio-03"
"ws-livstudio-06"
"ws-livstudio-04"
"ws-livstudio-03"
"ws-social-03"
"ws-promos-06"
"ws-promos-05"
"ws-promos-04"
"ws-promos-03"
"ws-promos-02"
"ws-livstudio-12"
"ws-livstudio-11"
"ws-livstudio-08"
)

# Count total instances for progress tracking
TOTAL_INSTANCES=${#INSTANCES[@]}
CURRENT=0

log "Processing $TOTAL_INSTANCES specified instances."

# Process each instance
for INSTANCE in "${INSTANCES[@]}"; do
  CURRENT=$((CURRENT + 1))
  log "[$CURRENT/$TOTAL_INSTANCES] Processing instance: $INSTANCE"

  # Get zone of the instance
  ZONE=$(gcloud compute instances list --filter="name=$INSTANCE" --format="value(zone)")
  log "Instance $INSTANCE is in zone $ZONE"

  # Get status of the instance
  STATUS=$(gcloud compute instances describe "$INSTANCE" --zone="$ZONE" --format="value(status)")
  log "Current status: $STATUS"

  # Always terminate the instance regardless of current state
  if [ "$STATUS" != "TERMINATED" ]; then
    log "Terminating instance $INSTANCE..."
    gcloud compute instances stop "$INSTANCE" --zone="$ZONE" --quiet
    log "Instance $INSTANCE terminated successfully."
  else
    log "Instance $INSTANCE is already terminated."
  fi

  # Get boot disk information
  BOOT_DISK_INFO=$(gcloud compute instances describe "$INSTANCE" --zone="$ZONE" --format="json" | jq '.disks[] | select(.boot==true)')
  BOOT_DISK_NAME=$(echo "$BOOT_DISK_INFO" | jq -r '.deviceName')
  BOOT_DISK_SOURCE=$(echo "$BOOT_DISK_INFO" | jq -r '.source' | awk -F '/' '{print $NF}')
  BOOT_DISK_AUTO_DELETE=$(echo "$BOOT_DISK_INFO" | jq -r '.autoDelete')

  log "Boot disk: $BOOT_DISK_NAME (source: $BOOT_DISK_SOURCE, auto-delete: $BOOT_DISK_AUTO_DELETE)"

  # Check current interface type to confirm it's NVME
  CURRENT_INTERFACE=$(echo "$BOOT_DISK_INFO" | jq -r '.interface')

  if [ "$CURRENT_INTERFACE" != "NVME" ]; then
    log "Boot disk already uses $CURRENT_INTERFACE interface, not NVME. Skipping."
    continue
  fi

  # Detach the boot disk
  log "Detaching boot disk from $INSTANCE..."
  gcloud compute instances detach-disk "$INSTANCE" --disk="$BOOT_DISK_SOURCE" --zone="$ZONE" --quiet
  log "Boot disk detached successfully."

  # Reattach the disk with SCSI interface as boot disk
  log "Reattaching boot disk with SCSI interface..."
  ATTACH_CMD="gcloud compute instances attach-disk \"$INSTANCE\" --disk=\"$BOOT_DISK_SOURCE\" --device-name=\"$BOOT_DISK_NAME\" --zone=\"$ZONE\" --boot --interface=SCSI"

  # Execute the attach command
  eval "$ATTACH_CMD"

  # Ensure auto-delete is OFF, regardless of previous setting
  log "Ensuring auto-delete is disabled for the disk..."
  gcloud compute instances set-disk-auto-delete "$INSTANCE" --disk="$BOOT_DISK_SOURCE" --zone="$ZONE" --no-auto-delete
  log "Boot disk reattached with SCSI interface."

  # Do not restart the instance, leave it terminated
  log "Instance $INSTANCE will remain terminated as requested."

  log "Successfully processed instance $INSTANCE (changed boot disk interface to SCSI)"
  echo "---------------------------------"
done

log "All instances processed. Please verify the results with:"
log "gcloud compute instances list --filter=\"name:( $(IFS=\| ; echo "${INSTANCES[*]}") )\""
