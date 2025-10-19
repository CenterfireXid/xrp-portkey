# XRP-Portkey — Headless Raspberry Pi Tailscale Client (Travel Node)

**XRP-Portkey** is a headless Raspberry Pi that auto-joins **pre-saved Wi‑Fi** networks and routes all traffic through a chosen **Tailscale exit node**. Optionally, it can share that encrypted tunnel over **Ethernet (eth0)** to a single downstream device (laptop/TV). Includes **boot persistence**, **helper scripts**, and an **IP-persistence** guide so you can keep the same Tailscale IP after a reinstall.

---

## Table of Contents
- [Features](#features)
- [Prerequisites & Assumptions](#prerequisites)
- [Quick Start (installer)](#quick-start-installer)
- [Manual Setup (no installer)](#manual-setup-no-installer)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Keep the Same Tailscale IP](#keep-the-same-tailscale-ip)
- [Roadmap](#roadmap)
- [License](#license)

---

## Features

- **Headless Wi‑Fi** via `wpa_supplicant@wlan0` (pre‑saved SSIDs & passwords)
- **Automatic IP/DNS** via `dhcpcd5`
- **Tailscale** auto‑start; **exit node** selection (`--accept-routes` / `--accept-dns`)
- **(Optional)** Ethernet sharing: NAT `eth0 → tailscale0` + DHCP via `dnsmasq`
- **Boot persistence** using a one‑shot systemd service
- **Helper scripts** to switch/clear exit nodes quickly
- **IP persistence** option: restore the same Tailscale `100.x.x.x` after OS reinstall

---

## Prerequisites

- You have a **Tailscale account** and access to the **admin console**.
- You already have **at least one device configured as an Exit Node**:
  - In the admin console, you enabled **“Use as exit node”** on that device.
  - (Optional) You allowed **LAN access** on the exit node if you want to reach devices on that LAN.
- You can authenticate this Pi to Tailscale either by:
  - Opening the authorization URL from `tailscale up`, **or**
  - Supplying a **Tailscale auth key** (`AUTHKEY`) for unattended setup.
- You have **Wi‑Fi SSIDs and passwords** for networks this Pi should auto‑join.
- You have **SSH or console access** to the Pi and **sudo** permissions.
- Internet egress from the Pi is permitted (no captive portal or restrictive firewall).
- **Accurate system time** (NTP enabled by default on Raspberry Pi OS).
- (Optional) To preserve the **same Tailscale 100.x IP** across reinstalls, you can back up and restore:
  - `/var/lib/tailscale/tailscaled.state` (treat as a secret; do **not** commit to git).
- (Optional for Ethernet sharing) You have an **Ethernet cable** and a downstream device (laptop/TV) that can use DHCP.

---

## Quick Start (installer)

> If you already have your SSIDs in `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`, you can skip `SSID_CONF_SRC`.

1) **Clone** this repo (or copy the installer onto the Pi)

Install git if it's not already installed
```
if ! command -v git >/dev/null; then
  sudo apt update && sudo apt install -y git
fi
```

Clone the repo (replace <your-username> if needed)
```
git clone https://github.com/CenterfireXid/xrp-portkey.git
cd xrp-portkey
```

2) **Run the one‑shot installer** (as root):
```bash
sudo bash ./scripts/install-portkey.sh
```

Optional environment variables:
- `EXIT_NODE_NAME` — default exit node (e.g., `desktop-YOURDESKTOP`)
- `AUTHKEY` — Tailscale auth key (non‑ephemeral recommended for headless)
- `SSID_CONF_SRC` — path to a ready `wpa_supplicant-wlan0.conf` to install
- `STATE_SRC` — previously saved `/var/lib/tailscale/tailscaled.state` to **preserve the same IP**
- `ETH_SHARE=true` — enable Ethernet sharing (NAT + dnsmasq) immediately

Example:
```bash
sudo EXIT_NODE_NAME=desktop-YOURDESKTOP \
     AUTHKEY=tskey-abc123... \
     SSID_CONF_SRC=./config/wpa_supplicant-wlan0.conf.example \
     ETH_SHARE=true \
     bash ./scripts/install-portkey.sh
```

3) **Reboot**:
```bash
sudo reboot
```

4) **Verify** after boot:
```bash
tailscale status --self
curl ifconfig.me
```
- Public IP should match your exit node’s WAN IP.
- If Ethernet sharing is enabled, plug a laptop/TV into **eth0** and confirm it receives an IP and shows the same public IP.

---

## Manual Setup (no installer)

Below is a short version. For the complete walkthrough, see **[docs/manual-setup.md](docs/manual-setup.md)**.

### 1) Base system
```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y iptables-persistent dnsmasq dhcpcd5 curl
```

### 2) Headless Wi‑Fi (wlan0)
```bash
sudo systemctl stop NetworkManager 2>/dev/null || true
sudo systemctl disable NetworkManager 2>/dev/null || true

sudo tee /etc/wpa_supplicant/wpa_supplicant-wlan0.conf >/dev/null <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=US
network={ ssid="PhoneHotspot" psk="hotspotpassword" priority=1 }
network={ ssid="FriendsWiFi" psk="friendspassword" priority=2 }
network={ ssid="HomeWiFi"    psk="homepassword"    priority=3 }
EOF

sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
sudo systemctl enable wpa_supplicant@wlan0 dhcpcd
sudo systemctl start  wpa_supplicant@wlan0 dhcpcd
```

### 3) Tailscale + exit node
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up  # authenticate via URL

sudo tailscale up --exit-node=<EXIT_NODE_NAME> \
  --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true
```

### 4) (Optional) Share tunnel over Ethernet
```bash
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
sudo ip addr add 192.168.88.1/24 dev eth0
sudo ip link set eth0 up
sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
sudo iptables -A FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
echo -e "interface=eth0\ndhcp-range=192.168.88.10,192.168.88.20,12h" | sudo tee /etc/dnsmasq.conf
sudo systemctl enable dnsmasq && sudo systemctl restart dnsmasq
```

### 5) Boot persistence
```bash
sudo tee /usr/local/bin/portkey-boot.sh >/dev/null <<'EOS'
#!/bin/bash
set -e
for i in {1..20}; do ip -4 addr show wlan0 | grep -q 'inet ' && break; sleep 2; done
tailscale up --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true || true
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

---

## Verification

**On the Pi**
```bash
tailscale status --self
curl ifconfig.me
sudo iptables -t nat -L POSTROUTING -v -n
```

**On the Ethernet client (if enabled)**
```bash
# should receive 192.168.88.10–20
curl ifconfig.me   # should match the exit node’s WAN IP
```

---

## Troubleshooting

See **[docs/troubleshooting.md](docs/troubleshooting.md)** for deeper fixes. Highlights:
- **`wpa_cli: FAIL`** → ensure `wpa_supplicant@wlan0` is enabled; disable NetworkManager.
- **No IP on wlan0** → `systemctl status dhcpcd`; check SSID/PSK; confirm band support.
- **Routes offered but not used** → use `--accept-routes=true --accept-dns=true`.
- **Public IP mismatch** → confirm `--exit-node=<name>` and that the exit node is approved.
- **Ethernet client offline** → check `dnsmasq` status and NAT rules (`iptables -t nat -S`).

---

## Keep the Same Tailscale IP

Back up and restore this file to preserve the same `100.x` after reinstall:
```
/var/lib/tailscale/tailscaled.state
```
**Before wiping:**
```bash
sudo systemctl stop tailscaled
sudo cp /var/lib/tailscale/tailscaled.state /mnt/usb/tailscaled.state
```
**After reinstall (before starting tailscaled):**
```bash
sudo systemctl stop tailscaled
sudo cp /mnt/usb/tailscaled.state /var/lib/tailscale/tailscaled.state
sudo chown root:root /var/lib/tailscale/tailscaled.state
sudo chmod 600 /var/lib/tailscale/tailscaled.state
sudo systemctl start tailscaled
```

---

## Roadmap

- LED status script (blink 3× when exit‑node routing OK)
- One‑shot **install-portkey.sh** improvements (input prompts, preflight checks)
- Minimal web UI to display status & allow exit‑node switching
- Auto‑fallback when exit node is unreachable (retry loop, backoff)

---

## License

Use **MIT License** (attribution required). Add this header to scripts:
```bash
# Copyright (c) 2025 Your Name
# SPDX-License-Identifier: MIT
# This file is part of XRP-Portkey. See LICENSE for details.
```
Create a `LICENSE` file via GitHub’s “Add a license template” → **MIT**.
