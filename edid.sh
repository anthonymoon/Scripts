#!/bin/bash

# Set up variables
EDID_DIR="$HOME/.local/share/edid-monitor"
CURRENT_FILE="$EDID_DIR/current_edid.txt"
PREVIOUS_FILE="$EDID_DIR/previous_edid.txt"
LOG_FILE="$EDID_DIR/changes.log"

# Create directory if it doesn't exist
mkdir -p "$EDID_DIR"

# Run lunar edid command and save to temporary file
TEMP_FILE=$(mktemp)
sudo lunar edid | tee "$TEMP_FILE" >/dev/null 2>&1

# Check if lunar command was successful
if ! sudo lunar edid >/dev/null 2>&1; then
  echo "Error: 'lunar edid' command failed. Make sure lunar is installed and you have proper permissions."
  rm "$TEMP_FILE"
  exit 1
fi

# If this is the first run, save the file and exit
if [ ! -f "$CURRENT_FILE" ]; then
  echo "First run detected. Saving current EDID information."
  cp "$TEMP_FILE" "$CURRENT_FILE"
  rm "$TEMP_FILE"
  echo "Initial EDID information saved to $CURRENT_FILE"
  exit 0
fi

# Move current to previous if they're different
if ! cmp -s "$TEMP_FILE" "$CURRENT_FILE"; then
  # Files are different
  echo "Changes detected in EDID information!"

  # Save previous version
  cp "$CURRENT_FILE" "$PREVIOUS_FILE"

  # Update current version
  cp "$TEMP_FILE" "$CURRENT_FILE"

  # Log the change with timestamp
  TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

  # Group redirects to avoid multiple redirects to same file
  {
    echo "=== EDID changes detected at $TIMESTAMP ==="
    diff -u "$PREVIOUS_FILE" "$CURRENT_FILE"
    echo -e "\n\n"
  } >> "$LOG_FILE"

  echo "Previous EDID saved to $PREVIOUS_FILE"
  echo "Current EDID saved to $CURRENT_FILE"
  echo "Differences logged to $LOG_FILE"
else
  echo "No changes detected in EDID information."
fi

# Clean up
rm "$TEMP_FILE"

echo "Done."
