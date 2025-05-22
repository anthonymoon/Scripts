#!/bin/bash

# Define the paths for the service and the shutdown script
SERVICE_PATH="/etc/systemd/system/shutdown-vms.service"
SCRIPT_PATH="/usr/local/bin/shutdown-all-vms.sh"

# Check if the script is run as root, exit if not
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root."
	exit 1
fi

# Create the systemd service file
cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=Gracefully shut down all running VMs
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/bin/true
ExecStop=$SCRIPT_PATH
RemainAfterExit=yes
TimeoutStartSec=0
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target halt.target reboot.target shutdown.target
EOF

# Create the shutdown script
cat >"$SCRIPT_PATH" <<'EOF'
#!/bin/bash

logger -p daemon.info "Starting graceful shutdown of all running VMs."

# Helper function to check if a VM is still running
is_vm_running() {
  virsh list --name | grep -qw "$1"
}

# Helper function to attempt shutdown with various methods
shutdown_vm() {
  local VM_NAME="$1"
  local MAX_ATTEMPTS=5
  local SLEEP_DURATION=5
  local attempt=1

  while is_vm_running "$VM_NAME"; do
    if [ $attempt -gt $MAX_ATTEMPTS ]; then
      logger -p daemon.err "Unable to gracefully shut down $VM_NAME after $MAX_ATTEMPTS attempts. Proceeding to force shutdown."
      virsh destroy "$VM_NAME"
      break
    fi

    logger -p daemon.info "Shutdown attempt $attempt for $VM_NAME using method $attempt"
    case $attempt in
      1) virsh shutdown "$VM_NAME" --mode acpi ;;
      2) virsh shutdown "$VM_NAME" --mode agent ;;
      3) virsh shutdown "$VM_NAME" --mode initctl ;;
      4) virsh shutdown "$VM_NAME" --mode signal ;;
      5) virsh shutdown "$VM_NAME" --mode paravirt ;;
    esac

    sleep $SLEEP_DURATION
    ((attempt++))
  done

  if is_vm_running "$VM_NAME"; then
    logger -p daemon.err "Forceful shutdown failed for $VM_NAME. Manual intervention may be required."
  else
    logger -p daemon.info "$VM_NAME has been successfully shut down."
  fi
}

# Loop through all running VMs and attempt to shut them down gracefully
virsh list --state-running --name | while read -r VM; do
  shutdown_vm "$VM"
done

logger -p daemon.info "Completed shutdown of all running VMs."
EOF
