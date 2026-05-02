#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_UPSTREAM="${OPENCLAW_UPSTREAM:-127.0.0.1:18789}"
OPENCLAW_URL="${OPENCLAW_URL:-}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
ZT_IP="${ZT_IP:-}"
APPROVAL_POLL_SECONDS="${APPROVAL_POLL_SECONDS:-180}"
APPROVAL_POLL_INTERVAL="${APPROVAL_POLL_INTERVAL:-3}"
NONINTERACTIVE="${NONINTERACTIVE:-false}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash scripts/approve-openclaw-device.sh"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/install-docker.sh first."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  apt-get update
  apt-get install -y jq
fi

if [[ ! -d "$OPENCLAW_DIR" ]]; then
  echo "OpenClaw directory not found at $OPENCLAW_DIR."
  exit 1
fi

if [[ ! "$APPROVAL_POLL_SECONDS" =~ ^[0-9]+$ || "$APPROVAL_POLL_SECONDS" -lt 1 ]]; then
  echo "Invalid APPROVAL_POLL_SECONDS: $APPROVAL_POLL_SECONDS"
  exit 1
fi

if [[ ! "$APPROVAL_POLL_INTERVAL" =~ ^[0-9]+$ || "$APPROVAL_POLL_INTERVAL" -lt 1 ]]; then
  echo "Invalid APPROVAL_POLL_INTERVAL: $APPROVAL_POLL_INTERVAL"
  exit 1
fi

is_true() {
  [[ "${1:-}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy])$ ]]
}

find_zerotier_address() {
  local iface_path iface ip_addr

  shopt -s nullglob
  for iface_path in /sys/class/net/zt*; do
    iface="$(basename "$iface_path")"
    ip_addr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"

    if [[ -n "$ip_addr" ]]; then
      ZT_IP="$ip_addr"
      return 0
    fi
  done

  return 1
}

get_gateway_token() {
  (
    cd "$OPENCLAW_DIR"
    docker compose exec -T openclaw-gateway sh -lc 'node -e "const fs = require(\"fs\"); const config = JSON.parse(fs.readFileSync(\"/home/node/.openclaw/openclaw.json\", \"utf8\")); process.stdout.write(config?.gateway?.auth?.token || \"\");"'
  )
}

run_openclaw_cli() {
  (
    cd "$OPENCLAW_DIR"
    docker compose run --rm openclaw-cli "$@"
  )
}

list_pending_request_ids() {
  local devices_json="$1"

  jq -r '
    [
      .. | objects
      | select(.requestId? != null)
      | select(((.status? // .state? // "pending") | tostring | ascii_downcase) == "pending")
      | .requestId
    ]
    | unique
    | .[]
  ' <<<"$devices_json"
}

approve_request() {
  local request_id="$1"

  echo "== Approving OpenClaw device request =="
  echo "Request ID: $request_id"
  run_openclaw_cli devices approve "$request_id" --url "ws://${OPENCLAW_UPSTREAM}" --token "$GATEWAY_TOKEN"
}

if [[ -z "$GATEWAY_TOKEN" ]]; then
  GATEWAY_TOKEN="$(get_gateway_token)"
fi

if [[ -z "$GATEWAY_TOKEN" ]]; then
  echo "OpenClaw gateway token is empty. Run scripts/expose-openclaw-zerotier.sh first."
  exit 1
fi

if [[ -z "$OPENCLAW_URL" ]]; then
  if [[ -z "$ZT_IP" ]]; then
    find_zerotier_address || true
  fi

  if [[ -z "$ZT_IP" ]]; then
    echo "Could not detect a ZeroTier IP. Set OPENCLAW_URL=https://YOUR_HOST or ZT_IP=YOUR_ZEROTIER_IP."
    exit 1
  fi

  OPENCLAW_URL="https://${ZT_IP}/"
fi

echo "== OpenClaw browser pairing =="
echo "Open this URL on the client/browser you want to approve:"
echo "  ${OPENCLAW_URL}#token=${GATEWAY_TOKEN}"
echo ""

if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
  echo "No interactive approval requested; skipping device approval polling."
  echo "Rerun this step when you can open the URL and respond to the prompt:"
  echo "  sudo bash scripts/approve-openclaw-device.sh"
  exit 0
fi

read -rp "Press Enter after the browser shows pairing required, or type s to skip: " APPROVE_DEVICE_RESPONSE
if [[ "$APPROVE_DEVICE_RESPONSE" =~ ^[Ss]$ ]]; then
  echo "Skipping device approval."
  exit 0
fi

deadline=$((SECONDS + APPROVAL_POLL_SECONDS))
while [[ "$SECONDS" -le "$deadline" ]]; do
  echo "Polling for pending OpenClaw device requests..."
  devices_json="$(run_openclaw_cli devices list --json --url "ws://${OPENCLAW_UPSTREAM}" --token "$GATEWAY_TOKEN")"
  mapfile -t request_ids < <(list_pending_request_ids "$devices_json")

  if [[ "${#request_ids[@]}" -eq 1 ]]; then
    approve_request "${request_ids[0]}"
    echo "Device approved. Refresh ${OPENCLAW_URL}"
    exit 0
  fi

  if [[ "${#request_ids[@]}" -gt 1 ]]; then
    echo "Multiple pending requests were found:"
    echo "$devices_json" | jq .
    echo ""
    read -rp "Enter the request ID to approve, or type s to skip: " REQUEST_ID
    if [[ "$REQUEST_ID" =~ ^[Ss]$ || -z "$REQUEST_ID" ]]; then
      echo "Skipping device approval."
      exit 0
    fi
    approve_request "$REQUEST_ID"
    echo "Device approved. Refresh ${OPENCLAW_URL}"
    exit 0
  fi

  sleep "$APPROVAL_POLL_INTERVAL"
done

echo "No pending OpenClaw device request appeared within ${APPROVAL_POLL_SECONDS}s."
echo "Keep the browser on the pairing-required page and rerun:"
echo "  sudo bash scripts/approve-openclaw-device.sh"
