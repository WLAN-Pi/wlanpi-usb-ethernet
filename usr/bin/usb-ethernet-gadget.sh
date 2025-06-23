#!/bin/bash

# Configuration
INTERFACES=("usb0" "usb1") # USB Ethernet interfaces to monitor
LOG_FILE="/var/log/usb-ethernet-gadget.log"
STATE_FILE="/var/run/usb-ethernet-gadget.state"
CHECK_INTERVAL=10          # Seconds between keep-alive checks
PING_COUNT=3               # Number of pings to send
GADGET_DIR="/sys/kernel/config/usb_gadget/wlanpi"
UDC_PATH="/sys/class/udc"
USB_PRODUCT="WLAN Pi USB Ethernet"
MANUFACTURER="WLAN Pi"
CONFIG_POWER="500"         # Max power in units of 2 mA (500 = 1 A)
CONFIG_ATTRIBUTES="0x80"   # Bus-powered

# Function to log messages to file and syslog
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    logger -t usb-ethernet-gadget "$message"
}

# Function to refresh ARP table
refresh_arp() {
    local iface="$1"
    # Get subnet broadcast address
    local broadcast
    broadcast=$(ip -4 addr show "$iface" | grep inet | awk '{print $2}' | cut -d/ -f1 | sed 's/\.[0-9]*$/.255/')
    if [ -n "$broadcast" ]; then
        ping -c 1 -b -I "$iface" "$broadcast" >/dev/null 2>&1
        log_message "Sent broadcast ping to $broadcast on $iface to refresh ARP table."
    else
        log_message "Could not determine broadcast address for $iface."
    fi
}

# Function to discover host IP via ARP table
discover_host_ip() {
    local iface="$1"
    # Query ARP table, exclude incomplete entries and header
    local ip
    ip=$(arp -n -i "$iface" | grep -v incomplete | grep -v Address | awk '{print $1}' | head -n 1)
    if [ -n "$ip" ]; then
        log_message "Discovered host IP $ip on $iface."
        echo "$ip"
        return 0
    else
        # Log raw ARP output for debugging
        log_message "No host IP found on $iface. ARP output: $(arp -n -i "$iface")"
        # Try refreshing ARP table
        refresh_arp "$iface"
        sleep 1
        ip=$(arp -n -i "$iface" | grep -v incomplete | grep -v Address | awk '{print $1}' | head -n 1)
        if [ -n "$ip" ]; then
            log_message "Discovered host IP $ip on $iface after ARP refresh."
            echo "$ip"
            return 0
        else
            log_message "Still no host IP found on $iface after ARP refresh."
            return 1
        fi
    fi
}

# Function to get or discover host IP for an interface
get_host_ip() {
    local iface="$1"
    local stored_ip
    # Check state file for cached IP
    if [ -f "$STATE_FILE" ]; then
        stored_ip=$(grep "^$iface:" "$STATE_FILE" | cut -d: -f3)
        if [ -n "$stored_ip" ]; then
            # Verify cached IP is still reachable
            if ping -c 1 -I "$iface" "$stored_ip" &>/dev/null; then
                log_message "Using cached host IP $stored_ip on $iface."
                echo "$stored_ip"
                return 0
            else
                log_message "Cached IP $stored_ip on $iface is not reachable."
            fi
        fi
    fi
    # Discover new IP if none cached or cached IP is unreachable
    discover_host_ip "$iface"
}

# Function to check if interface was previously connected
was_connected() {
    local iface="$1"
    if [ -f "$STATE_FILE" ]; then
        grep -q "^$iface:connected" "$STATE_FILE"
        return $?
    fi
    return 1
}

# Function to update connection state and host IP
update_state() {
    local iface="$1"
    local status="$2"
    local ip="$3"
    touch "$STATE_FILE"
    if grep -q "^$iface:" "$STATE_FILE"; then
        sed -i "s/^$iface:.*/$iface:$status:$ip/" "$STATE_FILE"
    else
        echo "$iface:$status:$ip" >> "$STATE_FILE"
    fi
}

# Gadget Configuration Functions
cleanup_gadget() {
    if [ -d "$GADGET_DIR" ]; then
        log_message "Cleaning up existing gadget configuration..."
        echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
        sleep 1
        rm -rf "$GADGET_DIR"
    fi
}

generate_mac_addresses() {
    local serial
    serial=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
    if [ -z "$serial" ]; then
        log_message "Error: Could not retrieve Raspberry Pi serial number."
        return 1
    fi
    local mac_base
    mac_base=$(echo "${serial}" | sed 's/\(..\)/:\1/g' | cut -b 2-)
    echo "02${mac_base}" "12${mac_base}"
}

create_device_strings() {
    local serial="$1"
    mkdir -p "$GADGET_DIR/strings/0x409"
    echo "$MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
    echo "$USB_PRODUCT" > "$GADGET_DIR/strings/0x409/product"
    echo "$serial" > "$GADGET_DIR/strings/0x409/serialnumber"
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
    local mac_host="$1"
    local mac_device="$2"
    mkdir -p "$GADGET_DIR/functions/ecm.usb0"
    echo "$mac_host" > "$GADGET_DIR/functions/ecm.usb0/host_addr"
    echo "$mac_device" > "$GADGET_DIR/functions/ecm.usb0/dev_addr"
    ln -s "$GADGET_DIR/functions/ecm.usb0" "$GADGET_DIR/configs/c.1/"
}

