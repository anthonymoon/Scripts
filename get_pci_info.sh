#!/bin/bash

# Ensure the script is run with root privileges
if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root" >&2
	exit 1
fi

# Use lspci with verbose output to get information
lspci_output=$(sudo lspci -vv)

# Extract and print the required information
echo "Physical Slot, PCIe Link Capabilities, and Link Speed:"

# Assuming the relevant lines are prefixed with 'PhySlot:', 'LnkCap:', and 'LnkSta:', respectively
echo "$lspci_output" | awk '
/PhySlot:/ {slot = $0}
/LnkCap:/ {cap = $0}
/LnkSta:/ {
  speed = $0
  print slot
  print cap
  print speed
  print "-----"
  slot = ""; cap = ""; speed = ""
}'
