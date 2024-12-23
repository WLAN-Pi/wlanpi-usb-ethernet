#!/bin/bash

# Define gadget paths
GADGET_DIR="/sys/kernel/config/usb_gadget/wlanpi"
UDC_PATH="/sys/class/udc"
USB_PRODUCT="WLAN Pi USB Ethernet"

# Remove existing gadget configuration
if [ -d "$GADGET_DIR" ]; then
    echo "Cleaning up existing gadget configuration..."
    echo "" > "$GADGET_DIR/UDC"
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
echo "02:01:02:03:04:0A" > "$GADGET_DIR/functions/rndis.usb0/dev_addr"
echo "02:01:02:03:04:0B" > "$GADGET_DIR/functions/rndis.usb0/host_addr"
echo "RNDIS" > "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
echo "5162001" > "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"

# Link functions to configuration
ln -s "$GADGET_DIR/functions/ecm.usb0" "$GADGET_DIR/configs/c.1/"
ln -s "$GADGET_DIR/functions/rndis.usb0" "$GADGET_DIR/configs/c.1/"

# OS descriptors for Windows
mkdir -p "$GADGET_DIR/os_desc"
echo 1 > "$GADGET_DIR/os_desc/use"
echo 0xcd > "$GADGET_DIR/os_desc/b_vendor_code"
echo "MSFT100" > "$GADGET_DIR/os_desc/qw_sign"

ln -s "$GADGET_DIR/functions/rndis.usb0" "$GADGET_DIR/os_desc"

# Bind gadget to UDC
UDC=$(ls "$UDC_PATH" | head -n 1)
echo "$UDC" > "$GADGET_DIR/UDC"

