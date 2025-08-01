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
)

PRIVATE_IPV6_RANGES=(
  "fd1d:fc98:b73e:b381"
  "fd1d:fc98:b73e:cafe"
  "fd1d:fc98:b73e:dead"
  "fd1d:fc98:b73e:1111"
)

banner() {
  echo -e "${CYAN}"
  echo "=========================================="
  echo "     GRE & SIT Tunnel Manager - v3"
  echo "         GitHub: MamadRss"
  echo "=========================================="
  echo -e "${RESET}"
}

enable_ip_forwarding() {
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sysctl -w net.ipv6.conf.all.forwarding=1
  sudo sysctl -p > /dev/null
}

find_free_ipv4_range() {
  for BASE_IP in "${PRIVATE_IP_RANGES[@]}"; do
    NET_PREFIX=$(echo "$BASE_IP" | cut -d. -f1-3)
    MATCH=$(ip addr show | grep -c "$NET_PREFIX")
    [[ "$MATCH" -eq 0 ]] && echo "$BASE_IP" && return
  done
  echo ""
}

find_free_ipv6_range() {
  for BASE6 in "${PRIVATE_IPV6_RANGES[@]}"; do
    MATCH=$(ip -6 addr show | grep -c "$BASE6")
    [[ "$MATCH" -eq 0 ]] && echo "$BASE6" && return
  done
  echo ""
}

create_tunnel() {
  read -p "Enter a name for the tunnel: " TUN_NAME
  [[ -z "$TUN_NAME" ]] && echo "[!] Tunnel name cannot be empty." && return

  echo "Select tunnel mode:"
  echo "1 - GRE (IPv4 over IPv4)"
  echo "2 - SIT (IPv6 over IPv4)"
  read -p "Enter 1 or 2: " MODE_SEL

  [[ "$MODE_SEL" != "1" && "$MODE_SEL" != "2" ]] && echo "[!] Invalid mode selected." && return

  echo "Select server location:"
  echo "1 - IRAN"
  echo "2 - FOREIGN"
  read -p "Enter 1 or 2: " LOCATION

  read -p "Enter IRAN server IPv4: " IP_IRAN
  read -p "Enter FOREIGN server IPv4: " IP_FOREIGN

  local_mode=$( [[ "$LOCATION" == "1" ]] && echo "iran" || echo "foreign" )

  # GRE MODE
  if [[ "$MODE_SEL" == "1" ]]; then
    echo
    read -p "Enter custom /30 base IP (e.g. 10.20.30.0), or press Enter for auto: " CUSTOM_BASE
    BASE_IP=${CUSTOM_BASE:-$(find_free_ipv4_range)}
    [[ -z "$BASE_IP" ]] && echo "[!] No free IP range." && return

    LOCAL_TUN_IP="${BASE_IP%.*}.$([[ "$LOCATION" == "1" ]] && echo "2" || echo "1")"
    REMOTE_TUN_IP="${BASE_IP%.*}.$([[ "$LOCATION" == "1" ]] && echo "1" || echo "2")"

    sudo ip tunnel del "$TUN_NAME" 2>/dev/null
    sudo ip tunnel add "$TUN_NAME" mode gre local "$([[ "$LOCATION" == "1" ]] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" remote "$([[ "$LOCATION" == "1" ]] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
    sudo ip link set "$TUN_NAME" up
    sudo ip addr add "$LOCAL_TUN_IP/30" dev "$TUN_NAME"
    enable_ip_forwarding

    echo -e "${YELLOW}[INFO] GRE tunnel up. Remote IP: $REMOTE_TUN_IP${RESET}"

    TUN_IP_ASSIGN="$LOCAL_TUN_IP/30"

  # SIT MODE
  elif [[ "$MODE_SEL" == "2" ]]; then
    echo
    read -p "Enter custom IPv6 base (e.g. fd00:1::), or press Enter for auto: " CUSTOM6
    BASE6=${CUSTOM6:-$(find_free_ipv6_range)}
    [[ -z "$BASE6" ]] && echo "[!] No free IPv6 range available." && return

    LOCAL6="${BASE6}::$( [[ "$LOCATION" == "1" ]] && echo "2" || echo "1" )"
    REMOTE6="${BASE6}::$( [[ "$LOCATION" == "1" ]] && echo "1" || echo "2" )"

    sudo ip tunnel del "$TUN_NAME" 2>/dev/null
    sudo ip tunnel add "$TUN_NAME" mode sit local "$([[ "$LOCATION" == "1" ]] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" remote "$([[ "$LOCATION" == "1" ]] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
    sudo ip link set "$TUN_NAME" up
    sudo ip addr add "$LOCAL6/64" dev "$TUN_NAME"
    enable_ip_forwarding

    echo -e "${YELLOW}[INFO] SIT tunnel up. Local IPv6: $LOCAL6, Remote: $REMOTE6${RESET}"

    TUN_IP_ASSIGN="$LOCAL6/64"
  fi

  read -p "Create persistent systemd service? (y/n): " MAKE_SERVICE
  if [[ "$MAKE_SERVICE" =~ ^[Yy]$ ]]; then
    SCRIPT_PATH="$GRE_SCRIPT_DIR/setup-$TUN_NAME.sh"
    SERVICE_PATH="$SYSTEMD_DIR/$TUN_NAME.service"

    sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
ip tunnel add "$TUN_NAME" mode $([[ "$MODE_SEL" == "1" ]] && echo "gre" || echo "sit") local "$([[ "$LOCATION" == "1" ]] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" remote "$([[ "$LOCATION" == "1" ]] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
ip link set "$TUN_NAME" up
ip addr add "$TUN_IP_ASSIGN" dev "$TUN_NAME"
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
EOF

    sudo chmod +x "$SCRIPT_PATH"

    sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Tunnel $TUN_NAME
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
    sudo systemctl enable "$TUN_NAME.service"
    echo "[*] Service $TUN_NAME.service created and enabled."
  fi
}

