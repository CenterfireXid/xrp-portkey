# XRP-Portkey — Manual Setup (Beginner-Friendly)

### This is a “for dummies” style walkthrough you can follow line-by-line. It explains what each command does, how to confirm it worked, and what to do if it didn’t.

## 0) Before you start (5 min)

You need:
- A Raspberry Pi (Pi 4B recommended) running Raspberry Pi OS Lite (no desktop is fine).
- A way to type commands on the Pi (HDMI + keyboard OR SSH).
- Your Wi-Fi names (SSIDs) and passwords.
- A Tailscale account and ONE machine already set as an Exit Node
  (turn on “Use as exit node” in the Tailscale admin; optional “Allow LAN access”).

What we’re building:
Your Pi will auto-join your saved Wi‑Fi, log into Tailscale, and route its traffic
(and optionally a device on its Ethernet port) through your chosen Tailscale exit node.

## 1) Update the Pi and install basics (10 min)

Why: Keeps packages current and installs tools we’ll use (DNS/DHCP for Ethernet sharing,
firewall/NAT, and curl).

Do this:
   ```
  sudo apt update && sudo apt full-upgrade -y
  sudo apt install -y iptables-persistent dnsmasq dhcpcd5 curl
   ```

Check it worked: No errors on screen.
If it fails: run 'sudo apt update' again; verify internet with 'ping -c3 1.1.1.1'.

## 2) Make Wi‑Fi auto-connect (wlan0) (5–10 min)

Why: The Pi needs to hop on known Wi‑Fi by itself (headless). We’ll use wpa_supplicant
to store your networks.

1) Turn off NetworkManager (so it doesn’t fight wpa_supplicant):
  ```
  sudo systemctl stop NetworkManager 2>/dev/null || true
  sudo systemctl disable NetworkManager 2>/dev/null || true
  ```

2) Create the Wi‑Fi config file (replace SSIDs/passwords):

  ```
  sudo tee /etc/wpa_supplicant/wpa_supplicant-wlan0.conf >/dev/null <<'EOF'
  ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
  update_config=1
  country=US
  network={ ssid="{PhoneHotspot" psk="hospotpassword" priority=1 }
  network={ ssid="FriendsWiFi" psk="friendspassword" priority=2 }
  network={ ssid="HomeWiFi"    psk="homepassword"    priority=3 }
  EOF
  sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  ```

4) Turn on Wi‑Fi services:
  ```
  sudo systemctl enable wpa_supplicant@wlan0 dhcpcd
  sudo systemctl start  wpa_supplicant@wlan0 dhcpcd
  ```

Check it worked:
  ```
  iwgetid -r                         # should print your Wi‑Fi name
  ip -4 addr show wlan0 | grep inet  # should show an IP like 192.168.x.x
  ping -c3 google.com                # should succeed
  ```

If it fails:
- 'iwgetid -r' is empty -> SSID/PSK typo, wrong band (2.4 vs 5 GHz), or weak signal.
- 'wpa_cli reconfigure' shows “FAIL” -> ensure wpa_supplicant@wlan0 is enabled and
  NetworkManager is disabled (above).

## 3) Install Tailscale and pick your exit node (5 min)

Why: Tailscale gives the Pi a secure identity, lets it send all traffic through
your chosen exit node, and creates an encrypted tunnel on the way there to protect your traffic.

Do this:
  ```
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo systemctl enable --now tailscaled
  sudo tailscale up
  ```

- The last command prints a URL. Open it on your phone/computer to authorize the Pi
  into your Tailscale network.

Choose your exit node (replace with your node’s name without the <>):
  ```
  sudo tailscale up --exit-node=<EXIT_NODE_NAME> \
    --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true
  ```

Check it worked:
  ```
  tailscale status --self
  curl ifconfig.me     # should now show your exit node’s public IP
  ```

If it fails:
- “not authorized” -> re-run 'sudo tailscale up' and open the URL again to log in.
- Wrong public IP -> make sure the exit node is enabled in the admin and you passed
  '--exit-node=<name>'.

## 4) (Optional) Share the tunnel to a device on Ethernet (eth0) (10 min)

