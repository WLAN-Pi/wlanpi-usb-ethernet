#!/bin/bash
#
# Usage:
#   sudo ./usb_update_address.sh <new_cidr>
#
# Example:
#   sudo ./usb_update_address.sh 10.43.0.1/24
#
# This script updates the Address line in usb0.network and usb1.network,
# then restarts.
#
set -e
#set -x

if [ -z "$1" ]; then
  echo "Usage: $0 <new_cidr>"
  echo "Example: $0 10.43.0.1/24"
  exit 1
fi

NEW_CIDR="$1"

# Adjust these paths if necessary
USB0_NETWORK_FILE="/etc/systemd/network/usb0.network"
USB1_NETWORK_FILE="/etc/systemd/network/usb1.network"

# Backup existing .network files
cp -v "$USB0_NETWORK_FILE" "${USB0_NETWORK_FILE}.bak"
cp -v "$USB1_NETWORK_FILE" "${USB1_NETWORK_FILE}.bak"

# Update the Address line in each file
sed -i "s|^Address=.*|Address=$NEW_CIDR|g" "$USB0_NETWORK_FILE"
sed -i "s|^Address=.*|Address=$NEW_CIDR|g" "$USB1_NETWORK_FILE"

shutdown -r now
echo "Rebooting..."
