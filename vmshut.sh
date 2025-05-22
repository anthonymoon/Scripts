#!/bin/bash

VM_NAME="$1"
MAX_ATTEMPTS=5
SLEEP_DURATION=5

# Function to check if the VM is running
is_vm_running() {
    virsh list --name | grep -q "^$VM_NAME$"
    return $?
}

# Function to attempt shutdown with various methods
shutdown_vm() {
    case $1 in
        1) virsh shutdown "$VM_NAME" --mode acpi ;;
        2) virsh shutdown "$VM_NAME" --mode agent ;;
        3) virsh shutdown "$VM_NAME" --mode initctl ;;
        4) virsh shutdown "$VM_NAME" --mode signal ;;
        5) virsh shutdown "$VM_NAME" --mode paravirt ;;
    esac
}

attempt=1

while is_vm_running; do
    if [ $attempt -gt $MAX_ATTEMPTS ]; then
        echo "Unable to shutdown $VM_NAME after $MAX_ATTEMPTS attempts. Proceeding to force shutdown."
        virsh destroy "$VM_NAME" --graceful
        break
    fi

    echo "Shutdown attempt $attempt using method $attempt"
    shutdown_vm $attempt

    sleep $SLEEP_DURATION
    ((attempt++))
done

if is_vm_running; then
    echo "Forceful shutdown also failed. Consider manually killing the process."
else
    echo "$VM_NAME has been successfully shut down."
fi