Why: Let a laptop/TV plugged into the Pi’s Ethernet port ride the same encrypted tunnel.

Do this:
  # Enable routing through the Pi
  ```
  echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  ```

  # Give eth0 a small private network and bring it up
  ```
  sudo ip addr add 192.168.88.1/24 dev eth0
  sudo ip link set eth0 up
  ```

  # NAT: send traffic from eth0 out over the Tailscale tunnel
  ```
  sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
  sudo iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
  sudo iptables -A FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
  ```

  # Hand out IPs to the connected device
  ```
  echo -e "interface=eth0\ndhcp-range=192.168.88.10,192.168.88.20,12h" | sudo tee /etc/dnsmasq.conf
  sudo systemctl enable dnsmasq && sudo systemctl restart dnsmasq
  ```

Check it worked:
- Plug your laptop/TV into the Pi -> it should get an IP like 192.168.88.10.
- On that device, run 'curl ifconfig.me' -> should match your exit node’s IP.

If it fails:
- No IP -> 'systemctl status dnsmasq' and check the cable/adapter.
- Has IP but no internet -> 'sudo iptables -t nat -S' (look for MASQUERADE to tailscale0),
  or the exit node isn’t set.

## 5) Make it stick on boot (5 min)

Why: After a reboot, we want Wi‑Fi, Tailscale, NAT, and DHCP to be ready automatically.

Do this:
  ```
  sudo tee /usr/local/bin/portkey-boot.sh >/dev/null <<'EOS'
  #!/bin/bash
  set -e
  # Wait up to ~40s for Wi‑Fi to get an IP
  for i in {1..20}; do ip -4 addr show wlan0 | grep -q 'inet ' && break; sleep 2; done
  # Reapply Tailscale preferences (uses stored settings)
  tailscale up --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true || true
  # Reassert Ethernet sharing if configured
  ip addr add 192.168.88.1/24 dev eth0 2>/dev/null || true
  ip link set eth0 up
  [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
  systemctl restart dnsmasq || true
  EOS
  sudo chmod +x /usr/local/bin/portkey-boot.sh

  sudo tee /etc/systemd/system/portkey-boot.service >/dev/null <<'EOF'
  [Unit]
  Description=XRP-Portkey boot consolidation
  After=network-online.target tailscaled.service
  Wants=network-online.target
  [Service]
  Type=oneshot
  ExecStart=/usr/local/bin/portkey-boot.sh
  RemainAfterExit=yes
  [Install]
  WantedBy=multi-user.target
  EOF

  sudo systemctl daemon-reload
  sudo systemctl enable portkey-boot.service tailscaled wpa_supplicant@wlan0 dhcpcd
  ```

Check it worked:
  ```
  sudo reboot
  # after it comes back:
  tailscale status --self
  curl ifconfig.me
  ```

## 6) Keep the same Tailscale IP (optional)

Why: If you reinstall the OS, you can keep the same 100.x.x.x so bookmarks/labels don’t break.

Backup now:
  ```
  sudo systemctl stop tailscaled
  sudo cp /var/lib/tailscale/tailscaled.state /mnt/usb/tailscaled.state
  sudo systemctl start tailscaled
  ```

Restore later (on a fresh OS, BEFORE starting tailscaled):
  ```
  sudo systemctl stop tailscaled
  sudo cp /mnt/usb/tailscaled.state /var/lib/tailscale/tailscaled.state
  sudo chown root:root /var/lib/tailscale/tailscaled.state
  sudo chmod 600 /var/lib/tailscale/tailscaled.state
  sudo systemctl start tailscaled
  ```

## Mini-glossary
- Tailscale exit node — a device you own that agrees to send your internet traffic
  to the wider internet on your behalf, so your Pi appears “from” that place.
- NAT (masquerade) — rewrites traffic from a private subnet so it can go out to the
  internet and return.
- dnsmasq — a tiny DNS/DHCP server we use to hand out addresses on Ethernet.

## Tips:
- It’s safe to re-run most commands; they just re-assert config.
- Save your tailscale state, don't skip step 6.
