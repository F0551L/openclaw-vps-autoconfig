#!/usr/bin/env bash
set -euo pipefail

PROXY_NAME="openclaw-zerotier-proxy"
PROXY_DIR="/opt/${PROXY_NAME}"
SERVICE_FILE="/etc/systemd/system/${PROXY_NAME}.service"
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_UPSTREAM="${OPENCLAW_UPSTREAM:-127.0.0.1:18789}"
PROXY_PORT="${PROXY_PORT:-80}"
HTTPS_PROXY_PORT="${HTTPS_PROXY_PORT:-443}"
ZT_IP="${ZT_IP:-}"
ZT_IFACE="${ZT_IFACE:-}"
ZT_DETECT_RETRIES="${ZT_DETECT_RETRIES:-3}"
ZT_DETECT_INTERVAL="${ZT_DETECT_INTERVAL:-10}"
WAIT_ZT_ADDRESS="${WAIT_ZT_ADDRESS:-true}"
ZT_ADDRESS_TIMEOUT="${ZT_ADDRESS_TIMEOUT:-}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
NONINTERACTIVE="${NONINTERACTIVE:-false}"
attempt=1

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash scripts/expose-openclaw-zerotier.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/install-docker.sh first."
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "Installing OpenSSL..."
  apt-get update
  apt-get install -y openssl
fi

if ! command -v zerotier-cli >/dev/null 2>&1; then
  echo "ZeroTier is not installed. Run clawtier.sh first."
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

if [[ ! "$ZT_DETECT_INTERVAL" =~ ^[0-9]+$ || "$ZT_DETECT_INTERVAL" -lt 1 ]]; then
  echo "Invalid ZT_DETECT_INTERVAL: $ZT_DETECT_INTERVAL"
  exit 1
fi

