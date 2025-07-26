#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

GRE_SCRIPT_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

PRIVATE_IP_RANGES=(
  "192.168.100.0"
  "192.168.200.0"
  "10.10.10.0"
  "172.16.100.0"
  "172.20.30.0"
)

banner() {
  echo -e "${CYAN}"
  echo "===================================="
  echo "      GRE Tunnel Manager - v2"
  echo "      GitHub: MamadRss"
  echo "===================================="
  echo -e "${RESET}"
}

enable_ip_forwarding() {
  sudo sysctl -w net.ipv4.ip_forward=1
  if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
  fi
  sudo sysctl -p > /dev/null
}

find_free_range() {
  for BASE_IP in "${PRIVATE_IP_RANGES[@]}"; do
    NET_PREFIX=$(echo "$BASE_IP" | cut -d. -f1-3)
    MATCH=$(ip addr show | grep -c "$NET_PREFIX")
    if [[ "$MATCH" -eq 0 ]]; then
      echo "$BASE_IP"
      return
    fi
  done
  echo ""
}

create_tunnel() {
  read -p "Enter a name for the GRE tunnel (e.g., gre-tun0): " TUN_NAME
  [[ -z "$TUN_NAME" ]] && echo "[!] Tunnel name cannot be empty." && return

  echo "Select server location:"
  echo "1 - IRAN"
  echo "2 - FOREIGN"
  read -p "Enter 1 or 2: " LOCATION

  read -p "Enter IRAN server IP: " IP_IRAN
  read -p "Enter FOREIGN server IP: " IP_FOREIGN

  echo
  read -p "Enter custom /30 base IP (e.g. 10.20.30.0), or press Enter to auto-select: " CUSTOM_BASE

  if [[ -n "$CUSTOM_BASE" ]]; then
    BASE_IP="$CUSTOM_BASE"
    echo "[*] Using custom IP base: $BASE_IP/30"
  else
    BASE_IP=$(find_free_range)
    if [[ -z "$BASE_IP" ]]; then
      echo "[!] No free IP range available. Please free some or expand the list."
      return
    fi
    echo "[*] Using auto-selected IP base: $BASE_IP/30"
  fi

  if [[ "$LOCATION" == "1" ]]; then
    LOCAL_TUN_IP="${BASE_IP%.*}.2"
    REMOTE_TUN_IP="${BASE_IP%.*}.1"
  else
    LOCAL_TUN_IP="${BASE_IP%.*}.1"
    REMOTE_TUN_IP="${BASE_IP%.*}.2"
  fi

  sudo ip tunnel del "$TUN_NAME" 2>/dev/null
  sudo ip tunnel add "$TUN_NAME" mode gre local "$([ "$LOCATION" == "1" ] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" \
                                     remote "$([ "$LOCATION" == "1" ] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
  sudo ip link set "$TUN_NAME" up
  sudo ip addr add "$LOCAL_TUN_IP/30" dev "$TUN_NAME"
  enable_ip_forwarding

  echo -e "${YELLOW}[INFO] Tunnel is up. Destination IP to use: $REMOTE_TUN_IP${RESET}"

  read -p "Create persistent systemd service? (y/n): " MAKE_SERVICE
  if [[ "$MAKE_SERVICE" =~ ^[Yy]$ ]]; then
    SCRIPT_PATH="$GRE_SCRIPT_DIR/setup-gre-$TUN_NAME.sh"
    SERVICE_PATH="$SYSTEMD_DIR/gre-$TUN_NAME.service"

    sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
ip tunnel add "$TUN_NAME" mode gre local "$([ "$LOCATION" == "1" ] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" remote "$([ "$LOCATION" == "1" ] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
ip link set "$TUN_NAME" up
ip addr add "$LOCAL_TUN_IP/30" dev "$TUN_NAME"
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
    echo "[*] Persistent systemd service gre-$TUN_NAME.service enabled."
  fi
}


delete_tunnel() {
  read -p "Enter the GRE tunnel name to delete: " TUN_NAME
  [[ -z "$TUN_NAME" ]] && echo "[!] Tunnel name cannot be empty." && return

  SERVICE="gre-$TUN_NAME.service"
  SCRIPT="$GRE_SCRIPT_DIR/setup-gre-$TUN_NAME.sh"

  echo "[*] Stopping and deleting tunnel $TUN_NAME..."
  sudo ip tunnel del "$TUN_NAME" 2>/dev/null

  if systemctl list-units --full -all | grep -q "$SERVICE"; then
    sudo systemctl stop "$SERVICE"
    sudo systemctl disable "$SERVICE"
    sudo rm -f "$SYSTEMD_DIR/$SERVICE"
    sudo systemctl daemon-reload
    echo "[*] Removed systemd service."
  fi

  [[ -f "$SCRIPT" ]] && sudo rm -f "$SCRIPT"

  echo -e "${YELLOW}[INFO] Tunnel $TUN_NAME and its service removed (if existed).${RESET}"
}

list_tunnels() {
  echo "[*] Active GRE tunnels with IP assignments:"
  echo "--------------------------------------------"
  
  ip tunnel show | grep -vE '^gre0|gretap0|erspan0' | while read -r line; do
    TUN_NAME=$(echo "$line" | awk -F: '{print $1}')
    LOCAL_IP=$(ip addr show "$TUN_NAME" 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "N/A")
    STATE=$(ip link show "$TUN_NAME" | grep -q "state UP" && echo "UP" || echo "DOWN")

    printf "🔗 %s\t%s\t[%s]\n" "$TUN_NAME" "$LOCAL_IP" "$STATE"
  done
}


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
