#!/bin/bash
# ==============================================================================
# Script: fix_ap_ip.sh
# Purpose: Fix Padavan 4.4 AP Mode (Operation Mode 3) Auto IP Renewal & Web Access
# Root Cause:
# 1. When switching to AP mode, br0 bridges all ports, but udhcpc.sh does not
#    update NVRAM ('lan_ipaddr_t'), route, or notify httpd / dnsmasq upon DHCP lease renew.
# 2. When upstream primary router rebooted or IP pool changed, Padavan stays stuck
#    with an invalid IP or inaccessible Web interface.
# 3. Cable re-plug did not trigger udhcpc force renewal.
# ==============================================================================

set -e
PADAVAN_ROOT="${1:-/opt/padavan}"

echo "=========================================================="
echo ">> Patching Padavan 4.4 AP Mode IP Auto-Update System..."
echo ">> Root Directory: ${PADAVAN_ROOT}"
echo "=========================================================="

UDHCPC_SCRIPT="${PADAVAN_ROOT}/trunk/user/scripts/udhcpc.sh"
SERVICES_C="${PADAVAN_ROOT}/trunk/user/rc/services_ex.c"
STORAGE_DIR="${PADAVAN_ROOT}/trunk/user/scripts"

# 1. Patch trunk/user/scripts/udhcpc.sh
if [ -f "$UDHCPC_SCRIPT" ]; then
  echo ">> Patching ${UDHCPC_SCRIPT} with AP mode dynamic lease hook..."

  # Check if our custom hook is already present
  if ! grep -q "AP_MODE_IP_AUTO_UPDATE_HOOK" "$UDHCPC_SCRIPT"; then
    cat << 'EOF' > /tmp/udhcpc_hook.txt
# === AP_MODE_IP_AUTO_UPDATE_HOOK (Fix AP Mode IP renewal) ===
if [ "$(nvram get sw_mode)" = "3" ] || [ "$(nvram get operation_mode)" = "3" ]; then
    case "$1" in
        deconfig)
            logger -t "udhcpc[AP]" "br0 IP lease deconfig/lost from upstream gateway"
            ;;
        renew|bound)
            logger -t "udhcpc[AP]" "Received IP ${ip} from gateway ${router}, netmask ${subnet}"
            [ -n "$ip" ] && nvram set lan_ipaddr_t="$ip"
            [ -n "$subnet" ] && nvram set lan_netmask_t="$subnet"
            [ -n "$router" ] && nvram set lan_gateway_t="$router"
            
            # Update routing table
            if [ -n "$router" ]; then
                route del default gw 0.0.0.0 dev br0 2>/dev/null || true
                route add default gw "$router" dev br0 2>/dev/null || true
            fi
            
            # Update local /etc/hosts for seamless access via domain
            sed -i '/my.router/d' /etc/hosts 2>/dev/null || true
            sed -i '/k2p.lan/d' /etc/hosts 2>/dev/null || true
            echo "${ip} my.router k2p.lan" >> /etc/hosts
            
            # Signal httpd and dnsmasq to re-read IP and interface binding
            killall -SIGHUP httpd 2>/dev/null || true
            killall -HUP dnsmasq 2>/dev/null || true
            
            # Execute user hook if exists
            [ -x /etc/storage/udhcpc_ap.sh ] && /etc/storage/udhcpc_ap.sh "$@" &
            ;;
    esac
fi
# === END AP_MODE_IP_AUTO_UPDATE_HOOK ===
EOF
    # Inject right before the exit of udhcpc.sh safely using standard POSIX sed
    if grep -q "exit 0" "$UDHCPC_SCRIPT"; then
      sed -i '/exit 0/r /tmp/udhcpc_hook.txt' "$UDHCPC_SCRIPT"
    else
      cat /tmp/udhcpc_hook.txt >> "$UDHCPC_SCRIPT"
    fi
    rm -f /tmp/udhcpc_hook.txt
    echo ">> Successfully hooked udhcpc.sh!"
  fi
else
  echo "WARN: ${UDHCPC_SCRIPT} not found, checking alternatives..."
fi

# 2. Inject default ap_watchdog.sh into default /etc/storage template
STORAGE_DEF="${PADAVAN_ROOT}/trunk/user/scripts/storage_default.sh"
[ ! -f "$STORAGE_DEF" ] && STORAGE_DEF=$(find "${PADAVAN_ROOT}/trunk" -name "storage_default.sh" 2>/dev/null | head -n 1)
if [ -n "$STORAGE_DEF" ] && [ -f "$STORAGE_DEF" ]; then
  echo ">> Injecting ap_watchdog.sh into $STORAGE_DEF..."
  cat << 'EOF' >> "$STORAGE_DEF"

# Create AP Mode DHCP watchdog on boot
if [ ! -f /etc/storage/ap_watchdog.sh ]; then
cat << 'EOS' > /etc/storage/ap_watchdog.sh
#!/bin/sh
# AP Mode Link & Gateway Watchdog
while true; do
    sleep 25
    SW_MODE=$(nvram get sw_mode)
    [ "$SW_MODE" != "3" ] && continue

    GATEWAY=$(nvram get lan_gateway_t)
    CURRENT_IP=$(ifconfig br0 | grep 'inet addr:' | cut -d: -f2 | awk '{print $1}')

    # If no IP assigned or cannot ping gateway 3 times, trigger udhcpc renewal
    if [ -z "$CURRENT_IP" ] || [ "$CURRENT_IP" = "0.0.0.0" ]; then
        logger -t "AP_WATCHDOG" "No IP on br0, requesting fresh DHCP lease..."
        killall -SIGUSR1 udhcpc 2>/dev/null || udhcpc -i br0 -b -p /var/run/udhcpc_br0.pid -s /sbin/udhcpc.sh
    elif [ -n "$GATEWAY" ]; then
        if ! ping -c 2 -W 3 "$GATEWAY" >/dev/null 2>&1; then
            logger -t "AP_WATCHDOG" "Gateway $GATEWAY unreachable! Sending SIGUSR1 to udhcpc..."
            killall -SIGUSR1 udhcpc 2>/dev/null
        fi
    fi
done
EOS
chmod +x /etc/storage/ap_watchdog.sh
fi

# Auto-start watchdog in AP mode
if [ "$(nvram get sw_mode)" = "3" ]; then
    killall ap_watchdog.sh 2>/dev/null || true
    /etc/storage/ap_watchdog.sh &
fi
EOF
fi

echo ">> AP mode dynamic IP update fix applied cleanly!"
