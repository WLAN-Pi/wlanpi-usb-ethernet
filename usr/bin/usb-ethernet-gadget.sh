#!/bin/bash

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~
# USB ethernet gadget monitor
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# Monitors USB ethernet interfaces (CDC ECM and RNDIS) for connectivity and
# manages USB gadget lifecycle. Handles host sleep/wake cycles, cable
# disconnects, and automatic recovery without causing reset loops.
#
# HOSTS:
#   - macOS (CDC ECM via usb0)
#   - Linux (CDC ECM via usb0)
#   - iOS/iPhone (CDC ECM via usb0)
#   - Modern Android (CDC ECM via usb0)
#   - Windows (RNDIS via usb1)
#
# usb0 is monitored by default (usb1 is created but not monitored unless enabled)
#
# USB STATE BEHAVIOR:
#   macOS:   Uses "configured" ↔ "not attached" (does NOT use "suspended")
#   iPhone:  Same as macOS - "configured" ↔ "not attached"
#   Android: Uses "configured" ↔ "suspended" ↔ "not attached"
#
#   Bottom line: cannot distinguish host sleep from cable unplug on macOS/iOS
#   because both show "not attached" state. REQUIRED to use timeout-based approach
#   with thresholds to avoid resetting during normal sleep/wake.
#
# LOG FILES:
#   /var/log/usb-ethernet-gadget.log      - Main operational log
#   /var/log/usb-gadget-boot-timing.log   - Boot timing (only when BOOT_TIMING_ENABLED="true")
#
# STATE FILE:
#   /var/run/usb-ethernet-gadget.state    - Current connection state per interface
#   Format: interface:status:host_ip:connected_once (e.g., "usb0:connected:198.18.42.17:true")
#
# DEPENDENCIES (external commands used):
#   Core utilities (coreutils): cat, cut, date, echo, mkdir, mktemp, mv, rm, sleep, touch, ln
#   Network tools: ip (iproute2), ping (iputils-ping)
#   Text processing: awk (gawk), grep, sed
#   System: modprobe (kmod), logger (bsdutils), uname, find (findutils)
#   Optional: bc (bc) - for sub-second timing in boot logs
#             zcat (gzip) - for reading /proc/config.gz


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# STATE MACHINE DEFINITIONS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# USB gadget states (from /sys/class/udc/*/state):
#   - "not attached"    : USB cable disconnected or host sleeping
#   - "suspended"       : Host has suspended USB (sleep mode)
#   - "configured"      : USB connected and enumerated, ready for data
#
# Connection states (tracked per interface):
#   - "disconnected"    : Never connected or connection lost
#   - "waiting"         : Interface up, waiting for host to respond
#   - "connected"       : Host IP found and responding to ping
#
# Host sleep states:
#   - HOST_IS_SLEEPING="false" : Host is awake or unknown
#   - HOST_IS_SLEEPING="true"  : Host detected entering sleep mode
#
# Failure counters (per interface):
#   - fail_no_ip        : Consecutive checks with no host IP found
#   - fail_no_ping      : Consecutive checks with ping failures
#   - not_attached_count: Consecutive checks in "not attached" state
#
# Valid USB state transitions:
#   not_attached -> suspended    : Device plugged in, not yet configured
#   not_attached -> configured   : Fast enumeration (rare)
#   suspended -> configured      : Enumeration complete (wake)
#   configured -> suspended      : Host entering sleep
#   suspended -> not_attached    : Unplugged while sleeping
#   configured -> not_attached   : Unplugged while active

# ~~~~~~~~~~~~~
# CONFIGURATION
# ~~~~~~~~~~~~~
# Interface(s) to monitor - usb0 monitored by default, host selects which to use
#   usb0 = CDC ECM (macOS, Linux, iOS, modern Android)
#   usb1 = RNDIS (Windows, older Android)
#     usb1 is disabled by default, gadget still creates an RNDIS interface.
#     usb1 is not monitored for connectivity or resets.
INTERFACES=("usb0")
LOG_FILE="/var/log/usb-ethernet-gadget.log"
STATE_FILE="/var/run/usb-ethernet-gadget.state"
GADGET_DIR="/sys/kernel/config/usb_gadget/wlanpi"
UDC_PATH="/sys/class/udc"

# Network configuration - must match /etc/systemd/network/usb*.network
USB_SUBNET="198.18.42"      # Subnet prefix for USB interfaces (198.18.42.0/24)

# Persistent boot timing log - survives reboots, for debugging
# early boot enumeration issues
BOOT_TIMING_LOG="/var/log/usb-gadget-boot-timing.log"

# ~~~~~~~~~~~~~~~~~
# POLLING INTERVALS
# ~~~~~~~~~~~~~~~~~
# Dynamic interval switching based on state:
#   - Normal connected state: CHECK_INTERVAL (2s)
#   - Post-wake turbo mode: POST_WAKE_TURBO_INTERVAL (1s) for faster recovery
#   - USB suspended: 1s (watching for wake)
#   - Disconnected/waiting: INIT_CHECK_INTERVAL (2s)
CHECK_INTERVAL=2           # Seconds between checks when connected (switches to POST_WAKE_TURBO_INTERVAL during turbo)
INIT_CHECK_INTERVAL=2      # Seconds between checks during initial discovery
POST_WAKE_TURBO_INTERVAL=1 # Seconds between checks during post-wake turbo mode (faster recovery)
POST_WAKE_TURBO_DURATION=15 # Duration of turbo mode in seconds after wake
PING_COUNT=3               # Number of pings per connectivity check
PING_TIMEOUT=1             # Seconds to wait for each ping response

# ~~~~~~~~~~~~~~~~~~~~~~
# USB gadget descriptors
# ~~~~~~~~~~~~~~~~~~~~~~
USB_PRODUCT="WLAN Pi USB Ethernet"
MANUFACTURER="WLAN Pi"
CONFIG_POWER="500"         # Max power in mA (500mA for USB 2.0)
CONFIG_ATTRIBUTES="0x80"   # Bus-powered (not self-powered)

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Failure thresholds - prevents reset loops during enumeration/sleep
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# Threshold Summary (checks × interval = approximate time before reset):
#
# Path                      | Threshold                    | Approx. Time
# --------------------------|------------------------------|-------------
# Post-wake fast reset      | POST_WAKE_FAST_THRESHOLD=1   | ~3-5s
# Reconnect (was connected) | RECONNECT_THRESHOLD=3        | ~6s
# USB "not attached"        | NOT_ATTACHED_THRESHOLD=25    | ~50s
#
# Philosophy:
# - Never connected → wait patiently (no reset)
# - Was connected → fast recovery (RECONNECT_THRESHOLD)
# - iOS wake → ultra-fast (POST_WAKE_FAST_THRESHOLD)
# - USB unplugged → patient (NOT_ATTACHED_THRESHOLD handles sleep/wake)

# Post-wake fast reset threshold - number of failed connectivity checks before reset after wake
# Lower = faster recovery for iPhone/iPad (but more aggressive), Higher = more patient (but slower)
# Optimized for iPad/iPhone behavior where screen wake does NOT wake network stack
# Default: 1 check (~4-5s total: 1s grace period + 1 check × 1s turbo interval + 2-3s reset)
POST_WAKE_FAST_THRESHOLD=1
# RECONNECT: Was connected, now broken
#   Single threshold for all "was connected" scenarios (no_ip, no_ping, unresponsive)
RECONNECT_THRESHOLD=3        # 3 checks × 2s = ~6s before reset

# USB "NOT ATTACHED": Cable unplugged or host sleeping
#   High threshold to avoid reset during normal sleep/wake cycles
NOT_ATTACHED_THRESHOLD=25    # 25 checks × 2s = ~50s (handles 40s sleep/wake)

# ~~~~~~~~~~~~~~~~~~~~~~~~~~
# Debug and Logging Settings
# ~~~~~~~~~~~~~~~~~~~~~~~~~~
# DEBUG_MODE: Enable verbose diagnostic logging (timestamps, state transitions)
#   "true"  = Log detailed diagnostics to main log file (useful for troubleshooting)
#   "false" = Only log important events (default, recommended for production)
DEBUG_MODE="false"

# BOOT_TIMING_ENABLED: Enable boot timing log for debugging enumeration issues
#   "true"  = Write detailed boot timing to /var/log/usb-gadget-boot-timing.log
#   "false" = Disable boot timing log (default, recommended for production)
#   Enable this when debugging early boot USB enumeration problems (e.g., Pixel 8)
BOOT_TIMING_ENABLED="false"

# Internal state for wake detection timing
WAKE_DETECTED_TIME=""
# Track host sleeping state explicitly to prevent counter accumulation and resets during sleep
# Set when sleep is detected, cleared when wake is confirmed
HOST_IS_SLEEPING="false"

# Tracks whether the gadget is currently bound to a UDC (main loop retries setup if unbound)
GADGET_BOUND="false"


