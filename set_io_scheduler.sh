#!/bin/bash

# Path to the device's queue scheduler
SCHEDULER_PATH="/sys/block/${1}/queue/scheduler"

# Check if the scheduler file exists and set it to 'none'
if [ -f "$SCHEDULER_PATH" ]; then
    echo "none" > "$SCHEDULER_PATH"
fi

