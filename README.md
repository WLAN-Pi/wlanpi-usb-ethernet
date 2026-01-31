# wlanpi-usb-ethernet

This package configures a USB Ethernet gadget on the WLAN Pi, providing CDC ECM (usb0) and RNDIS (usb1) interfaces for Ethernet-over-USB connectivity. It includes an integrated setup and keep-alive system to initialize the gadget and monitor connectivity, resetting when necessary.

## Intended Hosts

- **macOS/Linux**: CDC ECM (usb0)
- **iOS/iPhone**: CDC ECM (usb0)
- **Modern Android**: CDC ECM (usb0)
- **Windows**: RNDIS (usb1)

Both interfaces are created by default. Monitoring is controlled by `INTERFACES`.

## Installation

Install the package on a WLAN Pi running WLAN Pi OS (Debian/Armbian-based):

```
sudo dpkg -i wlanpi-usb-ethernet_*.deb
sudo apt-get install -f
```

The package automatically:

- Configures the USB Ethernet gadget with dual interfaces (CDC ECM + RNDIS)
- Runs `usb-ethernet-gadget.sh` to set up and monitor the gadget via `usb-ethernet-gadget.service`

## Keep-alive system

The script (`usb-ethernet-gadget.sh`) initializes the USB gadget and monitors the configured interfaces, handling:

- **Initial enumeration**: Patient waiting for slow hosts
- **Sleep/wake cycles**: Tolerates ~50 seconds of USB disconnection without resetting
- **Connectivity monitoring**: Uses ARP table and ping to verify host reachability
- **Automatic recovery**: Resets the gadget only when determined as necessary, using failure counting to avoid reset loops
  - `fail_no_ip`: No host IP found
  - `fail_no_ping`: IP exists but ping fails
  - `not_attached_count`: USB in "not attached" state
- **Post-wake fast recovery**: Accelerated reset path for iPhone (configurable threshold, default: 1 check after 1s grace period)

The host IP is discovered dynamically via ARP. Actions are logged to `/var/log/usb-ethernet-gadget.log`.