# ~~~~~~~~~~~~~~~~~~~~~
# GLOBAL STATE TRACKING
# ~~~~~~~~~~~~~~~~~~~~~
# Uses a single array for all per-interface state:
#   STATE[iface,field] = value
#
# Per-interface fields:
#   usb_state         - Current USB state (configured/suspended/not attached)
#   is_idle           - Host is idle/sleeping (ping fails but ARP exists)
#   is_connected      - Host is connected (prevents log spam on steady state)
#   fail_no_ip        - Consecutive failures: no host IP found
#   fail_no_ping      - Consecutive failures: host IP exists but ping fails
#   not_attached_count- Consecutive checks in "not attached" USB state
#   last_host_ip      - Last known host IP address
#   link_down_logged  - Whether "interface down" has been logged (prevents log spam)
#   suspended_logged  - Whether "USB suspended" has been logged (prevents log spam)
#
# Global fields (keyed as "global,field"):
#   last_suspended    - Previous value of sysfs suspended flag (wake detection)
#   last_dsts         - Previous value of DSTS register suspend bit
#
# Note: Connection history is tracked via was_previously_connected() which reads
# from the persistent STATE_FILE on disk (survives script restarts).

declare -gA STATE

# ~~~~~~~
# LOGGING
# ~~~~~~~

log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    logger -t usb-ethernet-gadget "$message"
}

# Only logs when DEBUG_MODE="true"
debug_log() {
    [[ "$DEBUG_MODE" != "true" ]] && return

    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - DEBUG: $message" >> "$LOG_FILE"
}

# Only logs when DEBUG_MODE="true"
diagnostic_log() {
    [[ "$DEBUG_MODE" != "true" ]] && return

    local category="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%N')
    echo "$timestamp - DIAG[$category]: $message" >> "$LOG_FILE"
}

# Detailed state logging for debugging sleep/wake detection issues
# Only logs when DEBUG_MODE="true"
log_detailed_state() {
    [[ "$DEBUG_MODE" != "true" ]] && return

    local context="$1"
    local iface="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%N')

    # USB state
    local usb_state suspended dsts
    usb_state=$(get_usb_state)
    suspended=$(get_sysfs_suspended)
    dsts=$(get_dsts_suspend_bit)

    # Global state
    local last_suspended last_dsts
    last_suspended="${STATE[global,last_suspended]:-N/A}"
    last_dsts="${STATE[global,last_dsts]:-N/A}"

    # Sleep/wake state
    local host_sleeping wake_time elapsed
    host_sleeping="$HOST_IS_SLEEPING"
    if [[ -n "$WAKE_DETECTED_TIME" ]]; then
        wake_time="$WAKE_DETECTED_TIME"
        elapsed=$(($(date +%s.%N | cut -d. -f1) - WAKE_DETECTED_TIME))
    else
        wake_time="N/A"
        elapsed="N/A"
    fi

    # Interface state
    local fail_no_ip fail_no_ping not_attached is_idle is_connected
    fail_no_ip=$(get_interface_state "$iface" "fail_no_ip")
    fail_no_ping=$(get_interface_state "$iface" "fail_no_ping")
    not_attached=$(get_interface_state "$iface" "not_attached_count")
    is_idle=$(get_interface_state "$iface" "is_idle")
    is_connected=$(get_interface_state "$iface" "is_connected")

    # Network State
    local dormant carr_chg carr_up carr_down
    dormant=$(get_interface_dormant "$iface")
    carr_chg=$(get_carrier_changes "$iface")
    carr_up=$(get_carrier_up_count "$iface")
    carr_down=$(get_carrier_down_count "$iface")

    # ARP state (debug-only, MUST be non-intrusive)
    # Use cached host IP only to avoid triggering ARP refresh or ping side effects
    local arp_state host_ip
    if [[ -f "$STATE_FILE" ]]; then
        host_ip=$(grep "^$iface:" "$STATE_FILE" | cut -d: -f3)
    else
        host_ip=""
    fi

    if [[ -n "$host_ip" ]]; then
        arp_state=$(ip neighbor show dev "$iface" 2>/dev/null | grep "^$host_ip " | awk '{print $NF}')
        [[ -z "$arp_state" ]] && arp_state="NONE"
    else
        arp_state="NO_IP"
    fi

    # Build log line with debug fields
    echo "$timestamp - STATE[$context]: iface=$iface usb=$usb_state sus=$suspended dsts=$dsts last_sus=$last_suspended last_dsts=$last_dsts HOST_IS_SLEEPING=$host_sleeping WAKE_TIME=$wake_time ELAPSED=$elapsed fail_ip=${fail_no_ip:-0} fail_ping=${fail_no_ping:-0} not_att=${not_attached:-0} is_idle=$is_idle is_conn=$is_connected dormant=$dormant carr_chg=$carr_chg carr_up=$carr_up carr_down=$carr_down arp=$arp_state host_ip=${host_ip:-NONE}" >> "$LOG_FILE"
}

# Calculate elapsed seconds since wake was detected
get_wake_elapsed() {
    if [[ -z "$WAKE_DETECTED_TIME" ]]; then
        echo "N/A"
        return
    fi
    local current_time
    current_time=$(date +%s.%N | cut -d. -f1)
    echo $((current_time - WAKE_DETECTED_TIME))
}

# Get human-readable description of interface type
get_interface_type() {
    local iface="$1"
    case "$iface" in
        usb0) echo "CDC ECM" ;;
        usb1) echo "RNDIS" ;;
        *)    echo "unknown" ;;
    esac
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# BOOT TIMING LOG - persistent across reboots for debugging enumeration issues
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Only active when BOOT_TIMING_ENABLED="true"
# Uses system uptime for accurate boot-relative timestamps
# Format: [uptime_secs] WALLCLOCK | STAGE | message

get_uptime_secs() {
    awk '{print $1}' /proc/uptime
}

boot_timing_log() {
    [[ "$BOOT_TIMING_ENABLED" != "true" ]] && return

    local stage="$1"
    local message="$2"
    local uptime wall_clock

    uptime=$(get_uptime_secs)
    wall_clock=$(date '+%Y-%m-%d %H:%M:%S.%N' | cut -c1-26)

    echo "[${uptime}s] ${wall_clock} | ${stage} | ${message}" >> "$BOOT_TIMING_LOG"

    # Echo to stderr for systemd journal capture - allows viewing boot timing with:
    #   journalctl -u usb-ethernet-gadget.service
    # Systemd captures stderr separately from stdout, and the file writes above
    # don't appear in the journal. This provides a second view of timing data.
    echo "[${uptime}s] BOOT_TIMING: ${stage} - ${message}" >&2
}

init_boot_timing_log() {
    [[ "$BOOT_TIMING_ENABLED" != "true" ]] && return

    local kernel_info dwc2_builtin uptime

    uptime=$(get_uptime_secs)
    kernel_info=$(uname -r)

    # Check if dwc2 is built-in (=y) or module (=m) from kernel config
    local dwc2_config
    dwc2_config=$(zcat /proc/config.gz 2>/dev/null | grep "^CONFIG_USB_DWC2=" | cut -d= -f2)
    case "$dwc2_config" in
        m)  dwc2_builtin="module (CONFIG_USB_DWC2=m)" ;;
        y)  dwc2_builtin="built-in (CONFIG_USB_DWC2=y)" ;;
        *)  dwc2_builtin="unknown (CONFIG_USB_DWC2=${dwc2_config:-not found})" ;;
    esac

    {
        echo ""
        echo "========================================================================"
        echo "BOOT SESSION: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Kernel: ${kernel_info}"
        echo "DWC2: ${dwc2_builtin}"
        echo "Script started at uptime: ${uptime}s"
        echo "========================================================================"
    } >> "$BOOT_TIMING_LOG"

    boot_timing_log "SCRIPT_START" "usb-ethernet-gadget.sh launched (uptime: ${uptime}s)"

    # Log current DWC2 state if already initialized
    if [[ -d /sys/bus/platform/drivers/dwc2/fe980000.usb ]]; then
        boot_timing_log "DWC2_STATE" "DWC2 already bound at script start"
    else
        boot_timing_log "DWC2_STATE" "DWC2 NOT bound at script start"
    fi

    # Log UDC state
    local udc_list
    udc_list=$(find /sys/class/udc -maxdepth 1 -mindepth 1 -printf '%f ' 2>/dev/null || true)
    if [[ -n "$udc_list" ]]; then
        boot_timing_log "UDC_STATE" "UDC available: ${udc_list}"
    else
        boot_timing_log "UDC_STATE" "No UDC available yet"
    fi
}

