# XRP-Portkey — Verification

Use this checklist to confirm XRP‑Portkey is working after installation or any change.

## 1) Verify Wi‑Fi connectivity on the Pi (wlan0)

Wi‑Fi connected and has an IP?
  ```
  iwgetid -r
  ip -4 addr show wlan0 | grep inet
  ```

Basic connectivity & DNS
  ```
  ping -c3 1.1.1.1
  ping -c3 google.com
  ```

Expected:
- 'iwgetid -r' prints your SSID.
- An 'inet' line on wlan0 (e.g., 192.168.x.x).
- Both pings succeed (DNS works if google.com resolves).

## 2) Verify Tailscale login & device state

  Tailscale service and identity
  ```
  systemctl status tailscaled
  tailscale status --self
  tailscale ip -4
  ```

Expected:
- tailscaled is 'active (running)'.
- status shows your hostname and 'linux' platform.
- 'tailscale ip -4' prints a 100.x.x.x address.

If not:
- Log in again:   sudo tailscale up
- Or reauth with a key: sudo tailscale up --authkey=<tskey-...>

## 3) Confirm exit‑node routing on the Pi

  Choose/confirm exit node (replace name)
  ```
  sudo tailscale up --exit-node=<EXIT_NODE_NAME> \
    --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true
  ```

  Public IP should match your exit node’s WAN IP
  ```
  curl ifconfig.me
  ```

  Optional: show peers and roles
  ```
  tailscale status
  ```

Expected:
- Public IP equals the exit node’s WAN IP (check on that device if needed).
- 'tailscale status' lists the exit node with 'idle: exit node' (or 'offers exit node')
  and your Pi shows 'active' with a relay region (e.g., 'dfw') — relayed is OK.

If not:
- Ensure the exit node has “Use as exit node” enabled in the Tailscale admin.
- Re-run the 'tailscale up' command above.
- If DNS warnings appear, try: sudo tailscale up --accept-dns=false

## 4) Verify Ethernet sharing (optional feature)

On the Pi:
  NAT rules and forwarding
  ```
  iptables -t nat -S | grep MASQUERADE
  grep net.ipv4.ip_forward /etc/sysctl.conf
  ```

  Ethernet interface is up with gateway IP
  ```
  ip -4 addr show eth0
  ```

On the connected device (laptop/TV via cable to the Pi):
- It should receive an IP in 192.168.88.10–192.168.88.20.
- Run:
  ```
    curl ifconfig.me
  ```
  This should match your exit node’s public IP.

If not:
- Check dnsmasq:   systemctl status dnsmasq
- Restart dnsmasq: sudo systemctl restart dnsmasq
- Reapply iptables: iptables-restore < /etc/iptables/rules.v4

## 5) Verify persistence across reboot

  Ensure services are enabled
  ```
  systemctl is-enabled wpa_supplicant@wlan0 dhcpcd tailscaled portkey-boot.service
  ```

  Reboot and re-check
  ```
  sudo reboot
  ```

After reboot (on the Pi):
  ```
  iwgetid -r
  tailscale status --self
  curl ifconfig.me
  iptables -t nat -L POSTROUTING -v -n | head -n 10
  ```

Expected:
- Wi‑Fi reconnects automatically.
- Tailscale shows as active and 'curl ifconfig.me' still returns the exit node IP.
- NAT POSTROUTING shows counters increasing when the Ethernet client is active.

## 6) (Optional) LED status sanity check (future feature placeholder)

If you implement an LED health script:
- LED blinks 3x when exit‑node routing is OK (curl ifconfig.me matches exit node).
- LED does a slow pulse if Wi‑Fi is down or Tailscale is offline.
- LED off when portkey‑boot service hasn’t run yet.

## 7) Snapshot report (for your own records or bug reports)

Collect these into a text file:
  ```
  echo "== whoami =="; hostnamectl
  echo "== tailscale =="; tailscale version; tailscale status --self
  echo "== ips =="; ip -4 addr; ip route
  echo "== public =="; curl -s ifconfig.me; echo
  echo "== services =="; systemctl is-active wpa_supplicant@wlan0 dhcpcd tailscaled dnsmasq
  echo "== nat =="; iptables -t nat -S
  ```

## Done!

If everything above checks out, XRP‑Portkey is configured correctly.