if [[ -n "$ZT_ADDRESS_TIMEOUT" && ! "$ZT_ADDRESS_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "Invalid ZT_ADDRESS_TIMEOUT: $ZT_ADDRESS_TIMEOUT"
  exit 1
fi

is_true() {
  [[ "${1:-}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy])$ ]]
}

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

find_zerotier_interface_for_ip() {
  local iface_path iface ip_addr

  shopt -s nullglob
  for iface_path in /sys/class/net/zt*; do
    iface="$(basename "$iface_path")"
    ip_addr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"

    if [[ "$ip_addr" == "$ZT_IP" ]]; then
      ZT_IFACE="$iface"
      return 0
    fi
  done

  return 1
}

format_origin() {
  local scheme="$1"
  local host="$2"
  local port="$3"

  if [[ "$scheme" == "http" && "$port" == "80" ]] || [[ "$scheme" == "https" && "$port" == "443" ]]; then
    echo "${scheme}://${host}"
  else
    echo "${scheme}://${host}:${port}"
  fi
}

run_openclaw_cli() {
  (
    cd "$OPENCLAW_DIR"
    docker compose run --rm openclaw-cli "$@"
  )
}

get_existing_gateway_token() {
  (
    cd "$OPENCLAW_DIR"
    docker compose run --rm --entrypoint node openclaw-cli -e 'try { const fs = require("fs"); const config = JSON.parse(fs.readFileSync("/home/node/.openclaw/openclaw.json", "utf8")); process.stdout.write(config?.gateway?.auth?.token || ""); } catch {}'
  )
}

configure_openclaw_allowed_origins() {
  local http_control_origin https_control_origin allowed_origins

  if [[ ! -d "$OPENCLAW_DIR" ]]; then
    echo "OpenClaw directory not found at $OPENCLAW_DIR; skipping Control UI allowed origin config."
    return 0
  fi

  http_control_origin="$(format_origin http "$ZT_IP" "$PROXY_PORT")"
  https_control_origin="$(format_origin https "$ZT_IP" "$HTTPS_PROXY_PORT")"

  allowed_origins="[\"http://localhost:18789\",\"http://127.0.0.1:18789\",\"${http_control_origin}\",\"${https_control_origin}\"]"

  echo "== Allowing OpenClaw Control UI origins =="
  echo "Allowed origins:"
  echo "  ${http_control_origin}"
  echo "  ${https_control_origin}"
  run_openclaw_cli config set gateway.controlUi.allowedOrigins "$allowed_origins"
}

configure_openclaw_gateway_auth() {
  local existing_token

  if [[ ! -d "$OPENCLAW_DIR" ]]; then
    echo "OpenClaw directory not found at $OPENCLAW_DIR; skipping gateway token config."
    return 0
  fi

  if [[ -z "$GATEWAY_TOKEN" ]]; then
    existing_token="$(get_existing_gateway_token)"
    if [[ -n "$existing_token" ]]; then
      GATEWAY_TOKEN="$existing_token"
    else
      GATEWAY_TOKEN="$(openssl rand -hex 32)"
    fi
  fi

  echo "== Configuring OpenClaw gateway token auth =="
  run_openclaw_cli config set gateway.auth.mode token
  run_openclaw_cli config set gateway.auth.token "$GATEWAY_TOKEN"
  run_openclaw_cli config set gateway.remote.token "$GATEWAY_TOKEN"
}

generate_self_signed_cert() {
  local cert_dir cert_name cert_path key_path

  cert_dir="${PROXY_DIR}/certs"
  cert_name="openclaw-zt-${ZT_IP}"
  cert_path="${cert_dir}/${cert_name}.crt"
  key_path="${cert_dir}/${cert_name}.key"

  mkdir -p "$cert_dir"
  chmod 700 "$cert_dir"

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    echo "== Reusing existing self-signed HTTPS certificate =="
  else
    echo "== Generating self-signed HTTPS certificate for ${ZT_IP} =="
    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
      -keyout "$key_path" \
      -out "$cert_path" \
      -subj "/CN=${ZT_IP}" \
      -addext "subjectAltName=IP:${ZT_IP}"
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
  fi
}

show_zerotier_status

if [[ -n "$ZT_IP" && -z "$ZT_IFACE" ]]; then
  find_zerotier_interface_for_ip || true
fi

if [[ -z "$ZT_IP" || -z "$ZT_IFACE" ]]; then
  attempt=1
  if [[ -n "$ZT_ADDRESS_TIMEOUT" ]]; then
    zt_address_deadline=$((SECONDS + ZT_ADDRESS_TIMEOUT))
  else
    zt_address_deadline=0
  fi

  echo "== Detecting ZeroTier address =="
  until find_zerotier_address; do
    echo ""
    echo "No ZeroTier IPv4 address found."
    echo "If the node was just joined, authorize it in ZeroTier Central and wait for an address assignment."

    if ! is_true "$WAIT_ZT_ADDRESS"; then
      echo "Skipping proxy setup because WAIT_ZT_ADDRESS is false."
      echo "Rerun after the node has a ZeroTier address:"
      echo "  sudo bash clawtier.sh -f p -sad"
      exit 0
    fi

    if [[ "$zt_address_deadline" -gt 0 && "$SECONDS" -ge "$zt_address_deadline" ]]; then
      echo "Giving up after ${ZT_ADDRESS_TIMEOUT}s waiting for a ZeroTier address."
      echo "Rerun this script after the node has a ZeroTier address."
      exit 1
    fi

    if [[ "$zt_address_deadline" -eq 0 && "$attempt" -ge "$ZT_DETECT_RETRIES" ]]; then
      echo "Giving up after ${ZT_DETECT_RETRIES} attempts."
      echo "Rerun this script after the node has a ZeroTier address."
      exit 1
    fi

    if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
      echo "Retrying ZeroTier address detection in ${ZT_DETECT_INTERVAL}s..."
      sleep "$ZT_DETECT_INTERVAL"
    else
      read -rp "Press Enter to retry ZeroTier address detection, or type q to quit: " RETRY_ZT_DETECT
      if [[ "$RETRY_ZT_DETECT" =~ ^[Qq]$ ]]; then
        echo "Stopped before configuring the proxy."
        exit 1
      fi
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

if [[ ! "$HTTPS_PROXY_PORT" =~ ^[0-9]+$ || "$HTTPS_PROXY_PORT" -lt 1 || "$HTTPS_PROXY_PORT" -gt 65535 ]]; then
  echo "Invalid HTTPS_PROXY_PORT: $HTTPS_PROXY_PORT"
  exit 1
fi

if [[ "$PROXY_PORT" == "$HTTPS_PROXY_PORT" ]]; then
  echo "PROXY_PORT and HTTPS_PROXY_PORT must be different."
  exit 1
fi

echo "== Configuring OpenClaw ZeroTier reverse proxy =="
echo "ZeroTier interface: $ZT_IFACE"
echo "ZeroTier address:   $ZT_IP"
echo "HTTP proxy port:    $PROXY_PORT"
echo "HTTPS proxy port:   $HTTPS_PROXY_PORT"
echo "OpenClaw upstream:  $OPENCLAW_UPSTREAM"

mkdir -p "$PROXY_DIR"
generate_self_signed_cert

HTTPS_CONTROL_ORIGIN="$(format_origin https "$ZT_IP" "$HTTPS_PROXY_PORT")"

cat > "${PROXY_DIR}/Caddyfile" <<EOF
{
	admin off
}

http://${ZT_IP}:${PROXY_PORT} {
	bind ${ZT_IP}
	redir ${HTTPS_CONTROL_ORIGIN}{uri} permanent
}

https://${ZT_IP}:${HTTPS_PROXY_PORT} {
	bind ${ZT_IP}
	tls /etc/caddy/certs/openclaw-zt-${ZT_IP}.crt /etc/caddy/certs/openclaw-zt-${ZT_IP}.key
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
ExecStart=/usr/bin/docker run --rm --name ${PROXY_NAME} --network host -v ${PROXY_DIR}:/etc/caddy:ro caddy:2-alpine caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecStop=-/usr/bin/docker stop ${PROXY_NAME}

[Install]
WantedBy=multi-user.target
EOF

echo "== Pulling Caddy image =="
docker pull caddy:2-alpine

echo "== Enabling reverse proxy service =="
systemctl daemon-reload
systemctl enable "$PROXY_NAME"
systemctl restart "$PROXY_NAME"

configure_openclaw_allowed_origins
configure_openclaw_gateway_auth
echo "== Restarting OpenClaw after gateway config changes =="
if [[ -d "$OPENCLAW_DIR" ]]; then
  (
    cd "$OPENCLAW_DIR"
    docker compose down
    docker compose up -d
  )
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "== Allowing proxy ports through UFW on ZeroTier only =="
  ufw allow in on "$ZT_IFACE" to "$ZT_IP" port "$PROXY_PORT" proto tcp comment "OpenClaw via ZeroTier"
  ufw allow in on "$ZT_IFACE" to "$ZT_IP" port "$HTTPS_PROXY_PORT" proto tcp comment "OpenClaw HTTPS via ZeroTier"
fi

echo ""
echo "== Done =="
echo "OpenClaw should be reachable from ZeroTier peers at:"
echo "  ${HTTPS_CONTROL_ORIGIN}/"
echo "Tokenized setup URL:"
echo "  ${HTTPS_CONTROL_ORIGIN}/#token=${GATEWAY_TOKEN}"
echo ""
echo "Install and trust this certificate on your client device if the browser does not trust it yet:"
echo "  ${PROXY_DIR}/certs/openclaw-zt-${ZT_IP}.crt"
echo ""
echo "Gateway token for the Control UI:"
echo "  ${GATEWAY_TOKEN}"
echo ""
echo "After the browser shows pairing required, approve the pending device with:"
echo "  sudo bash scripts/approve-openclaw-device.sh"
