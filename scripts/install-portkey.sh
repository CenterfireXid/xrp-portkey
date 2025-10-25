#!/usr/bin/env bash
set -euo pipefail

# XRP-Portkey interactive installer
# SPDX-License-Identifier: MIT

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This installer must be run as root. Try: sudo bash $0" >&2
    exit 1
  fi
}

confirm() {
  local prompt="${1:-Are you sure?}"
  read -r -p "$prompt [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

prompt_default() {
  local var_name="$1"
  local message="$2"
  local default="${3-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " value || true
    value="${value:-$default}"
  else
    read -r -p "$message: " value || true
  fi
  printf -v "$var_name" '%s' "$value"
}

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Installing missing dependency: $c"
    apt-get update -y && apt-get install -y "$c"
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "$f.bak.$(date +%s)"
  fi
}

print_banner() {
cat <<'BANNER'

=============================================
     XRP-Portkey Interactive Installer
=============================================
This will:
 - Configure headless Wi-Fi on wlan0 (wpa_supplicant + dhcpcd)
 - Install & join Tailscale (optionally with an auth key)
 - (Optional) Select an Exit Node and accept routes/DNS
 - (Optional) Share the tunnel on Ethernet (eth0) via NAT + DHCP
 - Enable a boot service to re-assert settings after reboot

You will be prompted for:
  • Country code (for Wi-Fi channels)   e.g., US
  • One or more Wi-Fi SSIDs + passwords
  • (Optional) Tailscale AUTHKEY         e.g., tskey-...
  • (Optional) Exit Node name            e.g., desktop-xyz
  • (Optional) Ethernet sharing choice
  • (Optional) LAN subnet (default 192.168.88.0/24)

Press Ctrl+C to abort at any time.
BANNER
}

need_root
print_banner
confirm "Proceed with installation?" || { echo "Aborted."; exit 1; }

# Basic tools
require_cmd curl
require_cmd iptables
require_cmd tee
require_cmd awk
require_cmd sed

echo "Updating packages and installing base components..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  iptables-persistent dnsmasq dhcpcd5 ca-certificates

# Disable NetworkManager if present (avoid conflicts)
if systemctl list-unit-files | grep -q '^NetworkManager.service'; then
  systemctl stop NetworkManager || true
  systemctl disable NetworkManager || true
fi

# Wi-Fi
COUNTRY="US"
prompt_default COUNTRY "Enter your Wi-Fi country code" "$COUNTRY"

WPA_FILE="/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
backup_file "$WPA_FILE"

cat >"$WPA_FILE" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=${COUNTRY}
EOF

echo "Add one or more Wi-Fi networks (blank SSID to stop)."
while true; do
  SSID=""
  prompt_default SSID "  SSID (blank to finish)"
  if [[ -z "$SSID" ]]; then break; fi
  read -r -s -p "  PSK for \"$SSID\": " PSK || true; echo
  PRIORITY="1"
  prompt_default PRIORITY "  Priority (1=highest) for \"$SSID\"" "$PRIORITY"
  cat >>"$WPA_FILE" <<EOF
network={ ssid="$SSID" psk="$PSK" priority=$PRIORITY }
EOF
done
chmod 600 "$WPA_FILE"

systemctl enable wpa_supplicant@wlan0 dhcpcd
systemctl restart wpa_supplicant@wlan0 dhcpcd

echo "Waiting up to ~20s for wlan0 to get an IP..."
for i in {1..10}; do ip -4 addr show wlan0 | grep -q 'inet ' && break; sleep 2; done

# Optional: restore tailscale state
if confirm "Restore a saved Tailscale state to keep same 100.x IP?"; then
  read -r -p "  Path to saved tailscaled.state: " STATE_SRC || true
  if [[ -n "${STATE_SRC:-}" && -f "$STATE_SRC" ]]; then
    systemctl stop tailscaled 2>/dev/null || true
    install -m 600 -o root -g root "$STATE_SRC" /var/lib/tailscale/tailscaled.state
    echo "Restored /var/lib/tailscale/tailscaled.state"
  else
    echo "  Skipping restore (file missing)."
  fi
fi

# Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
  echo "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

