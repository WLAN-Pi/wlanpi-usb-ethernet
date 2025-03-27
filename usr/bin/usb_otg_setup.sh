#!/bin/bash

set -e
set -x

LOGFILE="/tmp/usb_gadget_dual.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Constants
GADGET_DIR="/sys/kernel/config/usb_gadget/wlanpi"
UDC_PATH="/sys/class/udc"
USB_PRODUCT="WLAN Pi USB Ethernet"
MANUFACTURER="Oscium"
CONFIG_POWER="500"    # Max power in units of 2 mA (500 = 1 A)
CONFIG_ATTRIBUTES="0x80"  # Bus-powered

# Helper Functions
cleanup_gadget() {
    if [ -d "$GADGET_DIR" ]; then
        echo "Cleaning up existing gadget configuration..."
        echo "" > "$GADGET_DIR/UDC" || true
        sleep 1
        rm -rf "$GADGET_DIR"
    fi
}

generate_mac_addresses() {
    local serial
    serial=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
    if [ -z "$serial" ]; then
        echo "Error: Could not retrieve Raspberry Pi serial number."
        exit 1
    fi
    local mac_base
    mac_base=$(echo "${serial}" | sed 's/\(..\)/:\1/g' | cut -b 2-)
    echo "02${mac_base}" "12${mac_base}"
}

create_device_strings() {
    mkdir -p "$GADGET_DIR/strings/0x409"
    echo "$MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
    echo "$USB_PRODUCT" > "$GADGET_DIR/strings/0x409/product"
    echo "$SERIAL" > "$GADGET_DIR/strings/0x409/serialnumber"
}

create_configuration() {
    local config="$1"
    local description="$2"
    mkdir -p "$GADGET_DIR/configs/$config/strings/0x409"
    echo "$description" > "$GADGET_DIR/configs/$config/strings/0x409/configuration"
    echo "$CONFIG_ATTRIBUTES" > "$GADGET_DIR/configs/$config/bmAttributes"
    echo "$CONFIG_POWER" > "$GADGET_DIR/configs/$config/MaxPower"
}

create_cdc_ecm_function() {
    mkdir -p "$GADGET_DIR/functions/ecm.usb0"
    echo "$MAC_HOST" > "$GADGET_DIR/functions/ecm.usb0/host_addr"
    echo "$MAC_DEVICE" > "$GADGET_DIR/functions/ecm.usb0/dev_addr"
    ln -s "$GADGET_DIR/functions/ecm.usb0" "$GADGET_DIR/configs/c.1/"
}

create_rndis_function() {
    mkdir -p "$GADGET_DIR/functions/rndis.usb1"
    echo "$MAC_HOST" > "$GADGET_DIR/functions/rndis.usb1/host_addr"
    echo "$MAC_DEVICE" > "$GADGET_DIR/functions/rndis.usb1/dev_addr"
    mkdir -p "$GADGET_DIR/functions/rndis.usb1/os_desc/interface.rndis"
    echo "RNDIS" > "$GADGET_DIR/functions/rndis.usb1/os_desc/interface.rndis/compatible_id"
    echo "5162001" > "$GADGET_DIR/functions/rndis.usb1/os_desc/interface.rndis/sub_compatible_id"
    ln -s "$GADGET_DIR/functions/rndis.usb1" "$GADGET_DIR/configs/c.2/"
}

configure_os_descriptors() {
    mkdir -p "$GADGET_DIR/os_desc"
    echo 1 > "$GADGET_DIR/os_desc/use"
    echo 0xcd > "$GADGET_DIR/os_desc/b_vendor_code"
    echo "MSFT100" > "$GADGET_DIR/os_desc/qw_sign"
    ln -s "$GADGET_DIR/configs/c.2" "$GADGET_DIR/os_desc"
}

bind_gadget_to_udc() {
    udevadm settle -t 5 || true
    local udc
    udc=$(ls "$UDC_PATH" | head -n 1)
    if [ -n "$udc" ]; then
        echo "$udc" > "$GADGET_DIR/UDC"
    else
        echo "Error: No UDC device found."
        exit 1
    fi
}

# Main Script
cleanup_gadget
modprobe libcomposite

mkdir -p "$GADGET_DIR"
echo "0x26ae" > "$GADGET_DIR/idVendor"    # Oscium
echo "0x000E" > "$GADGET_DIR/idProduct"
echo "0x0100" > "$GADGET_DIR/bcdDevice"
echo "0x0200" > "$GADGET_DIR/bcdUSB"
echo "0xEF" > "$GADGET_DIR/bDeviceClass"
echo "0x02" > "$GADGET_DIR/bDeviceSubClass"
echo "0x01" > "$GADGET_DIR/bDeviceProtocol"

read MAC_DEVICE MAC_HOST <<< "$(generate_mac_addresses)"
SERIAL=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
create_device_strings

create_configuration "c.1" "CDC ECM Configuration"
create_configuration "c.2" "RNDIS Configuration"

create_cdc_ecm_function
create_rndis_function
configure_os_descriptors

bind_gadget_to_udc

echo "USB Ethernet gadget configured with dual interfaces: CDC ECM (usb0) and RNDIS (usb1)."
