#!/bin/bash

# Define the directory where the entries will be stored
entries_dir="/boot/loader/entries"

# Check if the directory exists, if not, create it
if [[ ! -d ${entries_dir} ]]; then
    mkdir -p ${entries_dir}
fi

# Create fwupd entry
cat > ${entries_dir}/fwupd.conf << EOF
title   Firmware Updater
efi     /EFI/tools/fwupdx64.efi
EOF

# Create netboot entry
cat > ${entries_dir}/netboot.conf << EOF
title   Netboot.xyz
efi     /EFI/tools/netboot.xyz.efi
EOF

# Create refind entry
cat > ${entries_dir}/refind.conf << EOF
title   rEFInd Boot Manager
efi     /EFI/refind/refind_x64.efi
EOF
