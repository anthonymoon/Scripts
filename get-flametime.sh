#!/bin/bash

# Output file to save results
OUTPUT_FILE="flame_boot_times.txt"
true > "$OUTPUT_FILE"  # Clear file if it exists - fixed SC2188

# Get the list of all running flame-* instances
echo "Finding running instances with names like 'flame-'..."
FLAME_INSTANCES=$(gcloud compute instances list --filter="name~'flame-' AND status=RUNNING" --format="csv[no-heading](name)")

# Check if we found any instances
if [[ -z "$FLAME_INSTANCES" ]]; then
  echo "No running instances with names like 'flame-' found."
  exit 1
fi

# Count the instances
INSTANCE_COUNT=$(echo "$FLAME_INSTANCES" | wc -l)
echo "Found $INSTANCE_COUNT running flame instances."
echo "Starting to collect systemd-analyze time data..."

# Counter for progress tracking
COUNTER=0

# Loop through each instance
echo "$FLAME_INSTANCES" | while read -r instance; do
  COUNTER=$((COUNTER + 1))
  echo "[$COUNTER/$INSTANCE_COUNT] Processing $instance..."
  
  # Echo instance name to the output file
  echo "===== $instance =====" >> "$OUTPUT_FILE"
  
  # Connect via SSH and run the command
  # Using timeout to prevent hanging if SSH connection fails
  if timeout 30s ssh "$instance.vs.parliament.com" -l anthonym "sudo systemd-analyze time" >> "$OUTPUT_FILE" 2>&1; then
    # Fixed SC2181 by checking the exit code directly
    echo "  Success - Data collected"
  else
    echo "  Failed to connect or run command on $instance" 
    echo "  Failed to connect or run command" >> "$OUTPUT_FILE"
  fi
  
  # Add a separator (fixed SC2129 by combining outputs)
  {
    echo ""
    echo "-----------------------------------------"
    echo ""
  } >> "$OUTPUT_FILE"
  
  # Small delay to avoid overwhelming the network
  sleep 1
done

echo "Done! Results saved to $OUTPUT_FILE"
echo "You can view the results with: cat $OUTPUT_FILE"

# Optional: Show a summary of the slowest booting instances
echo ""
echo "Summary of boot times (sorted from slowest to fastest):"
grep "systemd" "$OUTPUT_FILE" | sort -r | head -10