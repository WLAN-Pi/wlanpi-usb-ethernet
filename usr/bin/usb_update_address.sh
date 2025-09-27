#!/bin/bash
#
# Usage:
#   sudo ./usb_update_address.sh <new_cidr>
#
# Example:
#   sudo ./usb_update_address.sh 169.254.42.2/24
#   sudo ./usb_update_address.sh 169.254.43.1/24
#
# This script updates the following:
#  - Address line in usb0.network and usb1.network,
#  - Updates DHCP range in 10-usb-gadget.conf
# then restarts.
#
set -e
#set -x

if [ -z "$1" ]; then
  echo "Usage: $0 <new_cidr>"
  echo "Examples:"
  echo " - $0 169.254.42.2/24"
  echo " - $0 169.254.43.1/24"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "Must be run as root (sudo)"
   exit 1
fi

NEW_CIDR="$1"

if [[ ! "$NEW_CIDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  echo "Error: Invalid CIDR format. Expected format: x.x.x.x/24"
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
  if [[ "$octet" -gt 255 ]]; then
    echo "Error: IP octet $octet is invalid and greater than 255"
    exit 1
  fi
done

# Extract network portion (first 3 octets for /24)
if [ "$PREFIX" != "24" ]; then
  echo "Error: Only /24 networks are supported"
  exit 1
fi

# Validate link-local address range (169.254.0.0/16)
if [[ "${octets[0]}" != "169" || "${octets[1]}" != "254" ]]; then
  echo "Error: Address must be in link-local range (169.254.0.0/16)"
  exit 1
fi

NETWORK_BASE=$(echo "$IP" | cut -d'.' -f1-3)
HOST_LAST_OCTET="${octets[3]}"

# Calculate DHCP range: .10 to .29 in the same network
DHCP_START="${NETWORK_BASE}.10"
DHCP_END="${NETWORK_BASE}.29"

# Validate host IP doesn't conflict with DHCP range
if [[ "$HOST_LAST_OCTET" -ge 10 && "$HOST_LAST_OCTET" -le 29 ]]; then
  echo "Error: Host IP $IP conflicts with DHCP range ($DHCP_START - $DHCP_END)"
  echo "Use a host IP outside the .$DHCP_START-.$DHCP_END range"
  exit 1
fi

echo "Converting CIDR $NEW_CIDR to DHCP range: $DHCP_START,$DHCP_END"

USB0_NETWORK_FILE="/etc/systemd/network/usb0.network"
USB1_NETWORK_FILE="/etc/systemd/network/usb1.network"
DNSMASQ_FILE="/etc/dnsmasq.d/10-usb-gadget.conf"

for file in "$USB0_NETWORK_FILE" "$USB1_NETWORK_FILE" "$DNSMASQ_FILE"; do
  if [[ ! -f "$file" ]]; then
    echo "Error: Required file $file does not exist"
    exit 1
  fi
done

# Backup existing .network files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp -v "$USB0_NETWORK_FILE" "${USB0_NETWORK_FILE}.bak.${TIMESTAMP}"
cp -v "$USB1_NETWORK_FILE" "${USB1_NETWORK_FILE}.bak.${TIMESTAMP}"
cp -v "$DNSMASQ_FILE" "${DNSMASQ_FILE}.bak.${TIMESTAMP}"

# Update the Address line in each file
sed -i "s|^Address=.*|Address=$NEW_CIDR|g" "$USB0_NETWORK_FILE"
sed -i "s|^Address=.*|Address=$NEW_CIDR|g" "$USB1_NETWORK_FILE"

# Update DHCP range in dnsmasq config
sed -i "s|^dhcp-range=.*|dhcp-range=$DHCP_START,$DHCP_END,12h|g" "$DNSMASQ_FILE"

if ! grep -q "^dhcp-range=$DHCP_START,$DHCP_END,12h" "$DNSMASQ_FILE"; then
  echo "Warning: DHCP range may not have been updated correctly"
else
  echo "Updated DHCP range to: dhcp-range=$DHCP_START,$DHCP_END,12h"
fi

echo "Rebooting ..."
shutdown -r now
