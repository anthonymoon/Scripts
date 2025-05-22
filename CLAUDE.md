# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains a collection of shell scripts primarily focused on Linux system administration, virtualization management, storage optimization, and cloud infrastructure tasks. The scripts are designed to be standalone utilities that can be executed independently.

Key categories of scripts include:

1. **Storage Optimization**: Scripts for optimizing disk parameters and I/O schedulers
2. **Virtualization Management**: Scripts for VM management, QEMU/KVM, and VFIO passthrough
3. **System Monitoring**: Tools for capturing system information and performance metrics
4. **Cloud Infrastructure**: Google Cloud Platform (GCP) management scripts

## Script Usage

Scripts in this repository can generally be run directly after making them executable:

```bash
chmod +x script_name.sh
./script_name.sh
```

Some scripts may require root privileges or specific dependencies. These requirements are typically documented at the beginning of each script file.

## Common Script Patterns

Many scripts in this repository follow these patterns:

1. **Error handling**: Using `set -e` and explicit error checking with descriptive messages
2. **Section organization**: Functions for discrete operations within scripts
3. **Hardware detection**: Logic to detect and adapt to different device types
4. **Logging**: Many scripts use the `logger` command for system logging
5. **Google Shell Style Guidelines**: 
   - Never nest beyond two levels of if statements
   - Maintain clean, readable code structure

## Key Scripts

### Storage Optimization

- `disk_optimization.sh`: Comprehensive script for storage performance tuning
- `set_io_scheduler.sh`: Sets optimal I/O schedulers for different disk types
- `storage_config_collector.sh`: Collects detailed storage configuration for analysis

### Virtualization

- `shutdown-all-vms.sh`: Gracefully shuts down running VMs with multiple fallback methods
- `qcow2-mounter.sh`: Utility to mount/unmount QCOW2 image files
- `vfio-pci-override.sh`: Configures VFIO PCI passthrough for virtualization

### System Administration

- `system-info-capture.sh`: Comprehensive system information collection
- `watchCPU.sh`: Monitors CPU performance
- `get_pci_info.sh`: Retrieves PCI device information

### Cloud Infrastructure

- `gcp-add-cis-controls.sh`: Sets up CIS compliance monitoring for GCP
- `list-buckets-by-iam-grants.sh`: Lists GCS buckets by IAM permissions
- `reduceIAMPrivs.sh`: Helps reduce IAM privileges for security hardening

## Testing

These scripts don't have formal testing frameworks. When modifying scripts, test changes manually in a safe environment before deploying to production systems.

For storage-related scripts, you can use tools like `fio` for performance benchmarking:

```bash
fio --name=read-test --filename=/path/to/test/file --rw=read --bs=4k --direct=1 --ioengine=libaio --iodepth=64 --numjobs=4 --time_based --runtime=60 --group_reporting
```

## References

The storage optimization scripts align with detailed guidance in the `storage-optimization.md` document, which provides comprehensive techniques for Linux storage performance optimization.

## Development Best Practices

- Track your changes in git so we can checkpoint them and rollback if needed
- Commit after making each change

## Tool Configurations

- use pylint from homebrew