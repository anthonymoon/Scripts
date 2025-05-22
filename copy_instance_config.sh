#!/bin/bash

# Script to copy all instance configurations from one GCP instance to another (excluding SSH keys)
# Usage: ./copy_instance_config.sh SOURCE_INSTANCE SOURCE_ZONE TARGET_INSTANCE TARGET_ZONE PROJECT_ID

# Check if required parameters are provided
if [ $# -ne 5 ]; then
    echo "Usage: $0 SOURCE_INSTANCE SOURCE_ZONE TARGET_INSTANCE TARGET_ZONE PROJECT_ID"
    echo "Example: $0 flame-02 us-central1-c flame-03 us-central1-a gunpowder-noise"
    exit 1
fi

SOURCE_INSTANCE=$1
SOURCE_ZONE=$2
TARGET_INSTANCE=$3
TARGET_ZONE=$4
PROJECT=$5

echo "Starting copy of instance configuration from $SOURCE_INSTANCE in $SOURCE_ZONE to $TARGET_INSTANCE in $TARGET_ZONE..."

# Create a temporary directory for our work
TEMP_DIR=$(mktemp -d)
CONFIG_FILE="$TEMP_DIR/instance_config.json"

# Get the source instance configuration
echo "Getting configuration for $SOURCE_INSTANCE in $SOURCE_ZONE..."
gcloud compute instances describe $SOURCE_INSTANCE \
    --zone=$SOURCE_ZONE --project=$PROJECT --format=json > $CONFIG_FILE

if [ $? -ne 0 ]; then
    echo "Error: Failed to get configuration for $SOURCE_INSTANCE in $SOURCE_ZONE"
    rm -rf $TEMP_DIR
    exit 1
fi

# Extract configuration parameters
MACHINE_TYPE=$(jq -r '.machineType' $CONFIG_FILE | cut -d'/' -f11)
NETWORK=$(jq -r '.networkInterfaces[0].network' $CONFIG_FILE | cut -d'/' -f9)
SUBNET=$(jq -r '.networkInterfaces[0].subnetwork' $CONFIG_FILE | cut -d'/' -f11 2>/dev/null)
TAGS=$(jq -r '.tags.items | join(",")' $CONFIG_FILE 2>/dev/null)
SERVICE_ACCOUNT=$(jq -r '.serviceAccounts[0].email' $CONFIG_FILE 2>/dev/null)
SCOPES=$(jq -r '.serviceAccounts[0].scopes | join(",")' $CONFIG_FILE 2>/dev/null)

# Process metadata but exclude SSH keys
echo "Processing metadata (excluding SSH keys)..."
METADATA_ITEMS_FILE="$TEMP_DIR/metadata_items.txt"
jq -r '.metadata.items[] | select(.key != "ssh-keys" and .key != "sshKeys") | "\(.key)=\(.value)"' $CONFIG_FILE > $METADATA_ITEMS_FILE

if [ -s "$METADATA_ITEMS_FILE" ]; then
    METADATA=$(cat $METADATA_ITEMS_FILE | paste -sd "," -)
else
    METADATA=""
fi

# Create a snapshot of the source instance's boot disk
BOOT_DISK=$(jq -r '.disks[] | select(.boot == true) | .source' $CONFIG_FILE | cut -d'/' -f11)
SNAPSHOT_NAME="${SOURCE_INSTANCE}-boot-snapshot-$(date +%Y%m%d%H%M%S)"
TARGET_DISK="${TARGET_INSTANCE}-boot-disk"

# Check if target boot disk already exists
echo "Checking if boot disk $TARGET_DISK already exists in $TARGET_ZONE..."
if gcloud compute disks describe $TARGET_DISK --zone=$TARGET_ZONE --project=$PROJECT &>/dev/null; then
    echo "Boot disk $TARGET_DISK already exists in $TARGET_ZONE. Skipping disk creation."
    DISK_CREATED=false
else
    echo "Creating snapshot $SNAPSHOT_NAME from boot disk $BOOT_DISK in $SOURCE_ZONE..."
    gcloud compute disks snapshot $BOOT_DISK \
        --snapshot-names=$SNAPSHOT_NAME \
        --zone=$SOURCE_ZONE --project=$PROJECT

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create snapshot from $BOOT_DISK"
        rm -rf $TEMP_DIR
        exit 1
    fi

    # Create a new disk from the snapshot in the target zone
    echo "Creating new disk $TARGET_DISK from snapshot $SNAPSHOT_NAME in $TARGET_ZONE..."
    gcloud compute disks create $TARGET_DISK \
        --source-snapshot=$SNAPSHOT_NAME \
        --zone=$TARGET_ZONE --project=$PROJECT

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create disk from snapshot"
        rm -rf $TEMP_DIR
        exit 1
    fi
    DISK_CREATED=true
fi

# Check if target instance already exists
echo "Checking if instance $TARGET_INSTANCE already exists in $TARGET_ZONE..."
if gcloud compute instances describe $TARGET_INSTANCE --zone=$TARGET_ZONE --project=$PROJECT &>/dev/null; then
    echo "Instance $TARGET_INSTANCE already exists in $TARGET_ZONE. Skipping instance creation."
else
    # Create the target instance in the target zone
    echo "Creating target instance $TARGET_INSTANCE in $TARGET_ZONE..."

    # Build the create command with all the configuration parameters
    CREATE_CMD="gcloud compute instances create $TARGET_INSTANCE \
        --zone=$TARGET_ZONE \
        --project=$PROJECT \
        --machine-type=$MACHINE_TYPE \
        --disk=name=$TARGET_DISK,boot=yes,auto-delete=yes"

    # Add conditional parameters if they exist
    if [ ! -z "$NETWORK" ]; then
        if [ ! -z "$SUBNET" ]; then
            CREATE_CMD="$CREATE_CMD --network-interface=network=$NETWORK,subnet=$SUBNET"
        else
            CREATE_CMD="$CREATE_CMD --network=$NETWORK"
        fi
    fi

    if [ ! -z "$TAGS" ]; then
        CREATE_CMD="$CREATE_CMD --tags=$TAGS"
    fi

    if [ ! -z "$SERVICE_ACCOUNT" ] && [ ! -z "$SCOPES" ]; then
        CREATE_CMD="$CREATE_CMD --service-account=$SERVICE_ACCOUNT --scopes=$SCOPES"
    fi

    if [ ! -z "$METADATA" ]; then
        CREATE_CMD="$CREATE_CMD --metadata=$METADATA"
    fi

    # Execute the command
    eval $CREATE_CMD

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create instance $TARGET_INSTANCE"
        rm -rf $TEMP_DIR
        exit 1
    fi
fi

# Process additional disks (non-boot disks)
echo "Processing additional disks..."
jq -r '.disks[] | select(.boot == false)' $CONFIG_FILE > "$TEMP_DIR/additional_disks.json"

if [ -s "$TEMP_DIR/additional_disks.json" ]; then
    while read -r disk_json; do
        DISK_NAME=$(echo $disk_json | jq -r '.source' | cut -d'/' -f11)
        DISK_MODE=$(echo $disk_json | jq -r '.mode')
        DISK_AUTO_DELETE=$(echo $disk_json | jq -r '.autoDelete')

        ADD_TARGET_DISK="${TARGET_INSTANCE}-${DISK_NAME}"

        # Check if additional disk already exists
        echo "Checking if disk $ADD_TARGET_DISK already exists in $TARGET_ZONE..."
        if gcloud compute disks describe $ADD_TARGET_DISK --zone=$TARGET_ZONE --project=$PROJECT &>/dev/null; then
            echo "Disk $ADD_TARGET_DISK already exists in $TARGET_ZONE. Skipping disk creation."
        else
            # Create snapshot for this disk
            ADD_SNAPSHOT_NAME="${DISK_NAME}-snapshot-$(date +%Y%m%d%H%M%S)"

            echo "Creating snapshot $ADD_SNAPSHOT_NAME from disk $DISK_NAME in $SOURCE_ZONE..."
            gcloud compute disks snapshot $DISK_NAME \
                --snapshot-names=$ADD_SNAPSHOT_NAME \
                --zone=$SOURCE_ZONE --project=$PROJECT

            echo "Creating new disk $ADD_TARGET_DISK from snapshot $ADD_SNAPSHOT_NAME in $TARGET_ZONE..."
            gcloud compute disks create $ADD_TARGET_DISK \
                --source-snapshot=$ADD_SNAPSHOT_NAME \
                --zone=$TARGET_ZONE --project=$PROJECT
        fi

        # Check if disk is already attached to the instance
        ALREADY_ATTACHED=$(gcloud compute instances describe $TARGET_INSTANCE --zone=$TARGET_ZONE --project=$PROJECT --format="json" | jq -r --arg disk "$ADD_TARGET_DISK" '.disks[] | select(.source | contains($disk)) | .source' 2>/dev/null)

        if [ -z "$ALREADY_ATTACHED" ]; then
            echo "Attaching disk $ADD_TARGET_DISK to $TARGET_INSTANCE in $TARGET_ZONE..."
            gcloud compute instances attach-disk $TARGET_INSTANCE \
                --disk=$ADD_TARGET_DISK \
                --mode=$DISK_MODE \
                --zone=$TARGET_ZONE --project=$PROJECT
        else
            echo "Disk $ADD_TARGET_DISK is already attached to $TARGET_INSTANCE. Skipping attachment."
        fi
    done < "$TEMP_DIR/additional_disks.json"
fi

# Clean up temporary files
rm -rf $TEMP_DIR

echo "Instance configuration successfully copied from $SOURCE_INSTANCE ($SOURCE_ZONE) to $TARGET_INSTANCE ($TARGET_ZONE)"
echo "SSH keys were excluded from the copy process."
echo "Note: Network interfaces, IP addresses, and some instance-specific configurations may need manual adjustment."
