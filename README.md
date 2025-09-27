# wlanpi-usb-ethernet

This package configures a USB Ethernet gadget on the WLAN Pi, providing CDC ECM (usb0) and RNDIS (usb1) interfaces for Ethernet-over-USB connectivity. It includes an integrated setup and keep-alive system to initialize the gadget and monitor connectivity, resetting it when necessary.

## Installation

Install the package on a WLAN Pi running WLAN Pi OS (Debian/Armbian-based):

```
sudo dpkg -i wlanpi-usb-ethernet_0.0.4_*.deb
sudo apt-get install -f
```

The package automatically:

- Configures the USB Ethernet gadget with dual interfaces.
- Runs usb-ethernet-gadget.sh to set up and monitor the gadget via usb-ethernet-gadget.service.

## Keep-Alive System

The script (usb-ethernet-gadget.sh) initializes the USB gadget and monitors usb0 and usb1, resetting the gadget if a previously established connection to the host is lost. It uses the ARP table to dynamically discover the host’s IP address for each interface, refreshes the ARP table with broadcast pings if needed, and uses ping to check connectivity. Actions are logged to /var/log/usb-ethernet-gadget.log.

## Configuration

Edit `/usr/local/bin/usb-ethernet-gadget.sh` to adjust settings:

- CHECK_INTERVAL: Seconds between checks (default: 10).
- PING_COUNT: Number of pings to send (default: 3).
- INTERFACES: Interfaces to monitor (default: usb0 and usb1). Set to ("usb0") if usb1 is unused.

The host IP is discovered dynamically via ARP, eliminating the need for a static HOST_IP. To verify the discovered IP:

```
cat /var/run/usb-ethernet-gadget.state
arp -n -i usb0
arp -n -i usb1
```

After changes, restart the service:

```
sudo systemctl restart usb-ethernet-gadget.service
```

## Logs

Monitor logs for debugging:

```
tail -f /var/log/usb-ethernet-gadget.log
journalctl -u usb-ethernet-gadget.service -f
```

## Troubleshooting

If usb0 remains disconnected:

Verify the host’s IP:

```
arp -n -i usb0
ping -c 3 -I usb0 <host_ip>
```

Test ARP parsing:

```
arp -n -i usb0 | grep -v incomplete | grep -v Address | awk '{print $1}' | head -n 1
```

Check interface status:

```
ip a show usb0
```

Ensure the host allows ICMP (disable firewall temporarily if needed).

If usb1 is unused, set INTERFACES=("usb0") in the script.

Inspect logs for ARP output:grep "ARP output" /var/log/usb-ethernet-gadget.log

## Building the Package

Clone the repository and build the .deb package:

```
git clone https://github.com/WLAN-Pi/wlanpi-usb-ethernet.git -b keep-alive
cd wlanpi-usb-ethernet
dpkg-buildpackage -b -us -uc
```

The resulting .deb file will be in the parent directory.

## License

This project is licensed under the BSD-3-Clause License. See the LICENSE file for details.
