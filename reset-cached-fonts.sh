#!/bin/bash

# Get a list of all running Google Cloud compute instances with names matching 'nuke-render-*'
echo "Fetching list of running 'nuke-render-*' instances..."
INSTANCES=$(gcloud compute instances list --filter="status=RUNNING AND name~^nuke-render-.*" --format="value(name,zone)")

if [ -z "$INSTANCES" ]; then
  echo "No running 'nuke-render-*' instances found."
  exit 0
fi

# Loop through each matching instance and run fc-cache command
echo "Running fc-cache on each 'nuke-render-*' instance:"
echo "--------------------------------"

# Store the instance info in an array to avoid issues with stdin being consumed
mapfile -t INSTANCE_ARRAY <<< "$INSTANCES"

for instance_info in "${INSTANCE_ARRAY[@]}"; do
  # Extract instance name and zone
  NAME=$(echo "$instance_info" | awk '{print $1}')
  ZONE=$(echo "$instance_info" | awk '{print $2}')

  echo "Instance: $NAME (Zone: $ZONE)"
  echo "Running sudo fc-cache -fv..."

  # SSH into the instance and run the fc-cache command
  gcloud compute ssh --zone="$ZONE" "$NAME" -- "sudo fc-cache -fv"

  echo "--------------------------------"
done

echo "Font cache update completed on all matching 'nuke-render-*' instances."
