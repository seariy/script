#!/bin/bash
# ==============================================================================
# Script: install_plugins.sh
# Purpose: Pre-download & prepare MIPS binaries for Cloudflared, Caddy, VNT
# Target Architecture: MediaTek MT7621 (mipsel / mipsle - 32-bit Little Endian)
# ==============================================================================

set -e
PADAVAN_ROOT="${1:-/opt/padavan}"
ENABLE_UPX="${2:-true}"

BIN_DIR="${PADAVAN_ROOT}/trunk/user/plugins_bin"
ROOTFS_DIR="${PADAVAN_ROOT}/trunk/romfs"
STORAGE_DEFAULT="${PADAVAN_ROOT}/trunk/user/scripts/storage_default.sh"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR"

echo "=========================================================="
echo ">> Downloading and Preparing MIPS32le Binaries..."
echo ">> Binary directory: ${BIN_DIR}"
echo ">> UPX Compression: ${ENABLE_UPX}"
echo "=========================================================="

# 1. Cloudflared (Argo Tunnel Client)
if [ "true" = "true" ]; then
  echo ">> Fetching Cloudflared for Linux mipsle..."
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-mipsle"
  curl -sL --retry 3 "$CF_URL" -o cloudflared || {
    echo "WARN: Direct download failed, using fallback mirror..."
    curl -sL --retry 3 "https://fastly.jsdelivr.net/gh/cloudflare/cloudflared@master/cloudflared-linux-mipsle" -o cloudflared || true
  }
  if [ -f cloudflared ]; then
    chmod +x cloudflared
    if [ "$ENABLE_UPX" = "true" ] && command -v upx >/dev/null 2>&1; then
      echo ">> UPX compressing cloudflared..."
      upx --ultra-brute cloudflared 2>/dev/null || upx -9 cloudflared 2>/dev/null || true
    fi
  fi
fi

# 2. Caddy (Reverse Proxy & Web Server)
if [ "true" = "true" ]; then
  echo ">> Fetching Caddy for Linux mipsle..."
  # Download official Caddy mipsle release or prebuilt musl/uclibc
  CADDY_URL="https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_mipsle_softfloat.tar.gz"
  curl -sL --retry 3 "$CADDY_URL" -o caddy.tar.gz || true
  if [ -f caddy.tar.gz ]; then
    tar -xzf caddy.tar.gz caddy
    chmod +x caddy
    rm -f caddy.tar.gz
    if [ "$ENABLE_UPX" = "true" ] && command -v upx >/dev/null 2>&1; then
      echo ">> UPX compressing caddy..."
      upx --ultra-brute caddy 2>/dev/null || upx -9 caddy 2>/dev/null || true
    fi
  fi
fi

# 3. VNT (Virtual Network Tunnel)
if [ "true" = "true" ]; then
  echo ">> Fetching VNT (meshbird/vnt) for MIPS32le..."
  VNT_URL="https://github.com/vnt-dev/vnt/releases/download/v1.2.14/vnt-cli_mipsel-unknown-linux-musl_1.2.14.tar.gz"
  curl -sL --retry 3 "$VNT_URL" -o vnt.tar.gz || {
    curl -sL --retry 3 "https://github.com/vnt-dev/vnt/releases/latest/download/vnt-cli_mipsel-unknown-linux-musl.tar.gz" -o vnt.tar.gz || true
  }
  if [ -f vnt.tar.gz ]; then
    tar -xzf vnt.tar.gz
    chmod +x vnt-cli
    rm -f vnt.tar.gz
    if [ "$ENABLE_UPX" = "true" ] && command -v upx >/dev/null 2>&1; then
      echo ">> UPX compressing vnt-cli..."
      upx --ultra-brute vnt-cli 2>/dev/null || upx -9 vnt-cli 2>/dev/null || true
    fi
  fi
fi

# 4. Integrate into Padavan build system / romfs
mkdir -p "${PADAVAN_ROOT}/trunk/romfs/usr/bin"
mkdir -p "${PADAVAN_ROOT}/trunk/romfs/etc/storage/caddy"

# Depending on flash size:
# 16MB Flash: store startup download scripts to /etc/storage (loads binary from USB/ramdisk)
# 32MB Flash: embed small binaries (vnt-cli, etc.) directly into /usr/bin!
if [ -f vnt-cli ]; then
  cp -f vnt-cli "${PADAVAN_ROOT}/trunk/romfs/usr/bin/"
