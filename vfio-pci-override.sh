#!/bin/sh
DEVS="0000:04:00.0 0000:04:00.1 0000:0a:00.0 0000:0a:00.1" 

if [ ! -z "$(ls -A /sys/class/iommu)" ]; then
    for DEV in $DEVS; do
        echo "vfio-pci" > /sys/bus/pci/devices/$DEV/driver_override
    done
fi
modprobe -i vfio-pci