See [State machine](#state-machine)

## Configuration

Edit `/usr/bin/usb-ethernet-gadget.sh` to adjust settings:

### Polling intervals

- `CHECK_INTERVAL`: Seconds between checks when connected (default: 2)
- `INIT_CHECK_INTERVAL`: Seconds between checks during discovery (default: 2)
- `PING_COUNT`: Number of pings per connectivity check (default: 3)
- `PING_TIMEOUT`: Seconds to wait for each ping response (default: 1)

### Failure thresholds

These control how patient the script is before triggering a USB reset. The script uses a simplified 3-threshold system:

- `POST_WAKE_FAST_THRESHOLD`: Failed checks before reset after host wake (default: 1, ~3-5s)
  - Optimized for iPhone/iPad screen wake recovery
  - Only active for 15 seconds after wake detection
  - Ultra-fast reset to restore iOS connectivity

- `RECONNECT_THRESHOLD`: Failed checks before reset when connection was lost (default: 3, ~6s)
  - Single threshold for all "was connected, now broken" scenarios
  - Covers: no IP, ping failures, and unresponsive hosts
  - Fast recovery for established connections

- `NOT_ATTACHED_THRESHOLD`: Checks before reset when USB "not attached" (default: 25, ~50s)
  - Patient wait for sleep/wake cycles
  - Cannot distinguish cable unplug from host sleep, so we wait
  - Prevents unnecessary resets during normal sleep/wake

**Philosophy:**
- Never connected → wait patiently (no reset)
- Was connected → fast recovery (`RECONNECT_THRESHOLD`)
- iOS wake → ultra-fast (`POST_WAKE_FAST_THRESHOLD`)
- USB unplugged → patient (`NOT_ATTACHED_THRESHOLD`)

### Network configuration

- `USB_SUBNET`: Subnet prefix for USB interfaces (default: `"198.18.42"`)
  - Must match `/etc/systemd/network/usb*.network` configuration
  - Full subnet is `${USB_SUBNET}.0/24` (e.g., 198.18.42.0/24)

### Interfaces

- `INTERFACES`: Array of interfaces to monitor (default: `("usb0")`)

Both interfaces are created by default. The host OS will use whichever it supports:
  - CDC ECM (usb0): macOS, Linux, iOS, modern Android 10+
  - RNDIS (usb1): Windows, older Android 9 and earlier

Set to `("usb0")` or `("usb1")` to monitor only one interface if needed.

### Sleep/wake recovery

- `POST_WAKE_FAST_THRESHOLD`: Failed connectivity checks before reset after host wake (default: `1`)
  - Lower values (1): Faster recovery for iPhone (~4-5s), but more aggressive
  - Higher values (3-5): More patient, allows slower hosts to stabilize
  - Timing: 1s grace period + (threshold × ~1s per check)
  - Only applies for 15 seconds after wake detection

### Debug and logging

- `DEBUG_MODE`: Enable verbose diagnostic logging (default: `"true"`)
  - `"true"`: Logs detailed state transitions, timing, and diagnostics
  - `"false"`: Only logs important events (recommended for production)

- `BOOT_TIMING_ENABLED`: Enable boot timing log (default: `"false"`)
  - `"true"`: Writes detailed boot timing to `/var/log/usb-gadget-boot-timing.log`
  - `"false"`: Disabled (recommended for production)
  - Manually enable when debugging early boot USB enumeration problems

After changes, restart the service:

```
sudo systemctl restart usb-ethernet-gadget.service
```

## Logs

Monitor logs for debugging. For advanced debugging, enable `DEBUG_MODE`.

```
# Main operational log
tail -f /var/log/usb-ethernet-gadget.log

# Systemd service logs
journalctl -u usb-ethernet-gadget.service -f
```

To analyze boot timing enable `BOOT_TIMING_ENABLED` in the script, then check:

```
# Boot timing log (only when BOOT_TIMING_ENABLED="true")
cat /var/log/usb-gadget-boot-timing.log
```

## Verifying Connection State

```
# View current connection state
cat /var/run/usb-ethernet-gadget.state
# Format: interface:status:host_ip:connected_once

# Check USB gadget state
cat /sys/class/udc/*/state

# View ARP table for interface
arp -n -i usb0
```

## Troubleshooting

### Device won't connect

1. Check USB gadget state:
   ```
   cat /sys/class/udc/*/state
   ```
   - `configured`: USB is connected and enumerated
   - `not attached`: USB cable disconnected or host sleeping
   - `suspended`: Host has suspended USB

2. Verify interface is up:
   ```
   ip link show usb0
   ```

3. Check for host in ARP table:
   ```
   arp -n -i usb0
   ```

4. Review logs for failure patterns:
   ```
   grep "Triggering reset" /var/log/usb-ethernet-gadget.log | tail -10
   ```

### Commands

```
# Enable debugs

ssh wlanpi@198.18.42.1 "sudo sed -i 's/DEBUG_MODE=\"false\"/DEBUG_MODE=\"true\"/' /usr/bin/usb-ethernet-gadget.sh && echo 'DEBUG_MODE enabled'"
DEBUG_MODE enabled


# Clear logs and restart service

ssh wlanpi@198.18.42.1 "sudo sh -c '> /var/log/usb-ethernet-gadget.log' && sudo systemctl restart usb-ethernet-gadget.service && echo 'Service restarted with debug enabled'"
```

### Reset loops

If the device keeps resetting, the failure thresholds may need adjustment for the host. Increase the relevant threshold values in the script.

## State machine

The keep-alive system uses a state machine to handle sleep/wake cycles and connectivity:

```
[INIT]
  ↓
[CONNECTED]   ──────────────────┐
  ↓                             │
[SLEEP DETECTED]                │
  • Log once                    │
  • Reset counters              │
  • HOST_IS_SLEEPING=true       │
  ↓                             │
[HOST SLEEPING]                 │
  • Block USB resets            │
  • Monitor for wake            │
  ↓                             │
[WAKE DETECTED] ────────────────┤
  • Reset counters              │
  • Refresh ARP                 │
  • Start 1s grace period       │
  ↓                             │
[POST-WAKE FAST RESET MODE]     │
  • 1s grace: no reset          │
  • After grace: fast threshold │
  • POST_WAKE_FAST_THRESHOLD    │
    failed checks -> reset      │
  • 15s window, then normal     │
  ↓                             │
[USB RESET]                     │
  • Re-enumerate gadget         │
  • Re-discover host            │
  └─────────────────────────────┘
```

**Key states:**

- **Sleep detection**: Uses USB suspend flag (sysfs) and DSTS register to detect host sleep
- **Wake detection**: Monitors for suspend flag clearing (1→0 transition)
- **Post-wake fast reset**: Accelerated reset path for iPhone recovery
  - 1-second grace period (no reset decisions)
  - `POST_WAKE_FAST_THRESHOLD` failed checks triggers reset (default: 1)
  - Only active for 15 seconds after wake
- **Reset blocking**: Prevents reset while `HOST_IS_SLEEPING=true` to avoid stuck state

**Failure thresholds:**

| Scenario | Threshold | Approx. Time |
|----------|-----------|--------------|
| Post-wake fast reset | `POST_WAKE_FAST_THRESHOLD` | ~3-5s |
| Reconnect (was connected) | `RECONNECT_THRESHOLD` | ~6s |
| Not attached | `NOT_ATTACHED_THRESHOLD` | ~50s |
| Never connected | (none) | Wait patiently |

### Dynamic sleep intervals

The script adjusts its polling frequency based on current state:

- **USB suspended**: 1 second (watching for wake)
- **Connected**: `CHECK_INTERVAL` seconds (default: 2)
- **Waiting for host**: 1 second (frequent checks during discovery)
- **Disconnected**: `INIT_CHECK_INTERVAL` seconds (default: 2)

### ARP refresh on failure

When the host IP cannot be found or ping fails, the script automatically refreshes the ARP table:

- **First 3 failures**: Sends broadcast ping to subnet to refresh ARP entries
- **Caches host IP**: Stores discovered IP in state file to avoid repeated ARP queries
- **Fallback to ARP**: If ping fails but ARP shows REACHABLE/STALE/DELAY, considers host reachable (handles sleeping hosts)

### Host firewall blocking ICMP

The keep-alive uses ping to verify connectivity. If your host blocks ICMP, the script will fall back to ARP state checking, but connectivity verification may be less reliable.

### Clock sync (to improve log analysis)

When using the WLAN Pi as a USB device without Internet, NTP CANNOT sync the clock. This can make analyzing logs difficult. Consider to sync time from your host for accurate log timestamps:

```
ssh wlanpi@198.18.42.1 "sudo date -s '$(date -u +"%Y-%m-%d %H:%M:%S")'"
```

## Building the Package

Clone the repository and build the .deb package:

```
git clone https://github.com/WLAN-Pi/wlanpi-usb-ethernet.git
cd wlanpi-usb-ethernet
dpkg-buildpackage -b -us -uc
```

The resulting .deb file will be in the parent directory.

## License

This project is licensed under the BSD-3-Clause License. See the LICENSE file for details.
