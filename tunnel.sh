#!/bin/bash

CYAN=$(tput setaf 6)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

echo -e "${CYAN}"
echo "===================================="
echo "        GitHub: AbrDade"
echo "   GRE Tunnel v1 Setup Script"
echo "   Persistent Option via systemd"
echo "===================================="
echo -e "${RESET}"

# گرفتن نام تونل از کاربر
read -p "Enter a name for the GRE tunnel (e.g., gre-tun0): " TUN_NAME
if [[ -z "$TUN_NAME" ]]; then
    echo "[!] Tunnel name cannot be empty."
    exit 1
fi

# انتخاب موقعیت سرور
echo "Select server location:"
echo "1 - IRAN"
echo "2 - FOREIGN"
read -p "Enter 1 or 2: " LOCATION

# گرفتن IPها
read -p "Enter IRAN server IP: " IP_IRAN
read -p "Enter FOREIGN server IP: " IP_FOREIGN

# بررسی تونل قبلی
cleanup_tunnel() {
    ip tunnel show "$TUN_NAME" &> /dev/null
    if [[ $? -eq 0 ]]; then
        echo "[*] Removing existing tunnel $TUN_NAME..."
        sudo ip tunnel del "$TUN_NAME"
    fi
}

# فعال‌سازی IP Forwarding
enable_ip_forwarding() {
    echo "[*] Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    sudo sysctl -p > /dev/null
}

# پیکربندی ایران
setup_iran() {
    echo "[*] Configuring as IRAN server..."
    cleanup_tunnel
    sudo ip tunnel add "$TUN_NAME" mode gre local "$IP_IRAN" remote "$IP_FOREIGN" ttl 255
    sudo ip link set "$TUN_NAME" up
    sudo ip addr add 132.168.30.2/30 dev "$TUN_NAME"
    enable_ip_forwarding
    echo -e "${YELLOW}[INFO] Tunnel is up. Use destination IP: 132.168.30.1${RESET}"
}

# پیکربندی خارجی
setup_foreign() {
    echo "[*] Configuring as FOREIGN server..."
    cleanup_tunnel
    sudo ip tunnel add "$TUN_NAME" mode gre local "$IP_FOREIGN" remote "$IP_IRAN" ttl 255
    sudo ip link set "$TUN_NAME" up
    sudo ip addr add 132.168.30.1/30 dev "$TUN_NAME"
    enable_ip_forwarding
    echo -e "${YELLOW}[INFO] Tunnel is up. Use destination IP: 132.168.30.2${RESET}"
}

# ساخت اسکریپت دائم
create_persistent_script() {
    SCRIPT_PATH="/usr/local/bin/setup-gre-${TUN_NAME}.sh"
    echo "[*] Creating persistent setup script at $SCRIPT_PATH"

    sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash
ip tunnel add "$TUN_NAME" mode gre local "$([ "$LOCATION" == "1" ] && echo "$IP_IRAN" || echo "$IP_FOREIGN")" remote "$([ "$LOCATION" == "1" ] && echo "$IP_FOREIGN" || echo "$IP_IRAN")" ttl 255
ip link set "$TUN_NAME" up
ip addr add $([ "$LOCATION" == "1" ] && echo "132.168.30.2/30" || echo "132.168.30.1/30") dev "$TUN_NAME"
sysctl -w net.ipv4.ip_forward=1
EOF

    sudo chmod +x "$SCRIPT_PATH"
}

# ساخت systemd service
create_systemd_service() {
    SERVICE_NAME="gre-${TUN_NAME}.service"
    SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

    echo "[*] Creating systemd service: $SERVICE_NAME"

    sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=GRE Tunnel: $TUN_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-gre-${TUN_NAME}.sh
ExecStop=/sbin/ip tunnel del $TUN_NAME

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    echo -e "${YELLOW}[INFO] GRE tunnel will auto-start at boot.${RESET}"
}

# اجرای پیکربندی بر اساس موقعیت
case "$LOCATION" in
    1) setup_iran ;;
    2) setup_foreign ;;
    *)
        echo "[!] Invalid selection."
        exit 1
        ;;
esac

# پیشنهاد ساخت سرویس دائم
read -p "Do you want to create a systemd service to auto-start the tunnel after reboot? (y/n): " MAKE_SERVICE
if [[ "$MAKE_SERVICE" == "y" || "$MAKE_SERVICE" == "Y" ]]; then
    create_persistent_script
    create_systemd_service
else
    echo "[*] Skipping systemd service creation."
fi
