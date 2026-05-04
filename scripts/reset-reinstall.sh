#!/usr/bin/env bash
set -euo pipefail

FORCE=false
RESET_STEP=""
ADMIN_USER="${ADMIN_USER:-ocadmin}"
OLD_ZT_IP="${OLD_ZT_IP:-}"
NEW_ZT_IP="${NEW_ZT_IP:-}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-${OPENCLAW_DIR}/config/openclaw.json}"
PROXY_NAME="${PROXY_NAME:-openclaw-zerotier-proxy}"
PROXY_DIR="${PROXY_DIR:-/opt/${PROXY_NAME}}"
PROXY_SERVICE_FILE="${PROXY_SERVICE_FILE:-/etc/systemd/system/${PROXY_NAME}.service}"
RESET_MODE="step"
NEXT_BOOTSTRAP_STEP=""

usage() {
  cat <<USAGE
Usage: sudo bash scripts/reset-reinstall.sh --reset STEP [--force]

Reset/reinstall planner and cleanup runner.

Options:
  -r, --reset STEP   Step or reset mode to reset:
                     b/base, zt/zerotier, au/admin-user, d/docker,
                     oc/openclaw, p/proxy, ad/approve-device, rc/reboot-check,
                     data/clawtier-data, full/all.
  -f, --force        Non-interactive mode; do not prompt before applying reset actions.
  -h, --help         Show this help.

Reset modes:
  data               Remove ClawTier-managed application state and folders but keep
                     installed Docker and ZeroTier packages.
  full               Remove ClawTier-managed application state, Docker packages/data,
                     ZeroTier packages/state, and the managed admin user when safe.

Examples:
  sudo bash scripts/reset-reinstall.sh -r zt
  sudo bash scripts/reset-reinstall.sh --reset data
  sudo bash scripts/reset-reinstall.sh --reset full --force
USAGE
}

normalize_step() {
  case "$1" in
    b|base|bootstrap) echo "base" ;;
    zt|zerotier) echo "zerotier" ;;
    au|admin-user|admin|user) echo "admin-user" ;;
    d|docker) echo "docker" ;;
    oc|openclaw) echo "openclaw" ;;
    p|proxy|expose|zerotier-proxy) echo "proxy" ;;
    ad|approve-device|approve|device|pairing) echo "approve-device" ;;
    rc|reboot-check|reboot) echo "reboot-check" ;;
    data|clawtier-data|wipe-data|delete-data|app-data) echo "data" ;;
    full|all|scratch|from-scratch|full-reset) echo "full" ;;
    *)
      echo "Unknown reset target: $1" >&2
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

remove_path() {
  local path="$1"

  if [[ -e "$path" || -L "$path" ]]; then
    echo "- Removing $path"
    rm -rf --one-file-system "$path"
  else
    echo "- Not found, skipping $path"
  fi
}

disable_service_if_present() {
  local service="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  if systemctl list-unit-files "$service" >/dev/null 2>&1 || systemctl status "$service" >/dev/null 2>&1; then
    echo "- Disabling service: $service"
    systemctl disable --now "$service" >/dev/null 2>&1 || true
  fi
}

reload_systemd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
}

stop_openclaw_proxy() {
  echo "- Stopping OpenClaw ZeroTier proxy"
  disable_service_if_present "${PROXY_NAME}.service"

  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  fi

  remove_path "$PROXY_SERVICE_FILE"
  remove_path "$PROXY_DIR"
  reload_systemd
}

