#!/bin/bash

for iommu_group in $(find /sys/kernel/iommu_groups/ -maxdepth 1 -mindepth 1 -type d); do
    group=$(basename $iommu_group)
    found_ethernet_controller=false
    devices=""
    for device in $(ls -1 $iommu_group/devices/); do
        if [ -e $iommu_group/devices/$device/vendor ]; then
            class=$(cat $iommu_group/devices/$device/class)
            if [[ "$class" == "0x020000" ]]; then
                found_ethernet_controller=true
                vendor=$(cat $iommu_group/devices/$device/vendor)
                device_id=$(cat $iommu_group/devices/$device/device)
                devices+="\t$device: $vendor:$device_id\n"
                
                # Set smp_affinity to CPU0
                irq_list=$(ls -1 /proc/irq/ | grep -P "^\d+$" | xargs -I {} grep -l $device /proc/irq/{}/msi_irqs 2>/dev/null)
                for irq in $irq_list; do
                    echo "1" > /proc/irq/$irq/smp_affinity
                    echo "Setting smp_affinity for IRQ $irq to CPU0"
                done
            fi
        fi
    done
    if [ "$found_ethernet_controller" = true ]; then
        echo "IOMMU Group $group:"
        echo -e "$devices"
    fi
done
