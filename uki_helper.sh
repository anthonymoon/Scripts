#!/bin/bash

# Set the flavour of your kernel, adjust as needed
FLAVOUR=""

# Full path to the EFI directory on the ESP
EFI_PATH="/esp/EFI/ArchLinux"

# Kernel and initramfs paths
KERNEL_PATH="/boot/vmlinuz-linux"
INITRAMFS_PATH="/boot/initramfs-linux.img"

# Command line options from file
CMDLINE=$(cat /etc/kernel/cmdline)

# Ensure EFI_PATH exists
mkdir -p "$EFI_PATH"

# Start building the ukify command
UKIFY_CMD="ukify build --linux=$KERNEL_PATH"

# Check for microcode images and add them to the ukify command
for ucode in /boot/*-ucode.img; do
  if [[ -f "$ucode" ]]; then
    UKIFY_CMD+=" --initrd=$ucode"
  fi
done

# Add the initramfs to the ukify command
UKIFY_CMD+=" --initrd=$INITRAMFS_PATH"

# Add the kernel command line to the ukify command
UKIFY_CMD+=" --cmdline=\"$CMDLINE\""

# Specify the output file for the unified kernel image
OUTPUT_FILE="$EFI_PATH/linux-zen.efi"
UKIFY_CMD+=" --output=$OUTPUT_FILE"

# Execute the ukify command
eval $UKIFY_CMD

# Check if the ukify command was successful
if [[ $? -eq 0 ]]; then
  echo "Unified kernel image created successfully: $OUTPUT_FILE"
else
  echo "Failed to create the unified kernel image."
  exit 1
fi