stop_openclaw_stack() {
  echo "- Stopping OpenClaw stack"

  if [[ -d "$OPENCLAW_DIR" && -f "$OPENCLAW_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
    (
      cd "$OPENCLAW_DIR"
      docker compose down --remove-orphans --volumes || true
    )
  fi

  if command -v docker >/dev/null 2>&1; then
    mapfile -t openclaw_containers < <(docker ps --all --format '{{.Names}}' 2>/dev/null | grep -E '(^|[-_])openclaw([-_]|$)' || true)
    if [[ "${#openclaw_containers[@]}" -gt 0 ]]; then
      docker rm -f "${openclaw_containers[@]}" >/dev/null 2>&1 || true
    fi

    mapfile -t openclaw_volumes < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '(^|[-_])openclaw([-_]|$)' || true)
    if [[ "${#openclaw_volumes[@]}" -gt 0 ]]; then
      docker volume rm "${openclaw_volumes[@]}" >/dev/null 2>&1 || true
    fi
  fi
}

remove_openclaw() {
  stop_openclaw_proxy
  stop_openclaw_stack
  remove_path "$OPENCLAW_DIR"
}

leave_zerotier_networks() {
  local networks network_id

  if ! command -v zerotier-cli >/dev/null 2>&1; then
    return 0
  fi

  networks="$(zerotier-cli listnetworks 2>/dev/null || true)"
  if [[ -z "$networks" ]]; then
    return 0
  fi

  while read -r network_id; do
    if [[ -n "$network_id" ]]; then
      echo "- Leaving ZeroTier network: $network_id"
      zerotier-cli leave "$network_id" >/dev/null 2>&1 || true
    fi
  done < <(awk '/^200 listnetworks/ { print $3 }' <<<"$networks")
}

remove_zerotier_state() {
  leave_zerotier_networks
  disable_service_if_present zerotier-one.service
  remove_path /var/lib/zerotier-one
  remove_path /etc/zerotier-one
}

purge_zerotier_package() {
  remove_zerotier_state

  if command -v apt-get >/dev/null 2>&1; then
    echo "- Purging ZeroTier package"
    apt-get purge -y zerotier-one || true
    apt-get autoremove -y || true
  else
    echo "- apt-get not found; skipped ZeroTier package purge."
  fi
}

purge_docker() {
  echo "- Removing Docker containers, volumes, and packages"
  if command -v docker >/dev/null 2>&1; then
    mapfile -t all_containers < <(docker ps --all --quiet 2>/dev/null || true)
    if [[ "${#all_containers[@]}" -gt 0 ]]; then
      docker rm -f "${all_containers[@]}" >/dev/null 2>&1 || true
    fi

    mapfile -t all_volumes < <(docker volume ls --quiet 2>/dev/null || true)
    if [[ "${#all_volumes[@]}" -gt 0 ]]; then
      docker volume rm "${all_volumes[@]}" >/dev/null 2>&1 || true
    fi
  fi

  disable_service_if_present docker.service
  disable_service_if_present containerd.service

  if command -v apt-get >/dev/null 2>&1; then
    apt-get purge -y \
      docker-ce \
      docker-ce-cli \
      docker-ce-rootless-extras \
      docker-buildx-plugin \
      docker-compose-plugin \
      docker.io \
      docker-compose \
      podman-docker \
      containerd \
      containerd.io \
      runc || true
    apt-get autoremove -y || true
  else
    echo "- apt-get not found; skipped Docker package purge."
  fi

  remove_path /var/lib/docker
  remove_path /var/lib/containerd
  remove_path /etc/docker
}

delete_managed_admin_user() {
  local invoking_user="${SUDO_USER:-}"
  local current_user

  current_user="$(id -un)"

  if [[ -z "$ADMIN_USER" ]]; then
    echo "- ADMIN_USER is empty; skipping admin user deletion."
    return 0
  fi

  if [[ "$EUID" -ne 0 ]]; then
    echo "- Not running as root; skipping admin user deletion."
    return 0
  fi

  if [[ "$current_user" == "$ADMIN_USER" || "$invoking_user" == "$ADMIN_USER" ]]; then
    echo "- Skipping admin user deletion because it is the current/invoking user: $ADMIN_USER"
    return 0
  fi

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    echo "- Admin user not found, skipping deletion: $ADMIN_USER"
    remove_path "/etc/sudoers.d/${ADMIN_USER}"
    return 0
  fi

  echo "- Deleting managed admin user: $ADMIN_USER"
  pkill -u "$ADMIN_USER" >/dev/null 2>&1 || true
  if command -v deluser >/dev/null 2>&1; then
    deluser --remove-home "$ADMIN_USER" || true
  else
    userdel -r "$ADMIN_USER" || true
  fi
  remove_path "/etc/sudoers.d/${ADMIN_USER}"
}

cleanup_openclaw_allowed_origin_for_old_zt_ip() {
  local tmp_file

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

# Ordered from earliest to latest to support dependency cascades.
ALL_STEPS=(
  "base"
  "zerotier"
  "admin-user"
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

reset_step_hook() {
  local step="$1"
  case "$step" in
    base)
      echo "- Base reset: keeping OS packages and firewall baseline in place."
      ;;
    zerotier)
      remove_zerotier_state
      ;;
    admin-user)
      delete_managed_admin_user
      ;;
    docker)
      purge_docker
      ;;
    openclaw)
      remove_openclaw
      ;;
    proxy)
      stop_openclaw_proxy
      cleanup_openclaw_allowed_origin_for_old_zt_ip
      ;;
    approve-device|reboot-check)
      echo "- ${step} reset: no persistent ClawTier state to remove."
      ;;
  esac
}

