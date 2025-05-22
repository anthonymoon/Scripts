#!/bin/bash

# Setup script for Windows 11 ARM64 VM on Apple Silicon
# This script downloads UEFI firmware, sets up TPM, and creates a QCOW2 disk

set -e

# Configuration
VM_NAME="win11arm64"
DISK_SIZE="64G"
VM_DIR="$HOME/VMs/$VM_NAME"
TPM_DIR="/tmp/mytpm1"
UEFI_DIR="$VM_DIR/firmware"
QCOW2_PATH="$VM_DIR/windows11.qcow2"

# Display banner
echo "====================================="
echo "Windows 11 ARM64 VM Setup for QEMU"
echo "====================================="

# Create directories
mkdir -p "$VM_DIR"
mkdir -p "$UEFI_DIR"
mkdir -p "$TPM_DIR"

echo "[1/4] Downloading UEFI firmware..."

# Download UEFI firmware for ARM64
wget -O "$UEFI_DIR/QEMU_EFI.fd" https://releases.linaro.org/components/kernel/uefi-linaro/latest/release/qemu64/QEMU_EFI.fd
# Create variable store for UEFI
dd if=/dev/zero of="$UEFI_DIR/vars.fd" bs=1M count=64

echo "[2/4] Setting up TPM 2.0..."

# Check if swtpm is installed
if ! command -v swtpm &>/dev/null; then
  echo "Error: swtpm is not installed. Please install it first."
  echo "On macOS: brew install swtpm"
  echo "On Ubuntu: apt install swtpm"
  exit 1
fi

# Set up TPM 2.0
swtpm_setup --tpmstate "$TPM_DIR" --create-ek-cert --create-platform-cert --tpm2 --overwrite

# Start TPM socket in background
echo "Starting TPM socket server in background..."
swtpm socket --tpmstate "dir=$TPM_DIR" \
  --ctrl "type=unixio,path=$TPM_DIR/swtpm-sock" \
  --log level=20 --tpm2 &

# Save the PID for later cleanup
SWTPM_PID=$!
echo $SWTPM_PID >"$TPM_DIR/swtpm.pid"

echo "[3/4] Creating QCOW2 disk image ($DISK_SIZE)..."

# Create QCOW2 disk image
qemu-img create -f qcow2 "$QCOW2_PATH" "$DISK_SIZE"

echo "[4/4] Creating VM launch script..."

# Create a launch script for the VM
cat >"$VM_DIR/start_vm.sh" <<'EOF'
#!/bin/bash

VM_DIR="$(dirname "$(readlink -f "$0")")"
TPM_DIR="/tmp/mytpm1"

# Check if TPM socket is running, if not start it
if [ ! -S "$TPM_DIR/swtpm-sock" ]; then
    echo "Starting TPM socket..."
    swtpm socket --tpmstate "dir=$TPM_DIR" \
      --ctrl "type=unixio,path=$TPM_DIR/swtpm-sock" \
      --log level=20 --tpm2 &
    echo $! > "$TPM_DIR/swtpm.pid"
    # Wait a moment for the socket to be ready
    sleep 2
fi

# Start QEMU with Windows 11 ARM64
qemu-system-aarch64 \
  -accel hvf \
  -cpu host \
  -machine virt,highmem=on \
  -smp 4 \
  -m 8G \
  -bios "$VM_DIR/firmware/QEMU_EFI.fd" \
  -drive if=pflash,format=raw,file="$VM_DIR/firmware/vars.fd",readonly=off \
  -device virtio-gpu-pci,virgl=on \
  -spice port=5930,disable-ticketing=on \
  -device virtio-serial-pci \
  -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 \
  -chardev spicevmc,id=spicechannel0,name=vdagent \
  -drive file="$VM_DIR/windows11.qcow2",if=none,id=nvme0,format=qcow2 \
  -device nvme,drive=nvme0,serial=nvme0 \
  -drive file="$WINDOWS_ISO",media=cdrom,if=none,id=cdrom0 \
  -device ide-cd,drive=cdrom0,bus=ide.0 \
  -netdev user,id=vmnic0 \
  -device virtio-net-pci,netdev=vmnic0 \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -chardev socket,id=chrtpm,path="$TPM_DIR/swtpm-sock" \
  -device tpm-tis,tpmdev=tpm0 \
  -global ICH9-LPC.disable_s3=1

# Clean up TPM if needed
if [ "$CLEANUP_TPM" = "true" ]; then
    if [ -f "$TPM_DIR/swtpm.pid" ]; then
        PID=$(cat "$TPM_DIR/swtpm.pid")
        kill $PID 2>/dev/null || true
        rm "$TPM_DIR/swtpm.pid"
    fi
fi
EOF

# Make the launch script executable
chmod +x "$VM_DIR/start_vm.sh"

echo "====================================="
echo "Setup complete!"
echo "====================================="
echo "VM directory: $VM_DIR"
echo "UEFI firmware: $UEFI_DIR/QEMU_EFI.fd"
echo "Disk image: $QCOW2_PATH"
echo "TPM directory: $TPM_DIR"
echo ""
echo "To start the VM, you need to:"
echo "1. Edit $VM_DIR/start_vm.sh and set WINDOWS_ISO to your Windows 11 ARM64 ISO path"
echo "2. Run the script: $VM_DIR/start_vm.sh"
echo ""
echo "Note: You'll need to download Windows 11 ARM64 ISO separately"
echo "====================================="