AUTHKEY=""
prompt_default AUTHKEY "Enter Tailscale auth key (or leave blank for browser auth)" ""
EXIT_NODE_NAME=""
prompt_default EXIT_NODE_NAME "Enter Exit Node name (optional)" ""

TS_ARGS=(--accept-routes=true --accept-dns=true --exit-node-allow-lan-access=true)
[[ -n "$AUTHKEY" ]] && TS_ARGS+=(--authkey="$AUTHKEY")
[[ -n "$EXIT_NODE_NAME" ]] && TS_ARGS+=(--exit-node="$EXIT_NODE_NAME")

echo "Running: tailscale up ${TS_ARGS[*]}"
if ! tailscale up "${TS_ARGS[@]}"; then
  echo "Open the URL printed above to authorize the Pi, then re-run the same tailscale up command."
fi

tailscale status --self || true
echo "Public IP (via exit node if set): $(curl -4s ifconfig.me || echo '?')"

# Ethernet sharing
ETH_SHARE=false
if confirm "Enable Ethernet sharing (NAT + DHCP on eth0)?"; then ETH_SHARE=true; fi
ETH_SUBNET="192.168.88.0/24"
prompt_default ETH_SUBNET "LAN subnet for eth0 (CIDR)" "$ETH_SUBNET"
IFS=/ read -r ETH_NET ETH_PREFIX <<<"$ETH_SUBNET"
IFS=. read -r a b c d <<<"$ETH_NET"
ETH_GW_IP="${a}.${b}.${c}.1"
DHCP_START="${a}.${b}.${c}.10"
DHCP_END="${a}.${b}.${c}.20"

if [[ "$ETH_SHARE" == "true" ]]; then
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  sysctl -p || true

  ip addr add "${ETH_GW_IP}/${ETH_PREFIX}" dev eth0 2>/dev/null || true
  ip link set eth0 up || true

  iptables -t nat -S | grep -q ' -o tailscale0 -j MASQUERADE' || iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
  iptables -C FORWARD -i eth0 -o tailscale0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT
  iptables -C FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables-save > /etc/iptables/rules.v4

  backup_file /etc/dnsmasq.conf
  cat >/etc/dnsmasq.conf <<EOF
interface=eth0
dhcp-range=${DHCP_START},${DHCP_END},12h
domain-needed
bogus-priv
EOF
  systemctl enable dnsmasq
  systemctl restart dnsmasq
fi

# Boot consolidation
cat >/usr/local/bin/portkey-boot.sh <<'EOS'
#!/usr/bin/env bash
set -e
for i in {1..20}; do ip -4 addr show wlan0 | grep -q 'inet ' && break; sleep 2; done
tailscale up --accept-routes=true --exit-node-allow-lan-access=true --accept-dns=true || true
ip addr add 192.168.88.1/24 dev eth0 2>/dev/null || true
ip link set eth0 up || true
[ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4 || true
systemctl restart dnsmasq 2>/dev/null || true
EOS
chmod +x /usr/local/bin/portkey-boot.sh

cat >/etc/systemd/system/portkey-boot.service <<'EOF'
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

systemctl daemon-reload
systemctl enable portkey-boot.service
systemctl enable tailscaled wpa_supplicant@wlan0 dhcpcd

echo
echo "============================================="
echo "XRP-Portkey installation complete (or updated)"
echo "============================================="
echo
echo "Quick verify:"
echo "  tailscale status --self"
echo "  curl ifconfig.me     # should match your exit node's public IP"
if [[ "$ETH_SHARE" == "true" ]]; then
  echo "  iptables -t nat -S | grep MASQUERADE"
  echo "  # Plug a device into eth0; it should get ${DHCP_START}-${DHCP_END} and show same public IP"
fi
echo
echo "Reboot recommended: sudo reboot"
echo
echo "You were prompted for:"
cat <<PREP
 - Wi-Fi country code (e.g., US)
 - One or more Wi-Fi SSIDs + passwords
 - (Optional) Tailscale AUTHKEY (tskey-..., or browser auth)
 - (Optional) Exit Node name (as seen in Tailscale)
 - (Optional) Restore Tailscale state file to keep same 100.x IP
 - (Optional) Enable Ethernet sharing (Y/N)
 - (Optional) LAN subnet for eth0 (default ${ETH_SUBNET})
PREP
