# Linux Storage Supercharger: Performance Optimization for Rocky Linux

This guide adapts the advanced storage optimization techniques for your specific Rocky Linux system with volume group `rl` and RAID0 configuration. By implementing these optimizations, you'll achieve significantly better storage performance for your system.

## 1. Enabling TRIM/Discard Support for SSDs

### Verify TRIM Support

```bash
# Check if your SSDs support TRIM
sudo hdparm -I /dev/sd[bcdef] | grep TRIM

# Check all block devices for discard support
lsblk --discard
```

If your SSDs support TRIM, you'll see non-zero values in the DISC-GRAN and DISC-MAX columns of the lsblk output.

### Configure LVM for TRIM

1. Edit the LVM configuration file:
```bash
sudo nano /etc/lvm/lvm.conf
```

2. Find the `devices` section and enable discard:
```
devices {
    ...
    issue_discards = 1
    ...
}
```

3. Rebuild the initramfs:
```bash
sudo dracut -f
```

> **Warning**: With `issue_discards = 1` enabled, you won't be able to restore volume group metadata with `vgcfgrestore` if you make a mistake with LVM commands.

### Enable Periodic TRIM (Recommended)

For better performance, use periodic TRIM instead of continuous discard:

```bash
# Enable and start the weekly TRIM timer
sudo systemctl enable fstrim.timer
sudo systemctl start fstrim.timer

# Verify it's running
systemctl status fstrim.timer
```

If you prefer continuous TRIM despite the performance impact, add the `discard` option to your filesystem mount in `/etc/fstab`.

## 2. Optimizing Write-Back Caching

### Drive-Level Write Cache Configuration

1. Check current write cache status:
```bash
sudo hdparm -W /dev/sd[bcdef]
```

2. Enable write caching for each drive:
```bash
# For each of your drives in the RAID array
sudo hdparm -W 1 /dev/sdb
sudo hdparm -W 1 /dev/sdc
sudo hdparm -W 1 /dev/sdd
sudo hdparm -W 1 /dev/sde
sudo hdparm -W 1 /dev/sdf
```

3. Make settings persistent by adding to `/etc/hdparm.conf`:
```
/dev/sdb {
    write_cache = on
}
/dev/sdc {
    write_cache = on
}
/dev/sdd {
    write_cache = on
}
/dev/sde {
    write_cache = on
}
/dev/sdf {
    write_cache = on
}
```

### Kernel Parameter Optimization

Create a configuration file for SSD caching parameters:

```bash
sudo nano /etc/sysctl.d/99-ssd-cache.conf
```

Add the following content:
```
# Optimized SSD caching parameters for server workloads
vm.dirty_ratio = 30
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 300
```

Apply immediately:
```bash
sudo sysctl -p /etc/sysctl.d/99-ssd-cache.conf
```

### XFS Mount Options for Cache Optimization

If your root filesystem is XFS, update the mount options in `/etc/fstab`:

```bash
sudo nano /etc/fstab
```

Find the line for your root filesystem and modify it to include optimized parameters:
```
/dev/mapper/rl-root / xfs defaults,noatime,logbufs=8,logbsize=256k,allocsize=2M 0 0
```

## 3. Setting Up Emulated Persistent Memory with DAX

### Install Required Packages

```bash
sudo dnf install -y ndctl daxctl
```

### Configure the Kernel for PMEM

1. Add kernel parameters to reserve RAM for persistent memory:
```bash
sudo grubby --update-kernel=ALL --args="memmap=4G!12G hugepagesz=2M hugepages=1024 default_hugepagesz=2M"
```

2. Update GRUB:
```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

3. Reboot:
```bash
sudo reboot
```

### Create and Configure the PMEM Device

After rebooting, verify the pmem devices:
```bash
ls -l /dev/pmem*
dmesg | grep -E "persistent|pmem"
```

Create a namespace in FSDAX mode:
```bash
sudo ndctl create-namespace --mode=fsdax --align=2M --map=mem
```

Format the pmem device with XFS optimized for 2MB huge pages:
```bash
sudo mkfs.xfs -f -d su=2m,sw=1 -m reflink=0 /dev/pmem0
```

Create a mount point and mount with DAX option:
```bash
sudo mkdir -p /mnt/pmem
sudo mount -o dax /dev/pmem0 /mnt/pmem
```

Set the extent size to 2MB for optimal performance:
```bash
sudo xfs_io -c "extsize 2m" /mnt/pmem
```

Add to `/etc/fstab` for permanent mounting:
```
/dev/pmem0 /mnt/pmem xfs defaults,dax 0 0
```

### Configure Huge Pages

1. Add to `/etc/sysctl.conf` for persistent configuration:
```bash
sudo nano /etc/sysctl.conf
```

Add:
```
vm.nr_hugepages = 1024
```

2. Apply changes:
```bash
sudo sysctl -p
```

3. Configure memory locking limits:
```bash
sudo nano /etc/security/limits.conf
```

Add:
```
*               soft    memlock         unlimited
*               hard    memlock         unlimited
```

## 4. Setting Up PMEM as LVM Cache

### Add PMEM to Your Volume Group

```bash
# Create a physical volume on the pmem device
sudo pvcreate /dev/pmem0

