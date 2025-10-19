# XRP-Portkey — Manual Setup (No Installer)

This is the full, linear guide to configure XRP-Portkey from a clean Raspberry Pi OS Lite image.

## 0) Assumptions
- Pi boots to CLI and you have sudo access
- You have SSIDs/passwords ready
- You have a Tailscale account and an **exit node** already enabled in the admin console

## 1) Base OS & essentials
```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y iptables-persistent dnsmasq dhcpcd5 curl
```

## 2) Headless Wi‑Fi on wlan0 (wpa_supplicant)
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

# verify Wi‑Fi
iwgetid -r
ip -4 addr show wlan0
ping -c3 1.1.1.1 && ping -c3 google.com
```

## 3) Install & join Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up  # open the URL to authenticate

# set exit node (after enabling "Use as exit node" in admin)
sudo tailscale up --exit-node=YOURTAILSCALEEXITNODE \
  --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true

# verify
tailscale status --self
curl ifconfig.me
```

## 4) (Optional) Share tunnel over Ethernet
```bash
# forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# eth0 address + NAT to tailscale0
sudo ip addr add 192.168.88.1/24 dev eth0
sudo ip link set eth0 up
sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
sudo iptables -A FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'

# DHCP for client
echo -e "interface=eth0\ndhcp-range=192.168.88.10,192.168.88.20,12h" | sudo tee /etc/dnsmasq.conf
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq
```

## 5) Persistence (boot re‑assert)
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

## 6) Verify
```bash
tailscale status --self
curl ifconfig.me
sudo iptables -t nat -L POSTROUTING -v -n
```

## 7) Keep the same Tailscale IP (optional)
```bash
# before wiping
sudo systemctl stop tailscaled
sudo cp /var/lib/tailscale/tailscaled.state /mnt/usb/tailscaled.state

# after reinstall (before starting tailscaled)
sudo systemctl stop tailscaled
sudo cp /mnt/usb/tailscaled.state /var/lib/tailscale/tailscaled.state
sudo chown root:root /var/lib/tailscale/tailscaled.state
sudo chmod 600 /var/lib/tailscale/tailscaled.state
sudo systemctl start tailscaled

tailscale ip -4   # should match your old 100.x
```