log_usb_state() {
    [[ "$DEBUG_MODE" != "true" ]] && return

    local iface="$1"
    local context="$2"

    local usb_state suspended dsts_susp speed carrier operstate
    local rx_pkts tx_pkts arp_state host_ip

    # USB gadget info
    usb_state=$(cat /sys/class/udc/*/state 2>/dev/null || echo "?")
    suspended=$(cat /sys/class/udc/*/gadget/suspended 2>/dev/null || echo "?")
    dsts_susp=$(get_dsts_suspend_bit)
    speed=$(cat /sys/class/udc/*/current_speed 2>/dev/null || echo "?")

    # Network interface info
    carrier=$(cat /sys/class/net/"$iface"/carrier 2>/dev/null || echo "?")
    operstate=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo "?")
    rx_pkts=$(cat /sys/class/net/"$iface"/statistics/rx_packets 2>/dev/null || echo "?")
    tx_pkts=$(cat /sys/class/net/"$iface"/statistics/tx_packets 2>/dev/null || echo "?")

    # ARP state for known host
    host_ip=$(get_interface_state "$iface" "last_host_ip")
    arp_state="none"
    if [[ -n "$host_ip" ]]; then
        arp_state=$(ip neighbor show dev "$iface" 2>/dev/null | grep "^${host_ip} " | awk '{print $NF}')
        [[ -z "$arp_state" ]] && arp_state="none"
    fi

    debug_log "[$iface] [$context] usb=$usb_state suspended=$suspended dsts=$dsts_susp speed=$speed carrier=$carrier operstate=$operstate arp=$arp_state rx=$rx_pkts tx=$tx_pkts"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~
# USB WAKE DETECTION MODULE
# ~~~~~~~~~~~~~~~~~~~~~~~~~

get_sysfs_suspended() {
    cat /sys/class/udc/*/gadget/suspended 2>/dev/null || echo "?"
}

get_dsts_suspend_bit() {
    local dsts_line dsts_hex

    dsts_line=$(grep DSTS /sys/kernel/debug/usb/fe980000.usb/state 2>/dev/null)
    if [[ -n "$dsts_line" && "$dsts_line" =~ DSTS=0x([0-9a-fA-F]+) ]]; then
        dsts_hex="${BASH_REMATCH[1]}"
        echo $(( 0x$dsts_hex & 1 ))
    else
        echo "?"
    fi
}

get_carrier_changes() {
    # Returns total carrier state changes (up+down)
    local iface="$1"
    cat /sys/class/net/"$iface"/carrier_changes 2>/dev/null || echo "?"
}

get_carrier_up_count() {
    # Returns count of carrier UP events
    local iface="$1"
    cat /sys/class/net/"$iface"/carrier_up_count 2>/dev/null || echo "?"
}

get_carrier_down_count() {
    # Returns count of carrier DOWN events
    local iface="$1"
    cat /sys/class/net/"$iface"/carrier_down_count 2>/dev/null || echo "?"
}

get_interface_dormant() {
    # Returns dormant state: 0=active, 1=dormant (waiting for external event)
    # RFC 2863: dormant means "waiting for some external event"
    local iface="$1"
    cat /sys/class/net/"$iface"/dormant 2>/dev/null || echo "?"
}

# Determines wake/sleep event from current and previous states
determine_wake_event() {
    # Returns: "none", "sleep", "wake", or "unknown"

    local last_suspended="$1"
    local current_suspended="$2"
    local last_dsts="$3"
    local current_dsts="$4"

    # Check for wake transition (suspended -> active)
    if [[ "$last_suspended" == "1" && "$current_suspended" == "0" ]]; then
        echo "wake"
        return
    fi

    # Check for DSTS wake transition
    if [[ "$last_dsts" == "1" && "$current_dsts" == "0" ]]; then
        echo "wake"
        return
    fi

    # Check for sleep transition
    if [[ "$last_suspended" == "0" && "$current_suspended" == "1" ]]; then
        echo "sleep"
        return
    fi

    # Check for DSTS sleep transition
    if [[ "$last_dsts" == "0" && "$current_dsts" == "1" ]]; then
        echo "sleep"
        return
    fi

    # No state change
    if [[ "$current_suspended" == "?" && "$current_dsts" == "?" ]]; then
        echo "unknown"
    else
        echo "none"
    fi
}

# Handle wake/sleep power events and manage counter resets
# Centralizes all power state handling out the main loop
handle_power_events() {
    local current_suspended current_dsts last_suspended last_dsts wake_event

    # Read current USB suspend state
    current_suspended=$(get_sysfs_suspended)
    current_dsts=$(get_dsts_suspend_bit)

    # Get last known states (default to current for first run)
    last_suspended="${STATE[global,last_suspended]:-$current_suspended}"
    last_dsts="${STATE[global,last_dsts]:-$current_dsts}"

    # Log detailed state BEFORE processing for all interfaces
    for iface in "${INTERFACES[@]}"; do
        log_detailed_state "POWER_EVENTS_START" "$iface"
    done

    # Update global state for next iteration (MUST be in main process, not subshell)
    STATE[global,last_suspended]="$current_suspended"
    STATE[global,last_dsts]="$current_dsts"

    # Determine wake event using pure function (safe to call in subshell)
    wake_event=$(determine_wake_event "$last_suspended" "$current_suspended" "$last_dsts" "$current_dsts")

    diagnostic_log "POWER" "Wake event determination: last_sus=$last_suspended cur_sus=$current_suspended last_dsts=$last_dsts cur_dsts=$current_dsts result=$wake_event"

    case "$wake_event" in
        "wake")
            # Only process wake if we were previously sleeping
            diagnostic_log "POWER" "Processing wake event - HOST_IS_SLEEPING=$HOST_IS_SLEEPING"
            if [[ "$HOST_IS_SLEEPING" == "true" ]]; then
                HOST_IS_SLEEPING="false"
                WAKE_DETECTED_TIME=$(date +%s.%N | cut -d. -f1)
                log_message "[USB] Wake detected! suspended: 1→0 (host woke from sleep)"
                log_message "[USB] Host woke up - resetting failure counters and refreshing ARP"
                diagnostic_log "WAKE" "Wake PROCESSED at $(date '+%H:%M:%S') - HOST_IS_SLEEPING set to false, WAKE_DETECTED_TIME=$WAKE_DETECTED_TIME"
                for iface in "${INTERFACES[@]}"; do
                    reset_counters "$iface"
                    set_interface_state "$iface" "is_idle" "false"
                    set_interface_state "$iface" "is_connected" "false"
                    refresh_arp "$iface"
                    diagnostic_log "WAKE" "[$iface] Counters reset and ARP refreshed"
                    log_detailed_state "AFTER_WAKE" "$iface"
                done
            else
                diagnostic_log "WAKE" "Wake event IGNORED - HOST_IS_SLEEPING was already false"
            fi
            ;;
        "sleep")
            # Only process sleep if we weren't already sleeping
            diagnostic_log "POWER" "Processing sleep event - HOST_IS_SLEEPING=$HOST_IS_SLEEPING"
            if [[ "$HOST_IS_SLEEPING" == "false" ]]; then
                HOST_IS_SLEEPING="true"
                WAKE_DETECTED_TIME=""
                log_message "[USB] Sleep detected! suspended: 0→1 (host entering sleep mode)"
                log_message "[USB] Host sleeping - resetting failure counters"
                diagnostic_log "SLEEP" "Sleep PROCESSED at $(date '+%H:%M:%S') - HOST_IS_SLEEPING set to true, WAKE_DETECTED_TIME cleared"
                for iface in "${INTERFACES[@]}"; do
                    reset_counters "$iface"
                    diagnostic_log "SLEEP" "[$iface] Counters reset on sleep detection"
                    log_detailed_state "AFTER_SLEEP" "$iface"
                done
            else
                diagnostic_log "SLEEP" "Sleep event IGNORED - HOST_IS_SLEEPING was already true"
            fi
            ;;
        "none"|"unknown")
            # No state change - nothing to do
            ;;
    esac
}

# ~~~~~~~~~~~~~~~~
# STATE MANAGEMENT
# ~~~~~~~~~~~~~~~~

get_interface_state() {
    local iface="$1"
    local field="$2"
    echo "${STATE[$iface,$field]:-}"
}

set_interface_state() {
    local iface="$1"
    local field="$2"
    local value="$3"
    STATE[$iface,$field]="$value"
}

reset_counters() {
    local iface="$1"
    set_interface_state "$iface" "fail_no_ip" "0"
    set_interface_state "$iface" "fail_no_ping" "0"
    set_interface_state "$iface" "not_attached_count" "0"
}

# Check if interface was previously connected (reads from the persistent state file)
# This survives script restarts, UNLIKE the in-memory STATE array.
# Used to determine appropriate thresholds: faster recovery for known-good connections.
was_previously_connected() {
    local iface="$1"
    if [[ -f "$STATE_FILE" ]]; then
        local state_line connected_once
        state_line=$(grep "^$iface:" "$STATE_FILE" 2>/dev/null || true)
        connected_once=$(echo "$state_line" | cut -d: -f4)
        if [[ "$connected_once" == "true" ]]; then
            return 0
        fi
    fi
    return 1
}