# Add the physical volume to your existing volume group
sudo vgextend rl /dev/pmem0
```

### Create LVM Cache Volumes

```bash
# Create a metadata volume for the cache
sudo lvcreate -L 1G -n cache_meta rl /dev/pmem0

# Create the cache logical volume with most of the remaining space
sudo lvcreate -L 90%FREE -n cache_data rl /dev/pmem0

# Create a cache pool from the cache data and metadata volumes
sudo lvconvert --type cache-pool --poolmetadata rl/cache_meta rl/cache_data

# Attach the cache pool to the root logical volume
sudo lvconvert --type cache --cachepool rl/cache_data --cachemode writeback rl/root
```

### Add Required Kernel Modules to Initramfs

Create a dracut configuration file:
```bash
sudo nano /etc/dracut.conf.d/lvm-cache.conf
```

Add:
```
add_dracutmodules+=" dm_cache dm_cache_smq dm_persistent_data dm_bufio "
```

Rebuild the initramfs:
```bash
sudo dracut -f
```

### Set Cache Policy and Parameters

```bash
sudo lvchange --cachepolicy smq --cachesettings 'migration_threshold=2048' rl/root
```

## 5. Performance Tuning for the Entire Storage Stack

### Comprehensive Kernel Tuning

Create a comprehensive kernel tuning file:
```bash
sudo nano /etc/sysctl.d/99-storage-performance.conf
```

Add:
```
# XFS optimizations
fs.xfs.xfssyncd_centisecs = 3000

# VM optimizations
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 1500
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# File descriptor limits
fs.file-max = 2097152

# Memory management
vm.max_map_count = 262144
```

Apply the settings:
```bash
sudo sysctl -p /etc/sysctl.d/99-storage-performance.conf
```

### I/O Scheduler Optimization

Check current scheduler:
```bash
cat /sys/block/sda/queue/scheduler
```

Set optimal scheduler for SSDs:
```bash
# For each SSD in your system
echo "mq-deadline" | sudo tee /sys/block/sd[bcdef]/queue/scheduler
# For NVMe if present
echo "none" | sudo tee /sys/block/nvme0n1/queue/scheduler
```

Make permanent with udev rule:
```bash
sudo nano /etc/udev/rules.d/60-scheduler.rules
```

Add:
```
# Set none scheduler for NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"

# Set mq-deadline for SSDs
ACTION=="add|change", KERNEL=="sd[a-z]", ATTRS{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
```

### XFS Filesystem Optimization (For Future Filesystems)

When creating new XFS filesystems, use these parameters:
```bash
sudo mkfs.xfs -f -d su=2m,sw=1 -m reflink=0 -i size=2048 -l size=128m /dev/path/to/volume
```

Mount with performance-focused options:
```bash
sudo mount -o noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=2M,inode64 /dev/path/to/volume /mount/point
```

## 6. Monitoring and Performance Testing

### Monitor LVM Cache Performance

```bash
# Monitor cache statistics
sudo lvs -o+cache_dirty_blocks,cache_read_hits,cache_read_misses rl/root

# Detailed cache stats
sudo dmsetup status rl-root
```

### I/O Performance Monitoring

```bash
# Real-time I/O statistics
sudo dnf install -y sysstat iotop
sudo iostat -xz 1
sudo iotop -o

# XFS filesystem information
sudo xfs_info /
```

### Benchmarking

Install FIO for benchmarking:
```bash
sudo dnf install -y fio
```

Run basic read test:
```bash
fio --name=read-test --filename=/path/to/test/file --rw=read --bs=4k --direct=1 --ioengine=libaio --iodepth=64 --numjobs=4 --time_based --runtime=60 --group_reporting
```

Run basic write test:
```bash
fio --name=write-test --filename=/path/to/test/file --rw=write --bs=4k --direct=1 --ioengine=libaio --iodepth=64 --numjobs=4 --time_based --runtime=60 --group_reporting
```

## Putting It All Together

Here's a summary of the steps to take in sequence:

1. Enable TRIM support in LVM and set up periodic TRIM
2. Configure write-back caching at drive and kernel levels
3. Optimize XFS mount options for your existing root filesystem
4. Set up emulated persistent memory with DAX (requires reboot)
5. Configure the pmem device as an LVM cache for your root volume
6. Apply kernel tuning parameters for storage performance
7. Optimize I/O schedulers for your SSD and NVMe devices
8. Set up monitoring and run benchmarks to verify improvements

After completing these optimizations, your Rocky Linux system should experience significantly improved storage performance, with lower latency and higher throughput for both read and write operations.
