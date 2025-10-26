mkdir -p scripts
cat <<'EOF' | sudo tee scripts/uninstall-portkey.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail

# XRP-Portkey uninstaller (interactive)
# Removes Portkey NAT/DHCP/boot pieces, optionally uninstalls Tailscale
#Optionally revert WiFi modes including switching to NetworkManager.
#
# SPDX-License-Identifier: MIT

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo bash $0" >&2
    exit 1
  fi
}

confirm() {
  local prompt="${1:-Proceed?}"
  read -r -p "$prompt [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

say()  { echo -e "\033[1;36m[portkey]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[err]\033[0m $*" >&2; }

need_root

say "XRP-Portkey Uninstaller"
echo "This will remove Portkey components and optionally revert Wi-Fi behavior."

# 1) Stop services we manage
say "Stopping services (if present)..."
systemctl stop portkey-boot.service 2>/dev/null || true
systemctl stop dnsmasq               2>/dev/null || true
systemctl stop tailscaled            2>/dev/null || true

# 2) Disable Portkey services
say "Disabling services (if present)..."
systemctl disable portkey-boot.service 2>/dev/null || true
systemctl disable dnsmasq             2>/dev/null || true
# Don't disable tailscaled yet; user decides later.

# 3) Remove boot consolidation unit & script
if [[ -f /etc/systemd/system/portkey-boot.service ]]; then
  say "Removing /etc/systemd/system/portkey-boot.service"
  rm -f /etc/systemd/system/portkey-boot.service
fi
if [[ -f /usr/local/bin/portkey-boot.sh ]]; then
  say "Removing /usr/local/bin/portkey-boot.sh"
  rm -f /usr/local/bin/portkey-boot.sh
fi

# 4) Revert Ethernet sharing (dnsmasq + iptables + sysctl + eth0 IP)
if confirm "Revert Ethernet sharing (disable DHCP on eth0, remove NAT & IP forwarding, clear 192.168.88.1 from eth0)?"; then
  # dnsmasq config
  if [[ -f /etc/dnsmasq.conf ]]; then
    if grep -qE '^\s*interface=eth0' /etc/dnsmasq.conf || grep -qE '^\s*dhcp-range=' /etc/dnsmasq.conf; then
      say "Backing up /etc/dnsmasq.conf -> /etc/dnsmasq.conf.bak.$(date +%s)"
      cp -a /etc/dnsmasq.conf "/etc/dnsmasq.conf.bak.$(date +%s)"
      sed -i -e '/^\s*interface=eth0\s*$/d' -e '/^\s*dhcp-range=.*$/d' /etc/dnsmasq.conf || true
    fi
  fi
  systemctl restart dnsmasq 2>/dev/null || true

  # Remove eth0 static IP
  ip addr del 192.168.88.1/24 dev eth0 2>/dev/null || true

  # Remove iptables rules we added (if present)
  while iptables -t nat -C POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o tailscale0 -j MASQUERADE || true
  done
  while iptables -C FORWARD -i eth0 -o tailscale0 -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i eth0 -o tailscale0 -j ACCEPT || true
  done
  while iptables -C FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i tailscale0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
  done

  # Revert IP forwarding if set
  if grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    say "Reverting net.ipv4.ip_forward in /etc/sysctl.conf"
    sed -i -e 's/^net.ipv4.ip_forward=1/# net.ipv4.ip_forward=0 (disabled by portkey uninstall)/' /etc/sysctl.conf || true
    sysctl -p || true
  fi

  # Optionally remove saved rules.v4
  if [[ -f /etc/iptables/rules.v4 ]]; then
    if confirm "Remove saved iptables rules file at /etc/iptables/rules.v4?"; then
      rm -f /etc/iptables/rules.v4
      say "Removed /etc/iptables/rules.v4"
    fi
  fi
fi

# 5) Wi-Fi revert options (wpa_supplicant/dhcpcd vs. NetworkManager)
echo
echo "Wi-Fi revert options:"
echo "  [K]eep current services/files (do nothing)"
echo "  [D]isable wpa_supplicant@wlan0 + dhcpcd (no auto Wi-Fi on boot)"
echo "  [F]actory: clear saved networks, disable wpa_supplicant/dhcpcd,"
echo "             and enable NetworkManager, install if missing (Recommended)"

# Enforce valid input: K/D/F only (default K on empty)
while :; do
  read -r -p "Choose K/D/F [K]: " WIFI_CHOICE
  WIFI_CHOICE="${WIFI_CHOICE^^}"           # normalize to uppercase
  WIFI_CHOICE="${WIFI_CHOICE:-K}"          # default to K if empty
  [[ "$WIFI_CHOICE" =~ ^(K|D|F)$ ]] && break
  echo "Please enter K, D, or F."
done

WPA_FILE="/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

case "$WIFI_CHOICE" in
  K)
    say "Keeping current Wi-Fi setup (wpa_supplicant/dhcpcd left as-is)."
    ;;

  D)
    say "Disabling wpa_supplicant@wlan0 + dhcpcd (Wi-Fi will not auto-connect on boot)..."
    systemctl stop wpa_supplicant@wlan0 dhcpcd 2>/dev/null || true
    systemctl disable wpa_supplicant@wlan0 dhcpcd 2>/dev/null || true
    ;;

  F)
    say "Factory Wi-Fi reset (install/enable NetworkManager, then retire wpa_supplicant/dhcpcd)..."

    # 1) Ensure NetworkManager is installed FIRST (while Wi-Fi is still up)
    if ! systemctl list-unit-files | grep -q '^NetworkManager.service'; then
      say "Installing NetworkManager (keeping existing Wi-Fi up for download)..."
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager
    else
      say "NetworkManager already present."
    fi

    # 2) (Optional) Clear saved networks from wpa_supplicant but keep header intact
    if [[ -f "$WPA_FILE" ]]; then
      say "Backing up $WPA_FILE and clearing network blocks"
      cp -a "$WPA_FILE" "$WPA_FILE.bak.$(date +%s)"
      awk 'BEGIN{skip=0} /^network=\{/ {skip=1} skip==1 && /^\}/ {skip=0; next} skip==0 {print}' \
        "$WPA_FILE" > "$WPA_FILE.new" || true
      mv "$WPA_FILE.new" "$WPA_FILE"
      chmod 600 "$WPA_FILE"
    fi

    # 3) Retire classic stack (now that NM is installed)
    say "Disabling wpa_supplicant@wlan0 + dhcpcd..."
    systemctl stop wpa_supplicant@wlan0 dhcpcd 2>/dev/null || true
    systemctl disable wpa_supplicant@wlan0 dhcpcd 2>/dev/null || true

    # 4) Hand control to NetworkManager
    say "Enabling and starting NetworkManager..."
    systemctl enable NetworkManager
    systemctl start  NetworkManager

    say "Wi-Fi control is now handled by NetworkManager."
    echo "Tip: nmcli dev wifi list"
    echo "     nmcli dev wifi connect \"SSID\" password \"PSK\""
    ;;
esac

# 6) Tailscale removal (optional)
echo
if confirm "Completely uninstall Tailscale package (and optionally remove its state)?"; then
  if confirm "Remove Tailscale state (logout and delete /var/lib/tailscale)? WARNING: forgets device identity"; then
    tailscale logout 2>/dev/null || true
    systemctl stop tailscaled 2>/dev/null || true
    rm -rf /var/lib/tailscale 2>/dev/null || true
  fi
  apt-get purge -y tailscale 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
else
  say "Leaving Tailscale installed. To stop using an exit node:"
  echo "  sudo tailscale up --exit-node= --reset"
fi

# 7) Reload systemd and finish
systemctl daemon-reload

say "Uninstall steps complete."
echo "Recommended: reboot to ensure a clean state: sudo reboot"
EOF
sudo chmod +x scripts/uninstall-portkey.sh
