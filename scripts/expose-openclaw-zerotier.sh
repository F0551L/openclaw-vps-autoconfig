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
ZT_IPS=()
ZT_IFACES=()
ZT_NETWORK_IDS=()
ZT_DETECT_RETRIES="${ZT_DETECT_RETRIES:-3}"
ZT_DETECT_INTERVAL="${ZT_DETECT_INTERVAL:-10}"
WAIT_ZT_ADDRESS="${WAIT_ZT_ADDRESS:-true}"
ZT_ADDRESS_TIMEOUT="${ZT_ADDRESS_TIMEOUT:-}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
NONINTERACTIVE="${NONINTERACTIVE:-false}"
ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"
ZEROTIER_API_TOKEN="${ZEROTIER_API_TOKEN:-}"
ZEROTIER_API_TOKEN_FILE="${ZEROTIER_API_TOKEN_FILE:-}"
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

parse_zerotier_network_ids() {
  local raw token existing
  local -a parsed=()

  ZT_NETWORK_IDS=()
  if [[ -z "$ZT_NETWORK_ID" ]]; then
    return 0
  fi

  raw="${ZT_NETWORK_ID//[[:space:]]/}"
  IFS=',' read -r -a parsed <<<"$raw"

  for token in "${parsed[@]}"; do
    if [[ -z "$token" ]]; then
      echo "Invalid ZeroTier network list: $ZT_NETWORK_ID"
      echo "Use comma-delimited 16-character hexadecimal network IDs."
      exit 1
    fi

    if [[ ! "$token" =~ ^[0-9a-fA-F]{16}$ ]]; then
      echo "Invalid ZeroTier Network ID format: $token"
      echo "Expected a 16-character hexadecimal network ID."
      exit 1
    fi

    for existing in "${ZT_NETWORK_IDS[@]}"; do
      if [[ "${existing,,}" == "${token,,}" ]]; then
        continue 2
      fi
    done

    ZT_NETWORK_IDS+=("$token")
  done
}

zerotier_network_requested() {
  local network_id="$1"
  local requested

  if [[ "${#ZT_NETWORK_IDS[@]}" -eq 0 ]]; then
    return 0
  fi

  for requested in "${ZT_NETWORK_IDS[@]}"; do
    if [[ "${requested,,}" == "${network_id,,}" ]]; then
      return 0
    fi
  done

  return 1
}

