#!/usr/bin/env bash
set -euo pipefail

FORCE=false
RESET_STEP=""
OLD_ZT_IP="${OLD_ZT_IP:-}"
NEW_ZT_IP="${NEW_ZT_IP:-}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-/opt/openclaw/config/openclaw.json}"

usage() {
  cat <<USAGE
Usage: sudo bash scripts/reset-reinstall.sh --reset STEP [--force]

Reset/reinstall planner for a single setup step with cascade handling.

Options:
  -r, --reset STEP   Step to reset (same names as clawtier.sh --from step names):
                     b/base, au/admin-user, zt/zerotier, d/docker,
                     oc/openclaw, p/proxy, ad/approve-device, rc/reboot-check.
  -f, --force        Non-interactive mode; do not prompt before applying reset actions.
  -h, --help         Show this help.

Examples:
  sudo bash scripts/reset-reinstall.sh -r zt
  sudo bash scripts/reset-reinstall.sh --reset proxy
  sudo bash scripts/reset-reinstall.sh -r openclaw --force
USAGE
}

normalize_step() {
  case "$1" in
    b|base|bootstrap) echo "base" ;;
    au|admin-user|admin|user) echo "admin-user" ;;
    zt|zerotier) echo "zerotier" ;;
    d|docker) echo "docker" ;;
    oc|openclaw) echo "openclaw" ;;
    p|proxy|expose|zerotier-proxy) echo "proxy" ;;
    ad|approve-device|approve|device|pairing) echo "approve-device" ;;
    rc|reboot-check|reboot) echo "reboot-check" ;;
    *)
      echo "Unknown step: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
}

confirm_or_exit() {
  local prompt="$1"
  local answer

  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi

  while true; do
    read -rp "${prompt} [y/n]: " answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)
        echo "Aborted."
        exit 0
        ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

# Ordered from earliest to latest to support dependency cascades.
ALL_STEPS=(
  "base"
  "admin-user"
  "zerotier"
  "docker"
  "openclaw"
  "proxy"
  "approve-device"
  "reboot-check"
)

index_of_step() {
  local step="$1" i
  for i in "${!ALL_STEPS[@]}"; do
    if [[ "${ALL_STEPS[$i]}" == "$step" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

steps_from() {
  local step="$1"
  local start_idx
  start_idx="$(index_of_step "$step")"

  local i
  for ((i=start_idx; i<${#ALL_STEPS[@]}; i++)); do
    echo "${ALL_STEPS[$i]}"
  done
}

reset_zerotier_specific() {
  echo "- ZeroTier reset hook: leave joined networks and stop service (placeholder)."
  echo "  Implement with care: zerotier-cli listnetworks + zerotier-cli leave + package/service reinstall."
}

cleanup_openclaw_allowed_origin_for_old_zt_ip() {
  if [[ -z "$OLD_ZT_IP" || -z "$NEW_ZT_IP" || "$OLD_ZT_IP" == "$NEW_ZT_IP" ]]; then
    return 0
  fi

  if [[ ! -f "$OPENCLAW_CONFIG_FILE" ]]; then
    echo "- OpenClaw config not found at $OPENCLAW_CONFIG_FILE; skipping old ZeroTier IP cleanup."
    return 0
  fi

  echo "- ZeroTier network/IP changed (${OLD_ZT_IP} -> ${NEW_ZT_IP}); remove old allowed host from OpenClaw config."
  if command -v jq >/dev/null 2>&1; then
    tmp_file="$(mktemp)"
    jq --arg old_http "http://${OLD_ZT_IP}" --arg old_https "https://${OLD_ZT_IP}" '
      .gateway.controlUi.allowedOrigins |= map(select(. != $old_http and . != $old_https))
    ' "$OPENCLAW_CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$OPENCLAW_CONFIG_FILE"
  else
    echo "  jq not found; install jq or manually remove old origins from allowedOrigins."
  fi
}

reset_step_hook() {
  local step="$1"
  case "$step" in
    zerotier)
      reset_zerotier_specific
      ;;
    openclaw|proxy)
      cleanup_openclaw_allowed_origin_for_old_zt_ip
      ;;
    *)
      echo "- ${step} reset hook: no custom behavior yet."
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--reset)
      RESET_STEP="${2:-}"
      shift 2
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$RESET_STEP" ]]; then
  echo "Missing required option: --reset STEP" >&2
  usage >&2
  exit 1
fi

RESET_STEP="$(normalize_step "$RESET_STEP")"
mapfile -t CASCADE_STEPS < <(steps_from "$RESET_STEP")

echo "Reset step requested: $RESET_STEP"
echo "Affected steps (reinstall/update required):"
printf '  - %s\n' "${CASCADE_STEPS[@]}"

confirm_or_exit "Proceed with reset planning and hooks?"

echo "== Applying reset hooks =="
for step in "${CASCADE_STEPS[@]}"; do
  reset_step_hook "$step"
done

echo ""
echo "Reset planning complete."
echo "Next: rerun clawtier bootstrap from the selected step, for example:"
echo "  sudo bash clawtier.sh -f ${RESET_STEP}"
