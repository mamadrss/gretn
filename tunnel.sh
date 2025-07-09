#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

GRE_SCRIPT_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# نمایش بنر
banner() {
  echo -e "${CYAN}"
  echo "===================================="
  echo "        GRE Tunnel Manager"
  echo "        GitHub: AbrDade"
  echo "===================================="
  echo -e "${RESET}"
}

# فعال‌سازی IP forwarding
enable_ip_forwarding() {
  sudo sysctl -w net.ipv4.ip_forward=1
  if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
  fi
  sudo sysctl -p > /dev/null
}

# ایجاد تونل جدید
create_tunnel() {
  read -p "Enter a name for the GRE tunnel (e.g., gre-tun0): " TUN_NAME
  [[ -z "$TUN_NAME" ]] && echo "[!] Tunnel name cannot be empty." && return

  echo "Select server location:"
  echo "1 - IRAN"
  echo "2 - FOREIGN"
  read -p "Enter 1 or 2: " LOCATION

  read -p "Enter IRAN server IP: " IP_IRAN
  read -p "Enter FOREIGN server IP: " IP_FOREIGN

  echo "[*] Removing existing tunnel if present..."
  sudo ip tunnel del "$TUN_NAME" 2>/dev/null

  if [[ "$LOCATION" == "1" ]]; then
    sudo ip tunnel add "$TUN_NAME" mode gre local "$IP_IRAN" remote "$IP_FOREIGN" ttl 255
    sudo ip link set "$TUN_NAME" up
    sudo ip addr add 132.168.30.2/30 dev "$TUN_NAME"
    enable_ip_forwarding
    echo -e "${YELLOW}[INFO] Tunnel is up. Use destination IP: 132.168.30.1${RESET}"
  elif [[ "$LOCATION" == "2" ]]; then
    sudo ip tunnel add "$TUN_NAME" mode gre local "$IP_FOREIGN" remote "$IP_IRAN" ttl 255
    sudo ip link set "$TUN_NAME" up
    sudo ip addr add 132.168.30.1/30 dev "$TUN_NAME"
    enable_ip_forwarding
    echo -e "${YELLOW}[INFO] Tunnel is up. Use destination IP: 132.168.30.2${RESET}"
  else
    echo "[!] Invalid selection."
    return
  fi

  read -p "Do you want to create a persistent systemd service? (y/n): " MAKE_SERVICE
  if [[ "$MAKE_SERVICE" =~ ^[Yy]$ ]]; then
    SCRIPT_PATH="$GRE_SCRIPT_DIR/setup-gre-$TUN_NAME.sh"
    SERVICE_PATH="$SYSTEMD_DIR/gre-$TUN_NAME.service"

    sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
ip tunnel add "$TUN_NAME" mode gre local "$([ "$LOCATION" == "1" ] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" remote "$([ "$LOCATION" == "1" ] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
ip link set "$TUN_NAME" up
ip addr add $([ "$LOCATION" == "1" ] && echo "132.168.30.2/30" || echo "132.168.30.1/30") dev "$TUN_NAME"
sysctl -w net.ipv4.ip_forward=1
EOF
    sudo chmod +x "$SCRIPT_PATH"

    sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=GRE Tunnel $TUN_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH
ExecStop=/sbin/ip tunnel del $TUN_NAME

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "gre-$TUN_NAME.service"
    echo "[*] Service gre-$TUN_NAME.service created and enabled."
  fi
}

# حذف کامل تونل و سرویس مرتبط
delete_tunnel() {
  read -p "Enter the GRE tunnel name to delete: " TUN_NAME
  [[ -z "$TUN_NAME" ]] && echo "[!] Tunnel name cannot be empty." && return

  SERVICE="gre-$TUN_NAME.service"
  SCRIPT="$GRE_SCRIPT_DIR/setup-gre-$TUN_NAME.sh"

  echo "[*] Stopping and removing tunnel..."
  sudo ip tunnel del "$TUN_NAME" 2>/dev/null

  if systemctl list-units --full -all | grep -q "$SERVICE"; then
    echo "[*] Disabling and removing systemd service..."
    sudo systemctl stop "$SERVICE"
    sudo systemctl disable "$SERVICE"
    sudo rm -f "$SYSTEMD_DIR/$SERVICE"
    sudo systemctl daemon-reload
  fi

  if [[ -f "$SCRIPT" ]]; then
    echo "[*] Removing script $SCRIPT"
    sudo rm -f "$SCRIPT"
  fi

  echo -e "${YELLOW}[INFO] Tunnel and service (if existed) have been removed.${RESET}"
}

# لیست تونل‌های فعال
list_tunnels() {
  echo "[*] Existing GRE tunnels:"
  ip tunnel show | grep -E 'gre[0-9]*|tun' || echo "(none found)"
}

# منوی اصلی
main_menu() {
  while true; do
    banner
    echo "1. Create new GRE tunnel"
    echo "2. Delete GRE tunnel"
    echo "3. List active GRE tunnels"
    echo "4. Exit"
    echo "--------------------------"
    read -p "Choose an option: " CHOICE
    case "$CHOICE" in
      1) create_tunnel ;;
      2) delete_tunnel ;;
      3) list_tunnels ;;
      4) echo "Goodbye!"; exit 0 ;;
      *) echo "[!] Invalid choice." ;;
    esac
    echo
    read -p "Press Enter to return to menu..."
  done
}

main_menu