create_rndis_function() {
    local mac_host="$1"
    local mac_device="$2"
    mkdir -p "$GADGET_DIR/functions/rndis.usb1"
    echo "$mac_host" > "$GADGET_DIR/functions/rndis.usb1/host_addr"
    echo "$mac_device" > "$GADGET_DIR/functions/rndis.usb1/dev_addr"
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
        log_message "Bound gadget to UDC $udc."
        return 0
    else
        log_message "Error: No UDC device found."
        return 1
    fi
}

setup_gadget() {
    log_message "Configuring USB Ethernet gadget..."
    cleanup_gadget
    modprobe libcomposite || { log_message "Failed to load libcomposite module."; exit 1; }

    mkdir -p "$GADGET_DIR"
    echo "0x1209" > "$GADGET_DIR/idVendor"    # pid.codes
    echo "0x2042" > "$GADGET_DIR/idProduct"   # WLAN Pi
    echo "0x0100" > "$GADGET_DIR/bcdDevice"
    echo "0x0200" > "$GADGET_DIR/bcdUSB"

    read MAC_DEVICE MAC_HOST <<< "$(generate_mac_addresses)" || { log_message "Failed to generate MAC addresses."; exit 1; }
    SERIAL=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
    create_device_strings "$SERIAL"
    create_configuration "c.1" "CDC ECM Configuration"
    create_configuration "c.2" "RNDIS Configuration"
    create_cdc_ecm_function "$MAC_HOST" "$MAC_DEVICE"
    create_rndis_function "$MAC_HOST" "$MAC_DEVICE"
    configure_os_descriptors
    bind_gadget_to_udc || { log_message "Failed to bind gadget to UDC."; exit 1; }

    # Wait for interfaces to come up
    sleep 5
    for iface in "${INTERFACES[@]}"; do
        if ip link set "$iface" up 2>/dev/null; then
            log_message "Brought $iface up."
        else
            log_message "Failed to bring $iface up or interface not found."
        fi
    done
    log_message "USB Ethernet gadget configured successfully."
}

reset_gadget() {
    log_message "Resetting USB Ethernet gadget..."
    cleanup_gadget
    modprobe libcomposite || { log_message "Failed to load libcomposite module."; return 1; }

    mkdir -p "$GADGET_DIR"
    echo "0x1209" > "$GADGET_DIR/idVendor"    # pid.codes
    echo "0x2042" > "$GADGET_DIR/idProduct"   # WLAN Pi
    echo "0x0100" > "$GADGET_DIR/bcdDevice"
    echo "0x0200" > "$GADGET_DIR/bcdUSB"

    read MAC_DEVICE MAC_HOST <<< "$(generate_mac_addresses)" || { log_message "Failed to generate MAC addresses."; return 1; }
    SERIAL=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
    create_device_strings "$SERIAL"
    create_configuration "c.1" "CDC ECM Configuration"
    create_configuration "c.2" "RNDIS Configuration"
    create_cdc_ecm_function "$MAC_HOST" "$MAC_DEVICE"
    create_rndis_function "$MAC_HOST" "$MAC_DEVICE"
    configure_os_descriptors
    bind_gadget_to_udc || { log_message "Failed to bind gadget to UDC."; return 1; }

    # Wait for interfaces to come up
    sleep 5
    for iface in "${INTERFACES[@]}"; do
        if ip link set "$iface" up 2>/dev/null; then
            log_message "Brought $iface up."
        else
            log_message "Failed to bring $iface up or interface not found."
        fi
    done
    log_message "USB Ethernet gadget reset successfully."
    return 0
}

# Main Script
# Perform initial setup
setup_gadget

# Initialize state file for interfaces
for iface in "${INTERFACES[@]}"; do
    update_state "$iface" "disconnected" ""
done

# Enter keep-alive monitoring loop
log_message "Starting USB Ethernet keep-alive monitoring for ${INTERFACES[*]}."
while true; do
    needs_reset=false
    for iface in "${INTERFACES[@]}"; do
        if ip link show "$iface" >/dev/null 2>&1; then
            if ! ip link show "$iface" | grep -q "state UP"; then
                if was_connected "$iface"; then
                    log_message "Interface $iface was connected but is now down. Triggering reset."
                    needs_reset=true
                else
                    log_message "Interface $iface is down but was not previously connected. Skipping reset."
                fi
            else
                host_ip=$(get_host_ip "$iface")
                if [ -n "$host_ip" ] && [ "$host_ip" != "Address" ]; then
                    if ping -c "$PING_COUNT" -I "$iface" "$host_ip" &>/dev/null; then
                        log_message "Interface $iface is up and connected to $host_ip."
                        update_state "$iface" "connected" "$host_ip"
                    else
                        if was_connected "$iface"; then
                            log_message "Interface $iface was connected but no response from $host_ip. Triggering reset."
                            needs_reset=true
                        else
                            log_message "Interface $iface is up but no response from $host_ip. Skipping reset."
                            refresh_arp "$iface"
                        fi
                    fi
                else
                    if was_connected "$iface"; then
                        log_message "Interface $iface was connected but no valid host IP found. Triggering reset."
                        needs_reset=true
                    else
                        log_message "Interface $iface is up but no valid host IP found. Skipping reset."
                    fi
                fi
            fi
        else
            if was_connected "$iface"; then
                log_message "Interface $iface was connected but no longer exists. Triggering reset."
                needs_reset=true
            else
                log_message "Interface $iface does not exist and was not previously connected. Skipping reset."
            fi
        fi
    done

    if [ "$needs_reset" = true ]; then
        if reset_gadget; then
            log_message "USB Ethernet gadget reset successfully."
            for iface in "${INTERFACES[@]}"; do
                update_state "$iface" "disconnected" ""
            done
        else
            log_message "Failed to reset USB Ethernet gadget."
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