delete_tunnel() {
  read -p "Enter the tunnel name to delete: " TUN_NAME
  [[ -z "$TUN_NAME" ]] && echo "[!] Tunnel name cannot be empty." && return

  SERVICE="$TUN_NAME.service"
  SCRIPT="$GRE_SCRIPT_DIR/setup-$TUN_NAME.sh"

  echo "[*] Removing tunnel $TUN_NAME..."
  sudo ip tunnel del "$TUN_NAME" 2>/dev/null

  if systemctl list-units --full -all | grep -q "$SERVICE"; then
    sudo systemctl stop "$SERVICE"
    sudo systemctl disable "$SERVICE"
    sudo rm -f "$SYSTEMD_DIR/$SERVICE"
    sudo systemctl daemon-reload
  fi

  [[ -f "$SCRIPT" ]] && sudo rm -f "$SCRIPT"
  echo -e "${YELLOW}[INFO] Tunnel $TUN_NAME and service removed.${RESET}"
}

list_tunnels() {
  echo "[*] Active Tunnels:"
  echo "--------------------------------------"
  ip tunnel show | grep -vE '^gre0|gretap0|erspan0' | while read -r line; do
    TUN_NAME=$(echo "$line" | awk -F: '{print $1}')
    TUN_IP=$(ip addr show "$TUN_NAME" 2>/dev/null | grep -E 'inet6? ' | awk '{print $2}' || echo "N/A")
    MODE=$(echo "$line" | grep -q "mode sit" && echo "SIT" || echo "GRE")
    STATE=$(ip link show "$TUN_NAME" | grep -q "state UP" && echo "UP" || echo "DOWN")
    printf "🔗 %-12s %-20s [%s - %s]\n" "$TUN_NAME" "$TUN_IP" "$MODE" "$STATE"
  done
}

main_menu() {
  while true; do
    banner
    echo "1. Create new tunnel (GRE/SIT)"
    echo "2. Delete tunnel"
    echo "3. List tunnels"
    echo "4. Exit"
    echo "-----------------------------"
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