reset_data_mode() {
  remove_openclaw
  remove_zerotier_state
}

reset_full_mode() {
  remove_openclaw
  purge_docker
  purge_zerotier_package
  delete_managed_admin_user
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

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash scripts/reset-reinstall.sh"
  exit 1
fi

RESET_STEP="$(normalize_step "$RESET_STEP")"
case "$RESET_STEP" in
  data)
    RESET_MODE="data"
    NEXT_BOOTSTRAP_STEP="zerotier"
    ;;
  full)
    RESET_MODE="full"
    NEXT_BOOTSTRAP_STEP="base"
    ;;
  *)
    RESET_MODE="step"
    NEXT_BOOTSTRAP_STEP="$RESET_STEP"
    mapfile -t CASCADE_STEPS < <(steps_from "$RESET_STEP")
    ;;
esac

echo "Reset requested: $RESET_STEP"
echo "Admin user: ${ADMIN_USER}"

case "$RESET_MODE" in
  data)
    echo "Actions:"
    echo "  - Remove OpenClaw stack, proxy service, and managed folders."
    echo "  - Leave ZeroTier networks and remove local ZeroTier identity/state."
    echo "  - Keep Docker and ZeroTier packages installed."
    ;;
  full)
    echo "Actions:"
    echo "  - Remove OpenClaw stack, proxy service, and managed folders."
    echo "  - Purge Docker packages and Docker/containerd data."
    echo "  - Purge ZeroTier package and local ZeroTier identity/state."
    echo "  - Delete the managed admin user when it is not the invoking user."
    ;;
  step)
    echo "Affected steps (reinstall/update required):"
    printf '  - %s\n' "${CASCADE_STEPS[@]}"
    ;;
esac

confirm_or_exit "Proceed with reset cleanup?"

echo "== Applying reset cleanup =="
case "$RESET_MODE" in
  data) reset_data_mode ;;
  full) reset_full_mode ;;
  step)
    for step in "${CASCADE_STEPS[@]}"; do
      reset_step_hook "$step"
    done
    ;;
esac

echo ""
echo "Reset cleanup complete."
echo "Next: rerun clawtier bootstrap from the selected step, for example:"
if [[ "$NEXT_BOOTSTRAP_STEP" == "openclaw" ]]; then
  echo "  sudo OPENCLAW_FORCE_INSTALL=true bash clawtier.sh -f ${NEXT_BOOTSTRAP_STEP}"
else
  echo "  sudo bash clawtier.sh -f ${NEXT_BOOTSTRAP_STEP}"
fi
