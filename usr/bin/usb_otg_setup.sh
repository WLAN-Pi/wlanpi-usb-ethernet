#!/bin/bash

set -e
set -x

LOGFILE="/tmp/usb_gadget_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Define gadget paths
GADGET_DIR="/sys/kernel/config/usb_gadget/wlanpi"
UDC_PATH="/sys/class/udc"
USB_PRODUCT="WLAN Pi USB Ethernet"

# Check permissions
if [ ! -w "/sys/kernel/config" ]; then
    echo "Error: /sys/kernel/config is not writable. Are you running as root?"
    exit 1
fi

# Remove existing gadget configuration
if [ -d "$GADGET_DIR" ]; then
    echo "Cleaning up existing gadget configuration..."
    echo "" > "$GADGET_DIR/UDC" || true
    rm -rf "$GADGET_DIR"
fi

# Create new gadget
mkdir -p "$GADGET_DIR"
echo 0x1d6b > "$GADGET_DIR/idVendor"    # Linux Foundation
echo 0x0104 > "$GADGET_DIR/idProduct"  # Multifunction Composite Gadget
echo 0x0100 > "$GADGET_DIR/bcdDevice"
echo 0x0200 > "$GADGET_DIR/bcdUSB"

mkdir -p "$GADGET_DIR/strings/0x409"
echo "serialnumber123456" > "$GADGET_DIR/strings/0x409/serialnumber"
echo "WLAN Pi" > "$GADGET_DIR/strings/0x409/manufacturer"
echo "$USB_PRODUCT" > "$GADGET_DIR/strings/0x409/product"

# Add device descriptors for RNDIS compatibility
echo 0xEF > "$GADGET_DIR/bDeviceClass"       # Miscellaneous Device
echo 0x02 > "$GADGET_DIR/bDeviceSubClass"   # Common Class
echo 0x01 > "$GADGET_DIR/bDeviceProtocol"   # Interface Association Descriptor

# Create configuration
mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
echo "CDC and RNDIS" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
echo 120 > "$GADGET_DIR/configs/c.1/MaxPower"

# Add ECM (Linux/macOS/iOS support)
mkdir -p "$GADGET_DIR/functions/ecm.usb0"
echo "02:01:02:03:04:08" > "$GADGET_DIR/functions/ecm.usb0/dev_addr"
echo "02:01:02:03:04:09" > "$GADGET_DIR/functions/ecm.usb0/host_addr"

# Add RNDIS (Windows support)
mkdir -p "$GADGET_DIR/functions/rndis.usb0"
mkdir -p "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis"
echo "02:01:02:03:04:0A" > "$GADGET_DIR/functions/rndis.usb0/dev_addr"
echo "02:01:02:03:04:0B" > "$GADGET_DIR/functions/rndis.usb0/host_addr"
echo "RNDIS" > "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
echo "5162001" > "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"
echo 0xE0 > "$GADGET_DIR/functions/rndis.usb0/class"        # Wireless Controller
echo 0x01 > "$GADGET_DIR/functions/rndis.usb0/subclass"    # Abstract (modem)
echo 0x03 > "$GADGET_DIR/functions/rndis.usb0/protocol"    # RNDIS

# Link functions to configuration
ln -s "$GADGET_DIR/functions/ecm.usb0" "$GADGET_DIR/configs/c.1/"
ln -s "$GADGET_DIR/functions/rndis.usb0" "$GADGET_DIR/configs/c.1/"

# OS descriptors for Windows
mkdir -p "$GADGET_DIR/os_desc"
echo 1 > "$GADGET_DIR/os_desc/use"
echo 0xcd > "$GADGET_DIR/os_desc/b_vendor_code"
echo "MSFT100" > "$GADGET_DIR/os_desc/qw_sign"

# Correctly link os_desc configuration
ln -s "$GADGET_DIR/configs/c.1" "$GADGET_DIR/os_desc/configuration"

# Bind gadget to UDC
for attempt in {1..5}; do
    UDC=$(ls "$UDC_PATH" | head -n 1)
    if [ -n "$UDC" ]; then
        echo "$UDC" > "$GADGET_DIR/UDC"
        echo "Gadget bound to UDC: $UDC"
        break
    fi
    echo "Waiting for UDC device to appear... (attempt $attempt)"
    sleep 1
done

if [ -z "$UDC" ]; then
    echo "Error: No UDC device found after 5 attempts."
    exit 1
fi
