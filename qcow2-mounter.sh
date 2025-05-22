#!/bin/bash

# Check if two arguments were provided
if [ $# -ne 2 ]; then
	echo "Usage: $0 [mount|unmount] /path/to/image.qcow2"
	exit 1
fi

COMMAND="$1"
QCOW2_IMAGE="$2"
MOUNT_POINT="/mnt/$(basename "${QCOW2_IMAGE}" .qcow2)"
NBD_DEVICE="/dev/nbd0"

# Function to mount the QCOW2 image
mount_qcow2() {
	echo "Loading nbd kernel module..."
	sudo modprobe nbd max_part=8

	echo "Connecting the QCOW2 image to the NBD device..."
	sudo qemu-nbd --connect=${NBD_DEVICE} "${QCOW2_IMAGE}"

	echo "Waiting for the device to be ready..."
	sleep 5

	# Create mount point directory
	sudo mkdir -p "${MOUNT_POINT}"

	echo "Mounting the partition..."
	sudo mount ${NBD_DEVICE}p1 "${MOUNT_POINT}"

	echo "QCOW2 image mounted at ${MOUNT_POINT}"
}

# Function to unmount the QCOW2 image
unmount_qcow2() {
	echo "Unmounting the partition..."
	sudo umount "${MOUNT_POINT}"

	echo "Disconnecting the NBD device..."
	sudo qemu-nbd --disconnect ${NBD_DEVICE}

	echo "Removing nbd kernel module..."
	sudo rmmod nbd

	# Remove mount point directory
	sudo rmdir "${MOUNT_POINT}"

	echo "QCOW2 image has been unmounted."
}

# Execute the mount or unmount command
case "${COMMAND}" in
mount)
	mount_qcow2
	;;
unmount)
	unmount_qcow2
	;;
*)
	echo "Invalid command. Usage: $0 [mount|unmount] /path/to/image.qcow2"
	exit 1
	;;
esac