load_zerotier_api_token() {
  local perms

  if [[ -z "$ZEROTIER_API_TOKEN_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$ZEROTIER_API_TOKEN_FILE" ]]; then
    echo "ZeroTier API token file not found: $ZEROTIER_API_TOKEN_FILE"
    exit 1
  fi

  if [[ "$(stat -c "%u" "$ZEROTIER_API_TOKEN_FILE")" != "0" ]]; then
    echo "ZeroTier API token file must be owned by root: $ZEROTIER_API_TOKEN_FILE"
    exit 1
  fi

  perms="$(stat -c "%A" "$ZEROTIER_API_TOKEN_FILE")"
  if [[ "${perms:5:1}" == "w" || "${perms:8:1}" == "w" ]]; then
    echo "ZeroTier API token file must not be writable by group or other users: $ZEROTIER_API_TOKEN_FILE"
    echo "Run: sudo chmod 600 $ZEROTIER_API_TOKEN_FILE"
    exit 1
  fi

  ZEROTIER_API_TOKEN="$(head -n 1 "$ZEROTIER_API_TOKEN_FILE" | tr -d '\r')"
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

find_zerotier_addresses() {
  local networks network_id iface ip_addr found_count=0

  ZT_IPS=()
  ZT_IFACES=()

  networks="$(zerotier-cli listnetworks 2>/dev/null || true)"
  while read -r network_id iface; do
    if [[ -z "$network_id" || -z "$iface" ]]; then
      continue
    fi

    if ! zerotier_network_requested "$network_id"; then
      continue
    fi

    ip_addr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"

    if [[ -n "$ip_addr" ]]; then
      ZT_IFACES+=("$iface")
      ZT_IPS+=("$ip_addr")
      found_count=$((found_count + 1))
    fi
  done < <(awk '/^200 listnetworks/ && $6 == "OK" { print $3, $8 }' <<<"$networks")

  if [[ "${#ZT_NETWORK_IDS[@]}" -gt 0 && "$found_count" -lt "${#ZT_NETWORK_IDS[@]}" ]]; then
    return 1
  fi

  if [[ "$found_count" -gt 0 ]]; then
    ZT_IFACE="${ZT_IFACES[0]}"
    ZT_IP="${ZT_IPS[0]}"
    return 0
  fi

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

get_zerotier_node_id() {
  zerotier-cli info 2>/dev/null | awk '{ print $3; exit }'
}

get_joined_network_id() {
  zerotier-cli listnetworks 2>/dev/null | awk -v target="$ZT_NETWORK_ID" '
    /^200 listnetworks/ {
      if (target != "" && tolower($3) == tolower(target)) {
        print $3
        exit
      }
      if (fallback == "") {
        fallback = $3
      }
    }
    END {
      if (target == "" && fallback != "") {
        print fallback
      }
    }
  '
}

authorize_zerotier_member_for_network() {
  local node_id network_id api_url payload response_file http_code

  if [[ -z "$ZEROTIER_API_TOKEN" ]]; then
    return 1
  fi

  node_id="$(get_zerotier_node_id)"
  network_id="$1"

  if [[ -z "$node_id" || -z "$network_id" ]]; then
    echo "ZeroTier API token provided, but node ID or network ID could not be detected."
    return 1
  fi

  api_url="https://api.zerotier.com/api/v1/network/${network_id}/member/${node_id}"
  payload='{"config":{"authorized":true}}'
  response_file="$(mktemp)"

  echo "== Attempting ZeroTier Central auto-authorization =="
  echo "Network ID: $network_id"
  echo "Member ID:  $node_id"

  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    -H "Authorization: token ${ZEROTIER_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$api_url" || true)"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "ZeroTier Central authorization request succeeded (HTTP ${http_code})."
    rm -f "$response_file"
    return 0
  fi

  echo "ZeroTier Central authorization request failed (HTTP ${http_code:-unknown})."
  if [[ -s "$response_file" ]]; then
    cat "$response_file"
    echo ""
  fi
  rm -f "$response_file"
  return 1
}

authorize_zerotier_members() {
  local network_id authorized=false

  if [[ -z "$ZEROTIER_API_TOKEN" ]]; then
    return 1
  fi

  if [[ "${#ZT_NETWORK_IDS[@]}" -gt 0 ]]; then
    for network_id in "${ZT_NETWORK_IDS[@]}"; do
      if authorize_zerotier_member_for_network "$network_id"; then
        authorized=true
      fi
    done
  else
    network_id="$(get_joined_network_id)"
    if authorize_zerotier_member_for_network "$network_id"; then
      authorized=true
    fi
  fi

  $authorized
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

configure_openclaw_gateway() {
  local zt_ip http_control_origin https_control_origin allowed_origins configured_token

  if [[ ! -d "$OPENCLAW_DIR" ]]; then
    echo "OpenClaw directory not found at $OPENCLAW_DIR; skipping gateway config."
    return 0
  fi

  allowed_origins='["http://localhost:18789","http://127.0.0.1:18789"'

  echo "== Allowing OpenClaw Control UI origins =="
  echo "Allowed origins:"
  for zt_ip in "${ZT_IPS[@]}"; do
    http_control_origin="$(format_origin http "$zt_ip" "$PROXY_PORT")"
    https_control_origin="$(format_origin https "$zt_ip" "$HTTPS_PROXY_PORT")"
    allowed_origins+=",\"${http_control_origin}\",\"${https_control_origin}\""
    echo "  ${http_control_origin}"
    echo "  ${https_control_origin}"
  done
  allowed_origins+=']'

  echo "== Configuring OpenClaw gateway token auth =="
  configured_token="$(
    cd "$OPENCLAW_DIR"
    docker compose run --rm -T --entrypoint node openclaw-cli - "$allowed_origins" "$GATEWAY_TOKEN" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");

const [allowedOriginsJson, preferredToken] = process.argv.slice(2);
const configPath = "/home/node/.openclaw/openclaw.json";
const configDir = "/home/node/.openclaw";

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, "utf8"));
} catch {}

const ensureObject = (parent, key) => {
  if (!parent[key] || typeof parent[key] !== "object" || Array.isArray(parent[key])) {
    parent[key] = {};
  }
  return parent[key];
};

const gateway = ensureObject(config, "gateway");
const controlUi = ensureObject(gateway, "controlUi");
const auth = ensureObject(gateway, "auth");
const remote = ensureObject(gateway, "remote");
const token = preferredToken || auth.token || crypto.randomBytes(32).toString("hex");
const requiredOrigins = JSON.parse(allowedOriginsJson);

controlUi.allowedOrigins = [...new Set(requiredOrigins)];
auth.mode = "token";
auth.token = token;
remote.token = token;

fs.mkdirSync(configDir, { recursive: true });
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
process.stdout.write(token);
NODE
  )"
  GATEWAY_TOKEN="$configured_token"
}

