#!/usr/bin/env bash
set -euo pipefail

PROXY_NAME="openclaw-zerotier-proxy"
PROXY_DIR="/opt/${PROXY_NAME}"
SERVICE_FILE="/etc/systemd/system/${PROXY_NAME}.service"
OPENCLAW_UPSTREAM="${OPENCLAW_UPSTREAM:-127.0.0.1:18789}"
PROXY_PORT="${PROXY_PORT:-80}"
ZT_IP="${ZT_IP:-}"
ZT_IFACE="${ZT_IFACE:-}"
ZT_DETECT_RETRIES="${ZT_DETECT_RETRIES:-3}"
attempt=1

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash scripts/expose-openclaw-zerotier.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/install-docker.sh first."
  exit 1
fi

if ! command -v zerotier-cli >/dev/null 2>&1; then
  echo "ZeroTier is not installed. Run bootstrap.sh first."
  exit 1
fi

if ! systemctl is-active --quiet zerotier-one; then
  echo "Starting ZeroTier..."
  systemctl enable --now zerotier-one
fi

if [[ ! "$ZT_DETECT_RETRIES" =~ ^[0-9]+$ || "$ZT_DETECT_RETRIES" -lt 1 ]]; then
  echo "Invalid ZT_DETECT_RETRIES: $ZT_DETECT_RETRIES"
  exit 1
fi

show_zerotier_status() {
  local info networks node_id network_summary

  echo "== ZeroTier status =="
  info="$(zerotier-cli info 2>/dev/null || true)"
  if [[ -n "$info" ]]; then
    node_id="$(awk '{ print $3 }' <<<"$info")"
    echo "Node ID: ${node_id:-unknown}"
    echo "$info"
  else
    echo "Node ID: unknown"
  fi

  networks="$(zerotier-cli listnetworks 2>/dev/null || true)"
  if [[ -n "$networks" ]]; then
    echo ""
    echo "Joined ZeroTier networks:"
    network_summary="$(awk '/^200 listnetworks/ { printf "  Network ID: %s", $3; if ($4 != "") printf "  Name: %s", $4; if ($6 != "") printf "  Status: %s", $6; if ($8 != "") printf "  Interface: %s", $8; if ($9 != "") printf "  Addresses: %s", $9; print "" }' <<<"$networks")"
    if [[ -n "$network_summary" ]]; then
      echo "$network_summary"
      echo ""
      echo "Raw ZeroTier network output:"
    fi
    echo "$networks"
  else
    echo ""
    echo "No joined ZeroTier networks found."
  fi
}

find_zerotier_address() {
  local iface_path iface ip_addr

  shopt -s nullglob
  for iface_path in /sys/class/net/zt*; do
    iface="$(basename "$iface_path")"
    ip_addr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"

    if [[ -n "$ip_addr" ]]; then
      ZT_IFACE="$iface"
      ZT_IP="$ip_addr"
      return 0
    fi
  done

  return 1
}

show_zerotier_status

if [[ -z "$ZT_IP" || -z "$ZT_IFACE" ]]; then
  attempt=1

  echo "== Detecting ZeroTier address =="
  until find_zerotier_address; do
    echo ""
    echo "No ZeroTier IPv4 address found."
    echo "If the node was just joined, authorize it in ZeroTier Central and wait for an address assignment."

    if [[ "$attempt" -ge "$ZT_DETECT_RETRIES" ]]; then
      echo "Giving up after ${ZT_DETECT_RETRIES} attempts."
      echo "Rerun this script after the node has a ZeroTier address."
      exit 1
    fi

    read -rp "Press Enter to retry ZeroTier address detection, or type q to quit: " RETRY_ZT_DETECT
    if [[ "$RETRY_ZT_DETECT" =~ ^[Qq]$ ]]; then
      echo "Stopped before configuring the proxy."
      exit 1
    fi

    attempt=$((attempt + 1))
    show_zerotier_status
    echo "== Retrying ZeroTier address detection (${attempt}/${ZT_DETECT_RETRIES}) =="
  done
fi

if [[ ! "$ZT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid ZT_IP: $ZT_IP"
  exit 1
fi

if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ || "$PROXY_PORT" -lt 1 || "$PROXY_PORT" -gt 65535 ]]; then
  echo "Invalid PROXY_PORT: $PROXY_PORT"
  exit 1
fi

echo "== Configuring OpenClaw ZeroTier reverse proxy =="
echo "ZeroTier interface: $ZT_IFACE"
echo "ZeroTier address:   $ZT_IP"
echo "Proxy port:         $PROXY_PORT"
echo "OpenClaw upstream:  $OPENCLAW_UPSTREAM"

mkdir -p "$PROXY_DIR"

cat > "${PROXY_DIR}/Caddyfile" <<EOF
{
	auto_https off
	admin off
}

http://${ZT_IP}:${PROXY_PORT} {
	bind ${ZT_IP}
	reverse_proxy http://${OPENCLAW_UPSTREAM}
	header {
		-Server
	}
}
EOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenClaw ZeroTier reverse proxy
Requires=docker.service zerotier-one.service
After=docker.service zerotier-one.service

[Service]
Restart=unless-stopped
RestartSec=5
ExecStartPre=-/usr/bin/docker rm -f ${PROXY_NAME}
ExecStart=/usr/bin/docker run --rm --name ${PROXY_NAME} --network host -v ${PROXY_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecStop=-/usr/bin/docker stop ${PROXY_NAME}

[Install]
WantedBy=multi-user.target
EOF

echo "== Pulling Caddy image =="
docker pull caddy:2-alpine

echo "== Enabling reverse proxy service =="
systemctl daemon-reload
systemctl enable --now "$PROXY_NAME"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "== Allowing proxy port through UFW on ZeroTier only =="
  ufw allow in on "$ZT_IFACE" to "$ZT_IP" port "$PROXY_PORT" proto tcp comment "OpenClaw via ZeroTier"
fi

echo ""
echo "== Done =="
echo "OpenClaw should be reachable from ZeroTier peers at:"
if [[ "$PROXY_PORT" == "80" ]]; then
  echo "  http://${ZT_IP}/"
else
  echo "  http://${ZT_IP}:${PROXY_PORT}/"
fi
