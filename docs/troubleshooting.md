# XRP-Portkey — Troubleshooting Guide

This guide helps diagnose common issues with Wi‑Fi, DHCP/IP assignment, Tailscale auth/exit nodes,
Ethernet sharing (dnsmasq + iptables), DNS, and boot persistence.

## Table of Contents

- [Quick Reference](#quick-reference--commands-youll-use-often)
- [1) Wi-Fi: Not connecting, or no IP on wlan0](#1-wi-fi-not-connecting-or-no-ip-on-wlan0)
- [2) DHCP / DNS basics](#2-dhcp--dns-basics)
- [3) Tailscale: Authentication / not listed / wrong tailnet](#3-tailscale-authentication--not-listed--wrong-tailnet)
- [4) Exit node: “offers exit node” but Pi isn’t using it](#4-exit-node-offers-exit-node-but-pi-isnt-using-it)
- [5) Tailscale can’t reach configured DNS servers](#5-tailscale-cant-reach-configured-dns-servers)
- [6) Ethernet sharing (dnsmasq): Client gets no IP](#6-ethernet-sharing-dnsmasq-client-gets-no-ip)
- [7) Ethernet sharing: Has IP but no internet](#7-ethernet-sharing-has-ip-but-no-internet)
- [8) Persistence on boot (systemd service)](#8-persistence-on-boot-systemd-service)
- [9) Resetting pieces safely (when stuck)](#9-resetting-pieces-safely-when-stuck)
- [10) Preserving or changing Tailscale IP](#10-preserving-or-changing-tailscale-ip)
- [Log Collections (for bug reports)](#log-collections-for-bug-reports)
- [Security Notes](#security-notes)

## Quick Reference — Commands You’ll Use Often

Services & status  
  ```
  systemctl status wpa_supplicant@wlan0
  systemctl status dhcpcd
  systemctl status tailscaled
  systemctl status dnsmasq
  journalctl -u portkey-boot.service --no-pager -n 200
  ```

Networking checks  
  ```
  iwgetid -r                      # current SSID
  ip -4 addr show wlan0           # IP on Wi‑Fi
  ip -4 addr show eth0            # IP on Ethernet
  ip route                        # routing table
  ping -c3 1.1.1.1                # raw connectivity
  ping -c3 google.com             # DNS + connectivity
  curl ifconfig.me                # public IP (should match exit node)
  ```

Tailscale  
  ```
  tailscale status --self
  tailscale status
  tailscale ip -4
  sudo tailscale up --exit-node=<name> --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true
  sudo tailscale down && sudo tailscale up
  ```

Firewall/NAT  
  ```
  iptables -t nat -L -v -n
  iptables -t nat -S
  iptables-restore < /etc/iptables/rules.v4    # re-apply saved rules
  ```

## 1) Wi‑Fi: Not connecting, or no IP on wlan0

Symptoms
- 'iwgetid -r' shows nothing
- 'ip -4 addr show wlan0' has no 'inet' line
- 'wpa_cli reconfigure' gives 'FAIL'

Fix
1. Ensure NetworkManager is not fighting wpa_supplicant:
   ```
   sudo systemctl stop NetworkManager 2>/dev/null || true
   sudo systemctl disable NetworkManager 2>/dev/null || true
   ```
   
2. Verify config file exists and permissions are strict:
   ```
   ls -l /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
   sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
   ```
   
3. (Re)enable the Wi‑Fi stack:
   ```
   sudo systemctl enable wpa_supplicant@wlan0 dhcpcd
   sudo systemctl restart wpa_supplicant@wlan0 dhcpcd
   ```
   
4. Check logs:
   ```
   journalctl -u wpa_supplicant@wlan0 -n 100 --no-pager
   ```
5. SSID/PSK typos or band issues (2.4 vs 5 GHz) are common. Try proximity to AP.

6. Country code must match locale for channels:
   ```
   Ensure 'country=US' (or your country) in wpa_supplicant file.
   ```
   
## 2) DHCP / DNS basics

Symptoms
- Can ping 1.1.1.1 but 'ping google.com' fails
- DNS timeout messages

Fix
- Your exit-node DNS is accepted when using '--accept-dns=true'.
- If captive portals or enterprise DNS interfere, temporarily disable accept-dns:
  ```
  sudo tailscale up --accept-dns=false
  ```
- Verify '/etc/resolv.conf' is not statically overridden by other tools.


## 3) Tailscale: Authentication / not listed / wrong tailnet

Symptoms
- 'tailscale status' shows 'offline' or not in your tailnet
- 'tailscale up' printed a URL you didn’t open

Fix
  ```
  sudo systemctl enable --now tailscaled
  sudo tailscale up             # open the URL and authorize
  tailscale status --self
  ```

If the device joined the wrong tailnet, run:
  ```
  sudo tailscale logout
  sudo tailscale up
  ```

## 4) Exit node: “offers exit node” but Pi isn’t using it

Symptoms
- 'tailscale status' shows another device “offers exit node”
  but your Pi’s public IP (curl ifconfig.me) is unchanged.

Fix
- The Pi must explicitly opt‑in:
  ```
  sudo tailscale up --exit-node=<exitnode-name> --accept-routes=true --accept-dns=true --exit-node-allow-lan-access=true
  ```
  
- Confirm admin side:
  In Tailscale admin, the exit node device has “Use as exit node” enabled.
  If using “Allow LAN access,” enable it as well on that node.

- Re-check:
  ```
  tailscale status --self
  curl ifconfig.me
  ```
  
Note: Seeing “relay/DERP” in status is okay; it just means UDP is relayed.

## 5) Tailscale can’t reach configured DNS servers

Symptoms
- Health check warning: “can’t reach the configured DNS servers”

Fix
- Usually transient; verify general connectivity:
  ```
  ping -c3 1.1.1.1
  ping -c3 google.com
  ```
  
- If on restrictive networks, try:
  ```
  sudo tailscale up --accept-dns=false
  ```
  or verify that your exit node’s DNS is reachable from the exit node itself.

## 6) Ethernet sharing (dnsmasq): Client gets no IP

Checks
- dnsmasq running?
  ```
  systemctl status dnsmasq
  ```
  
- Config file exists and references eth0:
  ```
  cat /etc/dnsmasq.conf
  (should contain: interface=eth0 and a dhcp-range)
  ```
  
- Is eth0 up and has the gateway IP?
  ```
  ip -4 addr show eth0   (should include 192.168.88.1/24)
  ```
  
- Cables/adapters OK? Try another cable/port.

Reset dnsmasq quickly:
  ```
  sudo systemctl restart dnsmasq
  ```

## 7) Ethernet sharing: Has IP but no internet

Checks
- NAT rules in place?
  ```
  iptables -t nat -S
  ```
  Look for:
  -A POSTROUTING -o tailscale0 -j MASQUERADE

- Forward rules in place?
   ```
   iptables -S | grep FORWARD
   ```

- Re-apply saved rules if needed:
  ```
  sudo iptables-restore < /etc/iptables/rules.v4
  ```

- Ensure IP forwarding is enabled:
  ```
  grep net.ipv4.ip_forward /etc/sysctl.conf
  ```
  If missing:
  ```
  echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  ```
  
## 8) Persistence on boot (systemd service)

Symptoms
- After reboot, Wi‑Fi/Tailscale/Ethernet share not applied.

Checks
  ```
  systemctl status portkey-boot.service
  journalctl -u portkey-boot.service -n 200 --no-pager
  ```

Fix
- Ensure the script is executable:
 ```
  ls -l /usr/local/bin/portkey-boot.sh
  sudo chmod +x /usr/local/bin/portkey-boot.sh
  ```

- Re-enable the service:
  ```
  sudo systemctl daemon-reload
  sudo systemctl enable portkey-boot.service
  sudo systemctl start portkey-boot.service
  ```
- Confirm tailscaled & Wi‑Fi services are enabled:
  ```
  sudo systemctl enable tailscaled wpa_supplicant@wlan0 dhcpcd
  ```
  
## 9) Resetting pieces safely (when stuck)

Wi‑Fi stack:
  ```
  sudo systemctl restart wpa_supplicant@wlan0 dhcpcd
  ```

Tailscale (keeps preferences):
  ```
  sudo tailscale down || true
  sudo tailscale up --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true
  ```

dnsmasq:
  ```
  sudo systemctl restart dnsmasq
  ```

Reapply NAT rules:
  ```
  iptables-restore < /etc/iptables/rules.v4
  ```

## 10) Preserving or changing Tailscale IP

Keep the same 100.x IP across reinstalls by backing up and restoring:
  ```
  /var/lib/tailscale/tailscaled.state
 ```
**Treat this file as a secret (don’t commit to Git).**

## Log Collections (for bug reports)

  ```
  uname -a
  tailscale version
  tailscale status
  tailscale status --self
  journalctl -u tailscaled -n 200 --no-pager
  journalctl -u wpa_supplicant@wlan0 -n 200 --no-pager
  journalctl -u dnsmasq -n 200 --no-pager
  ip addr; ip route
  iptables -t nat -S; iptables -S
  cat /etc/dnsmasq.conf
  cat /etc/wpa_supplicant/wpa_supplicant-wlan0.conf (redact PSKs)
  ```

## Security Notes

- Don’t commit secrets (Wi‑Fi PSKs, auth keys, tailscaled.state) to Git.
- Prefer MagicDNS + hostname over hardcoding numeric addresses.
- Limit who can access your exit node; review ACLs in Tailscale admin.