update_state_file() {
    local iface="$1"
    local status="$2"
    local ip="$3"
    local connected_once
    local existing_line
    local tmpfile

    existing_line=$(grep "^${iface}:" "$STATE_FILE" 2>/dev/null || true)
    connected_once=$(echo "$existing_line" | cut -d: -f4)
    if [[ "$status" == "connected" ]]; then
        connected_once="true"
    elif [[ -z "$connected_once" ]]; then
        connected_once="false"
    fi

    # Atomic update: write to temp file, then move to avoid race condition
    tmpfile=$(mktemp "${STATE_FILE}.XXXXXX")
    {
        # Copy all lines except the one for this interface
        grep -v "^${iface}:" "$STATE_FILE" 2>/dev/null || true
        # Add the new/updated line
        echo "${iface}:${status}:${ip}:${connected_once}"
    } > "$tmpfile"
    mv "$tmpfile" "$STATE_FILE"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# USB STATE TRANSITION VALIDATOR
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Validates USB state transitions for debugging unexpected behavior
# Non-blocking: logs warnings but never fails
#
# Valid transitions based on DWC2 driver behavior:
# - not_attached -> suspended (device plugged in, not yet configured)
# - not_attached -> configured (rare: fast enumeration)
# - suspended -> configured (enumeration complete)
# - configured -> suspended (host sleep)
# - suspended -> not_attached (device unplugged while sleeping)
# - configured -> not_attached (device unplugged while active)
# - Any state -> same state (no change)
#
validate_state_transition() {
    local iface="$1"
    local prev_state="$2"
    local new_state="$3"

    # First time seeing state - any state is valid
    [[ -z "$prev_state" || "$prev_state" == "$new_state" ]] && return 0

    # Define valid transitions
    case "$prev_state -> $new_state" in
        "not attached -> suspended")
            return 0
            ;;
        "not attached -> configured")
            diagnostic_log "STATE" "[$iface] Unusual transition: not_attached -> configured (fast enum?)"
            return 0
            ;;
        "suspended -> configured")
            return 0
            ;;
        "configured -> suspended")
            return 0
            ;;
        "suspended -> not attached")
            return 0
            ;;
        "configured -> not attached")
            return 0
            ;;
        *)
            # Invalid transition - log warning but don't fail
            log_message "WARNING: [$iface] Invalid USB state transition: $prev_state -> $new_state"
            diagnostic_log "STATE" "[$iface] INVALID TRANSITION: $prev_state -> $new_state"
            return 1
            ;;
    esac
}

# ~~~~~~~~~~~~~~~~~~~~~
# CONNECTIVITY CHECKING
# ~~~~~~~~~~~~~~~~~~~~~

# Get host IP for an interface using a two-tier approach:
#   1. Return cached IP from state file (fast path - avoids network queries)
#   2. If no cache, discover via ARP (slow path - queries network)
#
# Why cache? During sleep/wake cycles, the host IP should stay the same.
# The separate verify_connectivity() function checks if the host is reachable.
get_host_ip() {
    local iface="$1"
    local stored_ip

    # Check state file for cached IP
    # Use cached IP without pinging
    # Connectivity check will verify if host is actually reachable
    if [[ -f "$STATE_FILE" ]]; then
        stored_ip=$(grep "^$iface:" "$STATE_FILE" | cut -d: -f3)
        if [[ -n "$stored_ip" ]]; then
            debug_log "Using cached host IP $stored_ip on $iface."
            echo "$stored_ip"
            return 0
        fi
    fi

    # Discover via ARP if no cached IP
    discover_host_ip "$iface"
}

discover_host_ip() {
    local iface="$1"
    local ip
    local max_attempts=2
    local attempt=0
    local raw_neighbor_output

    while [[ $attempt -lt $max_attempts ]]; do
        # Capture raw output for debugging
        raw_neighbor_output=$(ip -4 neighbor show dev "$iface" 2>/dev/null)
        debug_log "[$iface] ip neighbor raw output: '$raw_neighbor_output'"

        # Filter for valid IPv4 addresses (not incomplete/failed entries)
        ip=$(echo "$raw_neighbor_output" | \
             awk '$NF ~ /^(REACHABLE|STALE|DELAY|PROBE)$/ {print $1; exit}')

        debug_log "[$iface] discover_host_ip filtered result: '$ip' (attempt $attempt)"

        if [[ -n "$ip" ]]; then
            if [[ $attempt -eq 0 ]]; then
                log_message "Discovered host IP $ip on $iface."
            else
                log_message "Discovered host IP $ip on $iface after ARP refresh."
            fi
            echo "$ip"
            return 0
        fi

        # Only retry once with ARP refresh
        if [[ $attempt -eq 0 ]]; then
            log_message "No host IP found on $iface."
            refresh_arp "$iface"
            sleep 1
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

verify_connectivity() {
    local iface="$1"
    local host_ip="$2"
    local usb_state="$3"

    for _ in $(seq 1 "$PING_COUNT"); do
        if ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$host_ip" &>/dev/null; then
            # Ping successful
            if [[ "$(get_interface_state "$iface" "is_idle")" == "true" ]]; then
                log_message "[$iface] Host resumed - ping successful to $host_ip"
                set_interface_state "$iface" "is_idle" "false"
            fi
            return 0
        fi
    done

    # Ping failed - check if we should use ARP fallback
    # When USB is "configured", check ARP state to determine if this is:
    #   1. Initial connection (ARP shows REACHABLE/STALE/DELAY) -> use ARP fallback, be patient
    #   2. Established connection that became unresponsive -> count as failure for fast reset
    if [[ "$usb_state" == "configured" ]]; then
        # Check ARP state first
        local arp_entry arp_state
        arp_entry=$(ip neighbor show dev "$iface" 2>/dev/null | grep "^$host_ip ")
        if [[ -n "$arp_entry" ]]; then
            arp_state=$(echo "$arp_entry" | awk '{print $NF}')
            case "$arp_state" in
                REACHABLE|STALE|DELAY)
                    # ARP shows valid entry - this is likely initial connection
                    # Device is still negotiating, be patient and use ARP fallback
                    if [[ "$(get_interface_state "$iface" "is_idle")" != "true" ]]; then
                        log_message "[$iface] Host negotiating (ARP $arp_state, ping timeout) - initial connection"
                        set_interface_state "$iface" "is_idle" "true"
                    fi
                    return 0
                    ;;
            esac
        fi

        # No valid ARP entry or ARP expired - this is established connection that became unresponsive
        # Return failure immediately to trigger fast reset
        if [[ "$(get_interface_state "$iface" "is_idle")" == "true" ]]; then
            log_message "[$iface] Host unreachable (configured but ping failed, ARP expired)"
            set_interface_state "$iface" "is_idle" "false"
        fi
        return 1
    fi

    # Check ARP as fallback (only when USB is NOT configured)
    # This handles sleeping hosts where USB is suspended/not attached
    # but ARP entry is still valid
    local arp_entry arp_state
    arp_entry=$(ip neighbor show dev "$iface" 2>/dev/null | grep "^$host_ip ")
    if [[ -n "$arp_entry" ]]; then
        arp_state=$(echo "$arp_entry" | awk '{print $NF}')
        case "$arp_state" in
            REACHABLE|STALE|DELAY)
                if [[ "$(get_interface_state "$iface" "is_idle")" != "true" ]]; then
                    log_message "[$iface] Host sleeping (ARP $arp_state, ping timeout)"
                    set_interface_state "$iface" "is_idle" "true"
                fi
                return 0
                ;;
        esac
    fi

    # Both failed
    if [[ "$(get_interface_state "$iface" "is_idle")" == "true" ]]; then
        log_message "[$iface] Host unreachable (ARP expired)"
        set_interface_state "$iface" "is_idle" "false"
    fi
    return 1
}

