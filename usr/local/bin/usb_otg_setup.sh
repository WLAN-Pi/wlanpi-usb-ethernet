#!/bin/bash
modprobe dwc2
modprobe libcomposite

cd /sys/kernel/config/usb_gadget/
mkdir -p wlanpi_gadget
cd wlanpi_gadget

echo 0x1d6b > idVendor  # Linux Foundation
echo 0x0104 > idProduct # Multifunction Composite Gadget
echo 0x0100 > bcdDevice # Device version
echo 0x0200 > bcdUSB    # USB 2.0

mkdir -p strings/0x409
echo "WLANPI12345" > strings/0x409/serialnumber
echo "WLAN Pi Project" > strings/0x409/manufacturer
echo "WLAN Pi USB Ethernet" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "WLAN Pi USB Gadget Configuration" > configs/c.1/strings/0x409/configuration
echo 120 > configs/c.1/MaxPower

mkdir -p functions/ecm.usb0
ln -s functions/ecm.usb0 configs/c.1/
echo "$(ls /sys/class/udc/)" > UDC
