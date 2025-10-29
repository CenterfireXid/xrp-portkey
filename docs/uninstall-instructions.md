# XRP-Portkey — Uninstall Instructions

This document explains how to remove XRP-Portkey and revert the system to your preferred Wi-Fi behavior.

## RUN THE UNINSTALLER
Use the interactive script bundled with this repo:
  ```
  sudo bash ./scripts/uninstall-portkey.sh
  ```
## WHAT THE UNINSTALLER DOES
- Stops & disables Portkey services:
  - portkey-boot.service
  - dnsmasq (only if you enabled Ethernet sharing)

- Cleans up Ethernet sharing:
  - Removes NAT/iptables rules targeting tailscale0
  - Clears 192.168.88.1/24 from eth0
  - Optionally deletes /etc/iptables/rules.v4
  - Reverts net.ipv4.ip_forward in /etc/sysctl.conf

- Offers Wi-Fi revert modes (you choose one):
  - **(K) Keep:** leave wpa_supplicant@wlan0 / dhcpcd and the existing config as-is.
  - **(D) Disable:** stop + disable wpa_supplicant@wlan0 and dhcpcd (no auto Wi-Fi on boot).
  - **(F) Factory:** install/enable NetworkManager (first, while Wi-Fi is still up), clear saved
                 wpa_supplicant networks, then stop + disable wpa_supplicant@wlan0 and dhcpcd.
                 Afterward, NetworkManager manages Wi-Fi (use nmcli).

- Optionally uninstalls Tailscale, with an extra prompt to remove device state (/var/lib/tailscale)
  if you want to forget the identity (device will need to re-auth next time).

## AFTER UNINSTALL — OPTIONAL SANITY CHECKS
You can quickly confirm the system state with:

**Services should be stopped/disabled**
systemctl status portkey-boot.service
systemctl is-enabled dnsmasq || true

**If you chose Factory mode, NetworkManager should be running:**
systemctl is-active NetworkManager

**iptables NAT to tailscale0 should be absent**
sudo iptables -t nat -S | grep tailscale0 || echo "No Portkey NAT rules found."

> [!TIP]
>If you switched to NetworkManager, connect to Wi-Fi with:  
>  ```
>  nmcli dev wifi list  
>  nmcli dev wifi connect "SSID" password "PSK"
>  ```

## NOTES & RECOMMENDATIONS
- Keep backups made by the uninstaller (e.g., wpa_supplicant-wlan0.conf.bak.<timestamp>) until you confirm everything works.
- If you later re-install Portkey, you can use install-portkey.sh again; it will re-assert the services and NAT/DHCP.
- If you removed /var/lib/tailscale and re-install Tailscale, the device will appear as a new node in your tailnet.
EOF