# Determine whether to trigger a USB gadget reset based on failure state.
#
# Decision tree with 4 paths:
#
# 1. Post-wake turbo mode (iOS optimization)
#    → Fast reset for iPhone/iPad screen wake
#    → Only active for 15s after wake detection
#
# 2. USB "not attached"
#    → Patient wait (could be sleep/wake cycle)
#    → NOT_ATTACHED_THRESHOLD checks before reset
#
# 3. Was connected, now broken
#    → Fast recovery using RECONNECT_THRESHOLD
#    → Covers: no_ip, no_ping, configured-but-unresponsive
#
# 4. Never connected
#    → Wait patiently, no reset
#    → Like previous.sh philosophy
#
should_trigger_reset() {
    local iface="$1"
    local failure_type="$2"
    local was_previously_connected_status="$3"
    local usb_state="$4"

    local no_ip_count no_ping_count not_attached_count
    no_ip_count=$(get_interface_state "$iface" "fail_no_ip")
    no_ping_count=$(get_interface_state "$iface" "fail_no_ping")
    not_attached_count=$(get_interface_state "$iface" "not_attached_count")

    no_ip_count="${no_ip_count:-0}"
    no_ping_count="${no_ping_count:-0}"
    not_attached_count="${not_attached_count:-0}"

    # PATH 1: Post-wake turbo mode (iOS optimization)
    # Only applies for 15s after wake detection, excludes "not_attached" failures
    if [[ -n "$WAKE_DETECTED_TIME" && "$failure_type" != "not_attached" ]]; then
        local elapsed current_time
        current_time=$(date +%s)
        elapsed=$((current_time - WAKE_DETECTED_TIME))

        if [[ $elapsed -lt 1 ]]; then
            # Within 1-second grace period - don't trigger reset yet
            diagnostic_log "GRACE" "[$iface] In post-wake grace period (${elapsed}s/1s), deferring reset decision"
            return 1
        elif [[ $elapsed -lt "$POST_WAKE_TURBO_DURATION" ]]; then
            # Turbo mode active - use fast threshold
            local check_count=0
            if [[ "$failure_type" == "no_ping" ]]; then
                check_count="$no_ping_count"
            elif [[ "$failure_type" == "no_ip" ]]; then
                check_count="$no_ip_count"
            fi
            check_count="${check_count:-0}"

            # Log entry into turbo mode (once per wake event)
            if [[ "$check_count" -eq 0 ]]; then
                log_message "[$iface] Post-wake turbo mode active (${POST_WAKE_TURBO_INTERVAL}s polling, ${POST_WAKE_FAST_THRESHOLD} check threshold)"
            fi

            if [[ "$check_count" -ge "$POST_WAKE_FAST_THRESHOLD" ]]; then
                log_message "[$iface] RESET PATH: Post-wake turbo (iOS optimization) - ${elapsed}s after wake, ${check_count}/${POST_WAKE_FAST_THRESHOLD} checks"
                diagnostic_log "DECISION" "[$iface] Post-wake fast reset (elapsed: ${elapsed}s, threshold: ${POST_WAKE_FAST_THRESHOLD})"
                return 0
            fi

            diagnostic_log "GRACE" "[$iface] Post-wake turbo mode: ${check_count}/${POST_WAKE_FAST_THRESHOLD} checks (elapsed: ${elapsed}s)"
            return 1
        fi
        # After turbo duration, fall through to normal threshold logic
    fi

    # PATH 2: USB "not attached" (cable unplugged or host sleeping)
    if [[ "$usb_state" == "not attached" ]]; then
        if [[ "$not_attached_count" -ge "$NOT_ATTACHED_THRESHOLD" ]]; then
            log_message "[$iface] RESET PATH: USB not attached for ${not_attached_count} checks (threshold: ${NOT_ATTACHED_THRESHOLD})"
            return 0
        else
            log_message "[$iface] USB not attached (check $not_attached_count/$NOT_ATTACHED_THRESHOLD). Waiting..."
            return 1
        fi
    fi

    # PATH 3: Was connected, now broken (fast recovery)
    # Single threshold for all "was connected" scenarios
    if [[ "$was_previously_connected_status" == "true" ]]; then
        local check_count=0
        if [[ "$failure_type" == "no_ping" ]]; then
            check_count="$no_ping_count"
        elif [[ "$failure_type" == "no_ip" ]]; then
            check_count="$no_ip_count"
        else
            # Unknown failure type - use no_ping as default
            check_count="$no_ping_count"
        fi
        check_count="${check_count:-0}"

        if [[ "$check_count" -ge "$RECONNECT_THRESHOLD" ]]; then
            log_message "[$iface] RESET PATH: Connection lost ($failure_type) - ${check_count}/${RECONNECT_THRESHOLD} checks"
            return 0
        fi

        log_message "[$iface] Connection check #${check_count}/${RECONNECT_THRESHOLD} - waiting before reset..."
        return 1
    fi

    # PATH 4: Never connected - wait patiently (no reset)
    # Like we did in previous code, don't reset if we never had connectivity
    diagnostic_log "WAITING" "[$iface] Never connected - waiting patiently (no reset)"
    return 1
}

refresh_arp() {
    local iface="$1"
    local broadcast

    broadcast=$(ip -4 addr show "$iface" | grep inet | awk '{print $2}' | cut -d/ -f1 | sed 's/\.[0-9]*$/.255/')
    if [[ -n "$broadcast" ]]; then
        ping -c 1 -W 1 -b -I "$iface" "$broadcast" >/dev/null 2>&1
        log_message "Sent broadcast ping to $broadcast on $iface to refresh ARP table."
    fi
}

# ~~~~~~~~~~~~~~~~~~~~~
# USB GADGET MANAGEMENT
# ~~~~~~~~~~~~~~~~~~~~~

