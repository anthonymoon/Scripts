#!/bin/bash

# Define the directory and output files
DIR="/usr/local/bin"
OUTPUT_FILE="${DIR}/system-info-capture.log"
DIFF_FILE="${DIR}/diff-output.txt"

# Function to remove timestamps
remove_timestamps() {
    sed -r 's/[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [a-zA-Z]+//g' | \
    sed -r 's/[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}//g' | \
    sed -r 's/[0-9]+\.[0-9]+\.[0-9]+-zen[0-9]+-[0-9]+-zen #1 ZEN SMP PREEMPT_DYNAMIC [A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}//g'
}

# Start capturing output
{
echo "Journalctl warnings:"
journalctl -b -p warning | remove_timestamps

echo -e "\nLstopo:"
lstopo | remove_timestamps

echo -e "\nLspci (excluding Intel):"
lspci | grep -iv intel | remove_timestamps

echo -e "\nDRM Device:"
cat /sys/class/drm/card0/device/uevent | remove_timestamps

echo -e "\n/proc/iomem:"
cat /proc/iomem | remove_timestamps

echo -e "\n/proc/ioports:"
cat /proc/ioports | remove_timestamps

echo -e "\nSystemd-analyze critical-chain:"
systemd-analyze critical-chain | remove_timestamps

echo -e "\nBoot VGA Devices:"
for i in $(ls /sys/bus/pci/devices/*/boot_vga); do
    echo "$i:"
    cat $i
done | remove_timestamps

echo -e "\nLoginctl list-sessions:"
loginctl list-sessions | remove_timestamps

echo -e "\nSensors:"
sensors | remove_timestamps

echo -e "\nNvidia-smi:"
nvidia-smi | remove_timestamps

echo -e "\nBlock Devices' Scheduler:"
cat /sys/block/*/queue/scheduler | remove_timestamps

echo -e "\nLshw - Memory:"
lshw -short -C memory | remove_timestamps

echo -e "\nTuned-adm active:"
tuned-adm active | remove_timestamps

echo -e "\nUname -rv:"
uname -rv | remove_timestamps

echo -e "\nLspci -vv:"
lspci -vv | remove_timestamps

# Add additional commands as needed
} > $OUTPUT_FILE

# Navigate to the script directory
cd $DIR

# Initialize git repository if it doesn't exist
if [ ! -d ".git" ]; then
    git init
    git add .
    git commit -m "Initial commit"
fi

# Add changes to git
git add system-info-capture.log

# Commit changes if there are any
if git diff --cached --exit-code > /dev/null; then
    echo "No changes to commit."
else
    git commit -m "Update system info capture log"
    # Check for changes and output to DIFF_FILE
    git diff HEAD~1 HEAD > $DIFF_FILE
fi

# Ensure DIFF_FILE is untracked
git reset HEAD $DIFF_FILE