fi

# Copy management scripts to default storage template
cat << 'EOF' >> "$STORAGE_DEFAULT"

# === Cloudflared Service Manager ===
cat << 'EOS' > /etc/storage/cloudflared.sh
#!/bin/sh
# Usage: /etc/storage/cloudflared.sh {start|stop|restart|status}
TUNNEL_TOKEN="$(nvram get cf_tunnel_token)"
BIN_PATH="/media/AiDisk_a1/bin/cloudflared"
[ ! -x "$BIN_PATH" ] && BIN_PATH="/usr/bin/cloudflared"

case "$1" in
  start)
    if [ -z "$TUNNEL_TOKEN" ]; then
      logger -t "cloudflared" "Error: cf_tunnel_token is empty in nvram!"
      exit 1
    fi
    if [ ! -x "$BIN_PATH" ]; then
      logger -t "cloudflared" "Downloading cloudflared to /tmp/cloudflared..."
      curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-mipsle -o /tmp/cloudflared
      chmod +x /tmp/cloudflared
      BIN_PATH="/tmp/cloudflared"
    fi
    killall cloudflared 2>/dev/null || true
    $BIN_PATH tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" >/dev/null 2>&1 &
    logger -t "cloudflared" "Cloudflared tunnel service started."
    ;;
  stop)
    killall cloudflared 2>/dev/null || true
    logger -t "cloudflared" "Cloudflared service stopped."
    ;;
  restart)
    $0 stop
    sleep 2
    $0 start
    ;;
  status)
    pidof cloudflared >/dev/null && echo "Running" || echo "Stopped"
    ;;
esac
EOS
chmod +x /etc/storage/cloudflared.sh

# === Caddy Service Manager ===
cat << 'EOS' > /etc/storage/caddy.sh
#!/bin/sh
# Usage: /etc/storage/caddy.sh {start|stop|restart}
CONF_FILE="/etc/storage/caddy/Caddyfile"
BIN_PATH="/media/AiDisk_a1/bin/caddy"
[ ! -x "$BIN_PATH" ] && BIN_PATH="/usr/bin/caddy"

case "$1" in
  start)
    [ ! -f "$CONF_FILE" ] && echo -e ":8080 {\n  respond \"Hello from Padavan K2P Caddy!\"\n}" > "$CONF_FILE"
    killall caddy 2>/dev/null || true
    $BIN_PATH run --config "$CONF_FILE" >/dev/null 2>&1 &
    logger -t "caddy" "Caddy service started on :8080"
    ;;
  stop)
    killall caddy 2>/dev/null || true
    ;;
  restart)
    $0 stop
    sleep 2
    $0 start
    ;;
esac
EOS
chmod +x /etc/storage/caddy.sh

# === VNT P2P Mesh Tunnel Manager ===
cat << 'EOS' > /etc/storage/vnt.sh
#!/bin/sh
# Usage: /etc/storage/vnt.sh {start|stop|status}
VNT_TOKEN="$(nvram get vnt_token)"
VNT_SERVER="$(nvram get vnt_server)"
VNT_NAME="$(nvram get vnt_name)"
[ -z "$VNT_SERVER" ] && VNT_SERVER="vnt.crosschannel.cn:29872"
[ -z "$VNT_NAME" ] && VNT_NAME="K2P-Router"

case "$1" in
  start)
    if [ -z "$VNT_TOKEN" ]; then
      logger -t "vnt" "vnt_token not set in nvram. Waiting for config."
      exit 1
    fi
    killall vnt-cli 2>/dev/null || true
    vnt-cli -k "$VNT_TOKEN" -s "$VNT_SERVER" -d "$VNT_NAME" --model-tun >/dev/null 2>&1 &
    logger -t "vnt" "VNT P2P tunnel started for $VNT_NAME"
    ;;
  stop)
    killall vnt-cli 2>/dev/null || true
    ;;
  status)
    pidof vnt-cli >/dev/null && echo "Running" || echo "Stopped"
    ;;
esac
EOS
chmod +x /etc/storage/vnt.sh
EOF

echo ">> Plugin preparation completed successfully!"