generate_self_signed_cert() {
  local zt_ip="$1"
  local cert_dir cert_name cert_path key_path

  cert_dir="${PROXY_DIR}/certs"
  cert_name="openclaw-zt-${zt_ip}"
  cert_path="${cert_dir}/${cert_name}.crt"
  key_path="${cert_dir}/${cert_name}.key"

  mkdir -p "$cert_dir"
  chmod 700 "$cert_dir"

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    echo "== Reusing existing self-signed HTTPS certificate =="
  else
    echo "== Generating self-signed HTTPS certificate for ${zt_ip} =="
    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
      -keyout "$key_path" \
      -out "$cert_path" \
      -subj "/CN=${zt_ip}" \
      -addext "subjectAltName=IP:${zt_ip}"
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
  fi
}

show_zerotier_status
parse_zerotier_network_ids
load_zerotier_api_token

if [[ -n "$ZT_IP" && -z "$ZT_IFACE" ]]; then
  find_zerotier_interface_for_ip || true
fi

if [[ -n "$ZT_IP" && -n "$ZT_IFACE" ]]; then
  ZT_IPS=("$ZT_IP")
  ZT_IFACES=("$ZT_IFACE")
fi

if [[ -z "$ZT_IP" || -z "$ZT_IFACE" ]]; then
  if authorize_zerotier_members; then
    attempt=$((ZT_DETECT_RETRIES + 1))
  else
    attempt=1
  fi

  if [[ -n "$ZT_ADDRESS_TIMEOUT" ]]; then
    zt_address_deadline=$((SECONDS + ZT_ADDRESS_TIMEOUT))
  else
    zt_address_deadline=0
  fi

  echo "== Detecting ZeroTier address =="
  until find_zerotier_addresses; do
    echo ""
    echo "No ZeroTier IPv4 address found for every selected network."
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

for zt_ip in "${ZT_IPS[@]}"; do
  if [[ ! "$zt_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Invalid ZeroTier IP: $zt_ip"
    exit 1
  fi
done

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
echo "ZeroTier bindings:"
for binding_index in "${!ZT_IPS[@]}"; do
  echo "  ${ZT_IFACES[$binding_index]} ${ZT_IPS[$binding_index]}"
done
echo "HTTP proxy port:    $PROXY_PORT"
echo "HTTPS proxy port:   $HTTPS_PROXY_PORT"
echo "OpenClaw upstream:  $OPENCLAW_UPSTREAM"

mkdir -p "$PROXY_DIR"
for zt_ip in "${ZT_IPS[@]}"; do
  generate_self_signed_cert "$zt_ip"
done

HTTPS_CONTROL_ORIGIN="$(format_origin https "${ZT_IPS[0]}" "$HTTPS_PROXY_PORT")"

cat > "${PROXY_DIR}/Caddyfile" <<'EOF'
{
	admin off
}

EOF

for zt_ip in "${ZT_IPS[@]}"; do
  https_control_origin="$(format_origin https "$zt_ip" "$HTTPS_PROXY_PORT")"
  cat >> "${PROXY_DIR}/Caddyfile" <<EOF
http://${zt_ip}:${PROXY_PORT} {
	bind ${zt_ip}
	redir ${https_control_origin}{uri} permanent
}

https://${zt_ip}:${HTTPS_PROXY_PORT} {
	bind ${zt_ip}
	tls /etc/caddy/certs/openclaw-zt-${zt_ip}.crt /etc/caddy/certs/openclaw-zt-${zt_ip}.key
	reverse_proxy http://${OPENCLAW_UPSTREAM}
	header {
		-Server
	}
}
EOF
done

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

configure_openclaw_gateway
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
  for binding_index in "${!ZT_IPS[@]}"; do
    ufw allow in on "${ZT_IFACES[$binding_index]}" to "${ZT_IPS[$binding_index]}" port "$PROXY_PORT" proto tcp comment "OpenClaw via ZeroTier"
    ufw allow in on "${ZT_IFACES[$binding_index]}" to "${ZT_IPS[$binding_index]}" port "$HTTPS_PROXY_PORT" proto tcp comment "OpenClaw HTTPS via ZeroTier"
  done
fi

echo ""
echo "== Done =="
echo "OpenClaw should be reachable from ZeroTier peers at:"
for zt_ip in "${ZT_IPS[@]}"; do
  echo "  $(format_origin https "$zt_ip" "$HTTPS_PROXY_PORT")/"
done
echo "Tokenized setup URL:"
echo "  ${HTTPS_CONTROL_ORIGIN}/#token=${GATEWAY_TOKEN}"
echo ""
echo "Install and trust these certificates on your client devices if the browser does not trust them yet:"
for zt_ip in "${ZT_IPS[@]}"; do
  echo "  ${PROXY_DIR}/certs/openclaw-zt-${zt_ip}.crt"
done
echo ""
echo "Gateway token for the Control UI:"
echo "  ${GATEWAY_TOKEN}"
echo ""
echo "After the browser shows pairing required, approve the pending device with:"
echo "  sudo bash scripts/approve-openclaw-device.sh"
