#!/bin/bash
#
# Usage:
#   sudo ./usb_update_address.sh <new_cidr>
#
# Example:
#   sudo ./usb_update_address.sh 198.18.43.1/24
#
# This script updates the Address line in usb0.network and usb1.network
#  then restarts.
#
set -e
#set -x

if [ -z "$1" ]; then
  echo "Usage: $0 <new_cidr>"
  echo "Examples:"
  echo " - $0 198.18.43.1/24"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "Must be run as root (sudo)"
   exit 1
fi

NEW_CIDR="$1"

if [[ ! "$NEW_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  echo "Error: Invalid CIDR format. Expected format: x.x.x.x/24 inside RFC 5735 range (198.18.0.0/15)"
  exit 1
fi

# Extract IP and prefix from CIDR notation
IFS='/' read -r IP PREFIX <<< "$NEW_CIDR"

if [[ -z "$IP" || -z "$PREFIX" ]]; then
  echo "Error: Could not parse CIDR notation"
  exit 1
fi

# Validate IP octets
IFS='.' read -r -a octets <<< "$IP"

for octet in "${octets[@]}"; do
  if [[ "$octet" -lt 0 || "$octet" -gt 255 ]]; then
    echo "Error: IP octet $octet is invalid (must be 0-255)"
    exit 1
  fi
done

# Validate prefix is /24
if [ "$PREFIX" != "24" ]; then
  echo "Error: /24 networks only"
  exit 1
fi

# Validate RFC 5735 address range (198.18.0.0/15)
if [[ "${octets[0]}" != "198" || ("${octets[1]}" != "18" && "${octets[1]}" != "19") ]]; then
    echo "Error: CIDR must be in RFC 5735 range (198.18.0.0/15)"
    exit 1
fi

if [[ "${octets[3]}" -eq 0 ]]; then
  echo "Error: Cannot use network address (last octet cannot be 0)"
  exit 1
fi

if [[ "${octets[3]}" -eq 255 ]]; then
  echo "Error: Cannot use broadcast address (last octet cannot be 255)"
  exit 1
fi

USB0_NETWORK_FILE="/etc/systemd/network/usb0.network"
USB1_NETWORK_FILE="/etc/systemd/network/usb1.network"

for file in "$USB0_NETWORK_FILE" "$USB1_NETWORK_FILE"; do
  if [[ ! -f "$file" ]]; then
    echo "Error: Required file $file does not exist"
    exit 1
  fi
done

for file in "$USB0_NETWORK_FILE" "$USB1_NETWORK_FILE"; do
  if [[ ! -w "$file" ]]; then
    echo "Error: File $file is not writable"
    exit 1
  fi
done

# Backup existing .network files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp -v "$USB0_NETWORK_FILE" "${USB0_NETWORK_FILE}.bak.${TIMESTAMP}"
cp -v "$USB1_NETWORK_FILE" "${USB1_NETWORK_FILE}.bak.${TIMESTAMP}"

# Update the Address line in each file
sed -i "s|^Address=.*|Address=$NEW_CIDR|g" "$USB0_NETWORK_FILE"
sed -i "s|^Address=.*|Address=$NEW_CIDR|g" "$USB1_NETWORK_FILE"

# Verify the update was successful
for file in "$USB0_NETWORK_FILE" "$USB1_NETWORK_FILE"; do
  if ! grep -q "^Address=$NEW_CIDR" "$file"; then
    echo "Error: Failed to update Address in $file"
    exit 1
  fi
done

echo "Successfully updated network configuration:"
echo "  USB0: $USB0_NETWORK_FILE"
echo "  USB1: $USB1_NETWORK_FILE"
echo "  New address: $NEW_CIDR"
echo ""
echo "System reboot in 5 seconds (Ctrl+C to cancel) ..."
sleep 5
shutdown -r now
