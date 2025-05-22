#!/bin/bash

# Unbind the device from its current driver
echo -n "0000:01:00.0" > /sys/bus/pci/devices/0000:01:00.0/driver/unbind

# Load the amdgpu module with specific options
modprobe amdgpu runpm=0 audio=0 gpu_recovery=1 reset_method=4 hw_i2c=0

# Find the AMD GPU directory
AMDGPUS=$(find /sys/kernel/debug/dri/ -mindepth 1 -maxdepth 1 -type d -not -type l)

# Attempt GPU recovery
cat "$AMDGPUS/amdgpu_gpu_recover"

# Unload the amdgpu module
modprobe -r amdgpu

# Bind the device to the amdgpu driver
echo -n "0000:01:00.0" > /sys/bus/pci/drivers/amdgpu/bind