get_usb_state() {
    local state_file
    state_file=$(find /sys/class/udc/*/state 2>/dev/null | head -n 1)
    if [[ -f "$state_file" ]]; then
        cat "$state_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

cleanup_gadget() {
    if [[ -d "$GADGET_DIR" ]]; then
        log_message "Cleaning up existing gadget configuration..."
        echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
        sleep 1
        rm -rf "$GADGET_DIR"
    fi
}

generate_mac_addresses() {
    local serial mac_base
    serial=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
    if [[ -z "$serial" ]]; then
        log_message "Error: Could not retrieve Raspberry Pi serial number."
        return 1
    fi
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
    log_message "Created CDC ECM function (ecm.usb0) for Linux/Mac compatibility"
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
    log_message "Created RNDIS function (rndis.usb1) for Windows/Android compatibility"
}

configure_os_descriptors() {
    mkdir -p "$GADGET_DIR/os_desc"
    echo 1 > "$GADGET_DIR/os_desc/use"
    echo 0xcd > "$GADGET_DIR/os_desc/b_vendor_code"
    echo "MSFT100" > "$GADGET_DIR/os_desc/qw_sign"
    ln -s "$GADGET_DIR/configs/c.2" "$GADGET_DIR/os_desc"
}

# Configure the USB gadget in configfs (shared by setup_gadget and reset_gadget)
# This creates the gadget directory, USB descriptors, configurations, and functions.
# Does NOT handle: cleanup, dwc2 loading, UDC binding, or interface bring-up.
# Returns: 0 on success, 1 on failure
configure_gadget_core() {
    local mac_device mac_host serial

    modprobe libcomposite || { log_message "Failed to load libcomposite module."; return 1; }

    mkdir -p "$GADGET_DIR"
    echo "0x1209" > "$GADGET_DIR/idVendor"
    echo "0x2042" > "$GADGET_DIR/idProduct"
    echo "0x0100" > "$GADGET_DIR/bcdDevice"
    echo "0x0200" > "$GADGET_DIR/bcdUSB"

    read -r mac_device mac_host <<< "$(generate_mac_addresses)" || { log_message "Failed to generate MAC addresses."; return 1; }
    serial=$(awk '/Serial/ {print substr($3,5)}' /proc/cpuinfo)
    create_device_strings "$serial"
    create_configuration "c.1" "CDC ECM Configuration"
    create_configuration "c.2" "RNDIS Configuration"
    create_cdc_ecm_function "$mac_host" "$mac_device"
    create_rndis_function "$mac_host" "$mac_device"
    configure_os_descriptors
    return 0
}

bind_gadget_to_udc() {
    local udc state
    boot_timing_log "UDC_BIND" "Checking for UDC..."
    udc=$(find "$UDC_PATH" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -n 1)
    if [[ -n "$udc" ]]; then
        # Log which functions are configured before binding
        local functions_list=""
        for func in "$GADGET_DIR/configs/"*/ecm.* "$GADGET_DIR/configs/"*/rndis.*; do
            [[ -e "$func" ]] && functions_list+="$(basename "$func") "
        done
        log_message "Binding gadget with functions: $functions_list"
        boot_timing_log "UDC_BIND" "Writing to UDC: $udc (functions: $functions_list)"
        echo "$udc" > "$GADGET_DIR/UDC"
        boot_timing_log "UDC_BIND" "Gadget bound to $udc"
        log_message "Bound gadget to UDC $udc."

        # Log the state after binding
        # With DWC2 loaded as a module AFTER gadget configuration, the host
        # should see a fully-configured device from the start - no soft_connect
        # cycle needed.
        state=$(cat "$UDC_PATH/$udc/state" 2>/dev/null || echo "unknown")
        boot_timing_log "UDC_BIND" "Gadget ready (state: $state)"
        log_message "USB gadget ready (state: $state)"

        return 0
    else
        log_message "Error: No UDC device found."
        boot_timing_log "UDC_BIND" "ERROR - No UDC device found!"
        return 1
    fi
}

wait_for_udc() {
    local max_ticks="$1"
    local timing_message="$2"
    local udc_wait=0

    while [[ $udc_wait -lt $max_ticks ]]; do
        if [[ -n "$(find "$UDC_PATH" -maxdepth 1 -mindepth 1 -printf '%f' 2>/dev/null | head -1)" ]]; then
            if [[ -n "$timing_message" ]]; then
                boot_timing_log "SETUP_GADGET" "${timing_message} $((udc_wait * 100))ms"
            fi
            return 0
        fi
        sleep 0.1
        udc_wait=$((udc_wait + 1))
    done

    return 1
}

setup_gadget() {
    # Initial gadget setup at boot - includes detailed timing logs for debugging
    # Uses configure_gadget_core() for the actual configfs setup, then handles
    # DWC2 loading, UDC binding, and interface bring-up with boot timing.

    boot_timing_log "SETUP_GADGET" "=== Starting gadget setup ==="
    log_message "Configuring USB Ethernet gadget..."

    boot_timing_log "SETUP_GADGET" "Cleaning up existing gadget..."
    cleanup_gadget
    boot_timing_log "SETUP_GADGET" "Cleanup complete"

    boot_timing_log "SETUP_GADGET" "Configuring gadget in configfs..."
    configure_gadget_core || { boot_timing_log "SETUP_GADGET" "FAILED to configure gadget"; exit 1; }
    boot_timing_log "SETUP_GADGET" "Gadget configured in configfs"

    # Load DWC2 module AFTER gadget is fully configured via configfs.
    # This is critical for proper USB enumeration with picky hosts.
    #
    # Background: RPi commit 11919d5 (June 2025) changed DWC2 from module to
    # built-in, causing it to initialize at ~0.9s before the gadget is configured.
    # Picky USB hosts see an unconfigured device and cache a "bad state.
    # By keeping DWC2 as a module (blacklisted from auto-load)
    # and loading it here AFTER configfs setup, the host sees a fully-configured
    # device when DWC2 connects to the USB bus.
    boot_timing_log "SETUP_GADGET" "Loading dwc2 module..."
    if modprobe dwc2 2>/dev/null; then
        boot_timing_log "SETUP_GADGET" "dwc2 module loaded"
    else
        # Module may already be loaded or built-in - not an error
        boot_timing_log "SETUP_GADGET" "dwc2 modprobe returned non-zero (may be built-in or already loaded)"
    fi

    # Wait for UDC to appear after dwc2 loads (max 5 seconds at boot)
    boot_timing_log "SETUP_GADGET" "Waiting for UDC to appear..."
    if ! wait_for_udc 50 "UDC appeared after"; then
        log_message "Warning: Timeout waiting for UDC after loading dwc2. Attempting dwc2 reload..."
        boot_timing_log "SETUP_GADGET" "WARNING: Timeout waiting for UDC (5s), attempting dwc2 reload"

        # RETRY LOGIC: Unload and reload dwc2 to recover from transient issues (2 attempts)
        local retry
        for retry in 1 2; do
            modprobe -r dwc2 2>/dev/null
            sleep 1
            modprobe dwc2 2>/dev/null
            boot_timing_log "SETUP_GADGET" "dwc2 reloaded after timeout (retry ${retry}/2)"

            # Wait again with shorter timeout (2 seconds)
            if wait_for_udc 20 "UDC appeared after dwc2 reload (retry ${retry}/2)"; then
                log_message "UDC appeared after dwc2 reload (retry ${retry}/2)"
                break
            fi
        done

        # If still no UDC after retries, fail gracefully to avoid systemd loops
        if [[ -z "$(find "$UDC_PATH" -maxdepth 1 -mindepth 1 -printf '%f' 2>/dev/null | head -1)" ]]; then
            log_message "ERROR: UDC never appeared after dwc2 reload retries. Cannot bind gadget."
            boot_timing_log "SETUP_GADGET" "ERROR: UDC never appeared after dwc2 reload retries"
            GADGET_BOUND="false"
            return 1
        fi
    fi

    # Bind to UDC - host should see fully-configured device
    log_message "Gadget configured, binding to UDC..."
    boot_timing_log "SETUP_GADGET" "Calling bind_gadget_to_udc..."
    bind_gadget_to_udc || { log_message "Failed to bind gadget to UDC."; boot_timing_log "SETUP_GADGET" "FAILED to bind to UDC"; GADGET_BOUND="false"; return 1; }
    boot_timing_log "SETUP_GADGET" "=== Gadget setup complete ==="

    # Wait for interfaces to come up (more patient at boot - max 5s per interface)
    boot_timing_log "SETUP_GADGET" "Waiting for network interfaces..."
    local max_wait waited
    for iface in "${INTERFACES[@]}"; do
        max_wait=10
        waited=0
        while [[ $waited -lt $max_wait ]]; do
            if ip link show "$iface" >/dev/null 2>&1; then
                if ip link set "$iface" up 2>/dev/null; then
                    log_message "Brought $iface up after ${waited}s."
                    boot_timing_log "SETUP_GADGET" "$iface brought up (iteration $waited)"
                else
                    log_message "Failed to bring $iface up or interface not found."
                    boot_timing_log "SETUP_GADGET" "FAILED to bring $iface up"
                fi
                break
            fi
            sleep 0.5
            waited=$((waited + 1))
        done
        if [[ $waited -ge $max_wait ]]; then
            log_message "Timeout waiting for $iface to appear."
            boot_timing_log "SETUP_GADGET" "TIMEOUT waiting for $iface"
        fi
    done

    GADGET_BOUND="true"
}

reset_gadget() {
    # Reset gadget during runtime recovery
    # DWC2 is already loaded and we use shorter timeouts (faster recovery).
    # Uses configure_gadget_core() for the actual configfs setup.

    log_message "Resetting USB Ethernet gadget..."
    cleanup_gadget

    configure_gadget_core || { log_message "Failed to configure gadget."; return 1; }

    # Ensure dwc2 is loaded
    modprobe dwc2 2>/dev/null || true

    # Wait briefly for UDC if needed (shorter timeout than boot - max 2 seconds)
    local udc_wait=0
    while [[ $udc_wait -lt 20 ]]; do
        if [[ -n "$(find "$UDC_PATH" -maxdepth 1 -mindepth 1 2>/dev/null)" ]]; then
            break
        fi
        sleep 0.1
        udc_wait=$((udc_wait + 1))
    done

    bind_gadget_to_udc || { log_message "Failed to bind gadget to UDC."; return 1; }

    # Quick interface bring-up after reset (1s delay for interfaces to appear)
    sleep 1
    for iface in "${INTERFACES[@]}"; do
        if ip link set "$iface" up 2>/dev/null; then
            log_message "Brought $iface up."
        else
            log_message "Failed to bring $iface up or interface not found."
        fi
    done
    return 0
}

# ~~~~~~~~~
# MAIN LOOP
# ~~~~~~~~~

main_loop() {
    local needs_reset usb_state host_ip prev_count conn_result

    while true; do
        if [[ "$GADGET_BOUND" != "true" ]]; then
            log_message "Gadget not bound to UDC. Retrying setup in 10s..."
            sleep 10
            if setup_gadget; then
                boot_timing_log "RECOVERY" "Gadget setup recovered during main loop"
            fi
            continue
        fi

        needs_reset=false

        # 1. Handle wake/sleep power events and reset counters as needed
        handle_power_events

        # 2. Process each interface
        for iface in "${INTERFACES[@]}"; do
            # Log detailed state at start of interface processing
            log_detailed_state "MAIN_LOOP_START" "$iface"

            # 2a. Get USB state and check for transitions
            local prev_usb_state
            prev_usb_state=$(get_interface_state "$iface" "usb_state")
            usb_state=$(get_usb_state)

            diagnostic_log "MAIN" "[$iface] USB state: prev=$prev_usb_state current=$usb_state HOST_IS_SLEEPING=$HOST_IS_SLEEPING"

            set_interface_state "$iface" "usb_state" "$usb_state"

            # Reset failure counters on any USB state transition (except entering not_attached)
            # This prevents failure accumulation during sleep/wake transitions across all device types
            # Handles: configured->suspended (sleep), suspended->configured (wake),
            # not_attached->configured (reconnect), not_attached->suspended, etc.
            if [[ -n "$prev_usb_state" && "$prev_usb_state" != "$usb_state" ]]; then
                # Validate the state transition (non-blocking, for debugging)
                validate_state_transition "$iface" "$prev_usb_state" "$usb_state"

                # Don't reset counters when entering not_attached
                # Reset for all other transitions to ensure fresh start during device state changes
                if [[ "$usb_state" != "not attached" ]]; then
                    log_message "[$iface] USB state transition: $prev_usb_state -> $usb_state - resetting failure counters"
                    reset_counters "$iface"
                    diagnostic_log "RECOVERY" "[$iface] Counters reset on USB state transition ($prev_usb_state->$usb_state)"
                    log_detailed_state "AFTER_USB_TRANSITION" "$iface"
                else
                    diagnostic_log "MAIN" "[$iface] Entering not_attached - NOT resetting counters"
                fi
            fi

            # Debug logging
            log_usb_state "$iface" "loop"

            # 2b. Handle "not attached" state
            if [[ "$usb_state" == "not attached" ]]; then
                prev_count=$(get_interface_state "$iface" "not_attached_count")
                prev_count="${prev_count:-0}"
                if [[ "$prev_count" -eq 0 ]]; then
                    log_message "[$iface] USB disconnected - $(get_interface_type "$iface") (host unplugged or sleeping)"
                fi
                set_interface_state "$iface" "not_attached_count" "$((prev_count + 1))"

                if should_trigger_reset "$iface" "not_attached" "$(was_previously_connected "$iface" && echo "true" || echo "false")" "$usb_state"; then
                    needs_reset=true
                fi
                continue
            else
                # USB reconnected - reset counters
                prev_count=$(get_interface_state "$iface" "not_attached_count")
                prev_count="${prev_count:-0}"
                set_interface_state "$iface" "not_attached_count" "0"
                if [[ "$prev_count" -gt 0 ]]; then
                    log_message "[$iface] USB reconnected - $(get_interface_type "$iface") after $prev_count failed checks. Attempting immediate recovery..."
                fi
            fi

            # 2c. Handle "suspended" state
            if [[ "$usb_state" == "suspended" ]]; then
                # Only log once when entering suspended state, not every iteration
                if [[ "$(get_interface_state "$iface" "suspended_logged")" != "true" ]]; then
                    log_message "[$iface] USB suspended - $(get_interface_type "$iface") (host entered sleep mode)"
                    set_interface_state "$iface" "suspended_logged" "true"
                fi
                continue
            else
                # Not suspended - clear the flag so we log again if it suspends later
                set_interface_state "$iface" "suspended_logged" "false"
            fi

            # 2d. Check interface exists and is up
            if ! ip link show "$iface" >/dev/null 2>&1; then
                if was_previously_connected "$iface"; then
                    log_message "[$iface] Interface no longer exists - $(get_interface_type "$iface") was connected. Triggering reset."
                    needs_reset=true
                fi
                continue
            fi

            if ! ip link show "$iface" | grep -q "state UP"; then
                # Only log once when interface goes down, not every iteration
                if [[ "$(get_interface_state "$iface" "link_down_logged")" != "true" ]]; then
                    log_message "[$iface] Interface is down - $(get_interface_type "$iface")"
                    set_interface_state "$iface" "link_down_logged" "true"
                fi
                if was_previously_connected "$iface"; then
                    log_message "[$iface] Interface was connected but is now down - $(get_interface_type "$iface"). Triggering reset."
                    needs_reset=true
                fi
                continue
            else
                # Interface is up - clear the "logged" flag so we log again if it goes down later
                set_interface_state "$iface" "link_down_logged" "false"
            fi

            # 2e. Check for host IP
            host_ip=$(get_host_ip "$iface")

            if [[ -z "$host_ip" || "$host_ip" == "Address" ]]; then
                # No host IP found - differentiate between initial setup (ARP empty) vs host down (ARP failed)
                # During initial setup, the host needs time to negotiate DHCP and populate ARP
                # Don't count as failure until ARP entry exists (prevents reset loops during first setup)
                local arp_entry_count raw_neighbor_output
                # Count neighbor entries for our subnet to determine if host has completed DHCP negotiation
                raw_neighbor_output=$(ip -4 neighbor show dev "$iface" 2>/dev/null)
                arp_entry_count=$(echo "$raw_neighbor_output" | grep -c "$USB_SUBNET" || true)
                debug_log "[$iface] main_loop: ip neighbor raw='$raw_neighbor_output' count=$arp_entry_count"

                if [[ "$arp_entry_count" -eq 0 ]]; then
                    # ARP table is empty - host hasn't negotiated IP yet (initial setup phase)
                    # Don't count as failure, just wait for DHCP to complete
                    diagnostic_log "SETUP" "[$iface] No ARP entry yet - waiting for host DHCP negotiation"
                    update_state_file "$iface" "waiting" ""
                else
                    # ARP entry exists but host IP not found - count as failure
                    prev_count=$(get_interface_state "$iface" "fail_no_ip")
                    prev_count="${prev_count:-0}"
                    set_interface_state "$iface" "fail_no_ip" "$((prev_count + 1))"
                    set_interface_state "$iface" "fail_no_ping" "0"
                    diagnostic_log "CHECK" "[$iface] ARP has $arp_entry_count entries but no host IP - counting as failure $((prev_count + 1))"

                    # Try ARP refresh on first few failures
                    if [[ "${prev_count:-0}" -le 3 ]]; then
                        refresh_arp "$iface"
                        sleep 1
                        host_ip=$(get_host_ip "$iface")
                        if [[ -n "$host_ip" && "$host_ip" != "Address" ]]; then
                            log_message "[$iface] Found host IP $host_ip after ARP refresh"
                            reset_counters "$iface"
                            update_state_file "$iface" "connected" "$host_ip"
                            set_interface_state "$iface" "last_host_ip" "$host_ip"
                            continue
                        fi
                    fi

                    if should_trigger_reset "$iface" "no_ip" "$(was_previously_connected "$iface" && echo "true" || echo "false")" "$usb_state"; then
                        needs_reset=true
                    else
                        if [[ "$usb_state" == "configured" ]]; then
                            update_state_file "$iface" "waiting" ""
                        fi
                    fi
                fi
            else
                # Host IP found - verify connectivity
                set_interface_state "$iface" "fail_no_ip" "0"
                set_interface_state "$iface" "last_host_ip" "$host_ip"

                verify_connectivity "$iface" "$host_ip" "$usb_state"
                conn_result=$?

                if [[ $conn_result -eq 0 ]]; then
                    # Connected - only log on state transition (not every loop)
                    local was_connected
                    was_connected=$(get_interface_state "$iface" "is_connected")

                    debug_log "[$iface] Connectivity verified to $host_ip"
                    reset_counters "$iface"
                    update_state_file "$iface" "connected" "$host_ip"

                    # Only log connection message on transition from disconnected to connected
                    if [[ "$was_connected" != "true" ]]; then
                        log_message "[$iface] Host connected via $(get_interface_type "$iface") at $host_ip"
                        set_interface_state "$iface" "is_connected" "true"

                        # Only log recovery diagnostic if there was an actual wake event
                        if [[ -n "$WAKE_DETECTED_TIME" ]]; then
                            local elapsed
                            elapsed=$(get_wake_elapsed)
                            diagnostic_log "RECOVERY" "[$iface] Connected after wake (elapsed: ${elapsed}s)"
                        fi
                    fi
                else
                    # Connectivity failed - mark as disconnected for state tracking
                    set_interface_state "$iface" "is_connected" "false"

                    prev_count=$(get_interface_state "$iface" "fail_no_ping")
                    prev_count="${prev_count:-0}"
                    set_interface_state "$iface" "fail_no_ping" "$((prev_count + 1))"
                    local elapsed fail_count
                    elapsed=$(get_wake_elapsed)
                    fail_count=$(get_interface_state "$iface" "fail_no_ping")
                    diagnostic_log "CHECK" "[$iface] Connectivity failed (attempt: $fail_count/$RECONNECT_THRESHOLD, elapsed since wake: ${elapsed}s)"

                    if should_trigger_reset "$iface" "no_ping" "$(was_previously_connected "$iface" && echo "true" || echo "false")" "$usb_state"; then
                        needs_reset=true
                        diagnostic_log "DECISION" "[$iface] Triggering reset after $fail_count failed attempts (elapsed: ${elapsed}s)"
                    else
                        if [[ "$usb_state" == "configured" ]]; then
                            update_state_file "$iface" "waiting" "$host_ip"
                            diagnostic_log "WAITING" "[$iface] Entering waiting state (attempt: $fail_count/$RECONNECT_THRESHOLD, elapsed: ${elapsed}s)"
                        fi
                    fi
                fi
            fi
        done

        # 3. Execute reset if needed
        if [[ "$needs_reset" == "true" ]]; then
            if [[ "$HOST_IS_SLEEPING" == "true" ]]; then
                log_message "Reset deferred - host is sleeping (USB suspended). Will retry after wake."
                diagnostic_log "DECISION" "Reset blocked - host sleeping, waiting for wake"
                needs_reset=false
            else
                local reset_start_time reset_end_time reset_duration
                reset_start_time=$(date +%s)
                diagnostic_log "RESET" "Starting USB gadget reset at $(date '+%H:%M:%S')"

                if reset_gadget; then
                reset_end_time=$(date +%s)
                reset_duration=$((reset_end_time - reset_start_time))
                log_message "USB Ethernet gadget reset successfully (took ${reset_duration}s)."
                diagnostic_log "RESET" "Reset completed in ${reset_duration}s"

                for iface in "${INTERFACES[@]}"; do
                    update_state_file "$iface" "disconnected" ""
                    reset_counters "$iface"
                done
                # Re-initialize wake detection state after reset
                # USB state may have changed during reset, so re-read current values
                STATE[global,last_suspended]=$(get_sysfs_suspended)
                STATE[global,last_dsts]=$(get_dsts_suspend_bit)
                log_message "Reset wake detection state: suspended=${STATE[global,last_suspended]}, dsts=${STATE[global,last_dsts]}"

                # Reset the wake timer after reset to track post-reset recovery
                WAKE_DETECTED_TIME=$(date +%s.%N | cut -d. -f1)
                # Reset sleep tracking - after a reset we don't know host state yet
                HOST_IS_SLEEPING="false"
                diagnostic_log "RESET" "Wake timer and sleep tracking reset after USB reset"
                else
                    log_message "Failed to reset USB Ethernet gadget."
                    diagnostic_log "RESET" "Reset failed at $(date '+%H:%M:%S')"
                fi
            fi
        fi

        # 4. Dynamic sleep interval based on current state
        # The script adjusts polling frequency to balance responsiveness and CPU usage:
        #
        # State                      | Sleep Interval    | Reason
        # ---------------------------|-------------------|--------------------------------
        # USB suspended (sleep)      | 1s                | Watch for wake quickly
        # Connected + turbo mode     | POST_WAKE_TURBO_INTERVAL (1s) | Fast iOS recovery
        # Connected (normal)         | CHECK_INTERVAL (2s) | Standard monitoring
        # Waiting for host           | 1s                | Frequent checks during discovery
        # Disconnected               | INIT_CHECK_INTERVAL (2s) | Standard discovery
        #
        local current_suspended sleep_interval
        current_suspended=$(get_sysfs_suspended)

        if [[ "$current_suspended" == "1" ]]; then
            debug_log "Sleeping 1s (USB suspended - watching for wake)"
            sleep 1
        elif grep -q ":connected:" "$STATE_FILE" 2>/dev/null; then
            # Check if we're in post-wake turbo mode (faster polling for iPadOS/iOS recovery)
            local elapsed
            elapsed=$(get_wake_elapsed)

            if [[ -n "$elapsed" && "$elapsed" != "N/A" && "$elapsed" -lt "$POST_WAKE_TURBO_DURATION" ]]; then
                sleep_interval="$POST_WAKE_TURBO_INTERVAL"
                debug_log "Sleeping ${sleep_interval}s (post-wake turbo mode - ${elapsed}s/${POST_WAKE_TURBO_DURATION}s)"
            else
                sleep_interval="$CHECK_INTERVAL"
                debug_log "Sleeping ${sleep_interval}s (connected state)"
            fi
            sleep "$sleep_interval"
        elif grep -q ":waiting:" "$STATE_FILE" 2>/dev/null; then
            debug_log "Sleeping 1s (waiting state - checking frequently)"
            sleep 1
        else
            debug_log "Sleeping ${INIT_CHECK_INTERVAL}s (disconnected state)"
            sleep "$INIT_CHECK_INTERVAL"
        fi
    done
}

# ~~~~~~~~~~~~~~
# INITIALIZATION
# ~~~~~~~~~~~~~~

initialize() {
    local discovery_attempts max_discovery_attempts discovered
    local host_ip waited max_wait
    local link_state addr_state ip_addr start_time

    init_boot_timing_log

    if ! setup_gadget; then
        log_message "ERROR: Gadget setup failed. Continuing without binding to avoid systemd restart loop."
        boot_timing_log "INIT" "ERROR: Gadget setup failed (no UDC). Skipping initialization steps."
        return 1
    fi

    boot_timing_log "INIT" "Gadget setup complete, initializing state file..."

    for iface in "${INTERFACES[@]}"; do
        update_state_file "$iface" "disconnected" ""
    done

    # Wait for carrier and IP on ANY interface (parallel check)
    boot_timing_log "INIT" "Waiting for any interface to come up..."
    start_time=$(date +%s.%N)
    max_wait=40  # 40 × 0.5s = 20s total (same total time, but parallel)
    waited=0

    # Track per-interface state
    declare -A iface_carrier iface_ip
    for iface in "${INTERFACES[@]}"; do
        iface_carrier[$iface]=false
        iface_ip[$iface]=""
    done

    while [[ $waited -lt $max_wait ]]; do
        for iface in "${INTERFACES[@]}"; do
            # Skip if already got IP on this interface
            [[ -n "${iface_ip[$iface]}" ]] && continue

            link_state=$(ip link show "$iface" 2>/dev/null || true)
            addr_state=$(ip -4 addr show "$iface" 2>/dev/null || true)

            if echo "$link_state" | grep -q "state UP"; then
                if [[ "${iface_carrier[$iface]}" == "false" ]]; then
                    local elapsed
                    elapsed=$(echo "$(date +%s.%N) - $start_time" | bc)
                    log_message "$iface carrier detected after ${elapsed}s"
                    boot_timing_log "INIT" "$iface carrier detected (iteration $waited)"
                    iface_carrier[$iface]=true
                fi

                if echo "$addr_state" | grep -q "inet "; then
                    ip_addr=$(echo "$addr_state" | grep "inet " | awk '{print $2}')
                    log_message "$iface IP address assigned: $ip_addr"
                    boot_timing_log "INIT" "$iface IP assigned: $ip_addr"
                    iface_ip[$iface]="$ip_addr"
                    refresh_arp "$iface"
                fi
            fi
        done

        # Exit early if we have at least one interface with carrier and IP
        for iface in "${INTERFACES[@]}"; do
            if [[ -n "${iface_ip[$iface]}" ]]; then
                boot_timing_log "INIT" "Interface $iface ready, proceeding to host discovery"
                break 2  # Break out of both loops
            fi
        done

        sleep 0.5
        waited=$((waited + 1))
    done

    # Log timeout status for any interfaces that didn't come up
    for iface in "${INTERFACES[@]}"; do
        if [[ -z "${iface_ip[$iface]}" ]]; then
            log_message "Timeout waiting for $iface (carrier: ${iface_carrier[$iface]}, IP: false)"
            boot_timing_log "INIT" "TIMEOUT waiting for $iface (carrier: ${iface_carrier[$iface]})"
        fi
    done

    # Host discovery polling in parallel
    log_message "Starting initial host discovery polling..."
    boot_timing_log "INIT" "Starting host discovery polling (max 10 attempts)..."
    discovery_attempts=0
    max_discovery_attempts=10
    discovered=false

    while [[ $discovery_attempts -lt $max_discovery_attempts ]]; do
        for iface in "${INTERFACES[@]}"; do
            if ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
                host_ip=$(discover_host_ip "$iface")
                if [[ -n "$host_ip" ]]; then
                    log_message "Host discovered on $iface ($(get_interface_type "$iface")): $host_ip"
                    boot_timing_log "INIT" "HOST DISCOVERED on $iface: $host_ip (attempt $discovery_attempts)"
                    set_interface_state "$iface" "last_host_ip" "$host_ip"
                    update_state_file "$iface" "connected" "$host_ip"
                    discovered=true
                fi
            fi
        done

        [[ "$discovered" == "true" ]] && break

        sleep 0.5
        discovery_attempts=$((discovery_attempts + 1))
    done

    if [[ "$discovered" == "false" ]]; then
        boot_timing_log "INIT" "No host discovered after $max_discovery_attempts attempts"
    fi

    # Log startup with interface details
    log_message "Starting USB Ethernet keep-alive monitoring."
    log_message "Monitoring interfaces: ${INTERFACES[*]}"
    log_message "Host will automatically select the appropriate interface."
    boot_timing_log "INIT" "=== Initialization complete, entering main loop ==="

    # Initialize failure counters
    for iface in "${INTERFACES[@]}"; do
        reset_counters "$iface"
    done

    # Initialize global wake detection state
    HOST_IS_SLEEPING="false"
    STATE[global,last_suspended]=$(get_sysfs_suspended)
    STATE[global,last_dsts]=$(get_dsts_suspend_bit)
    log_message "Initial USB suspended state: ${STATE[global,last_suspended]}"
    log_message "Initial DSTS suspend bit: ${STATE[global,last_dsts]}"
    log_message "Host sleep tracking initialized: HOST_IS_SLEEPING=$HOST_IS_SLEEPING"
}

# ~~~~~~~~~~~
# ENTRY POINT
# ~~~~~~~~~~~

{
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ~~~ NEW USB ETHERNET GADGET SESSION START ~~~"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - PID: $$, PPID: $PPID"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
} >> "$LOG_FILE"

initialize || true
main_loop
