
#!/bin/bash

# This script sets up 10 TAP interfaces (tap0 - tap9), adds them to an existing bridge (virbr0), 
# and enables promiscuous mode on each interface.

BRIDGE=virbr0
TAP_COUNT=10

# Check if run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Function to create, setup, and enable promiscuous mode on a tap interface
create_tap() {
    local tap_name=$1
    ip tuntap add dev $tap_name mode tap
    ip link set $tap_name up
    ip link set $tap_name master $BRIDGE
    ip link set $tap_name promisc on  # Enable promiscuous mode
}

# Create and setup TAP interfaces
for i in $(seq 0 $(($TAP_COUNT - 1))); do
    create_tap "tap$i"
done

# Cleanup function to remove interfaces
cleanup() {
    for i in $(seq 0 $(($TAP_COUNT - 1))); do
        ip link set "tap$i" promisc off  # Disable promiscuous mode
        ip link delete "tap$i"
    done
}

# Trap script exit for cleanup
#trap cleanup EXIT

