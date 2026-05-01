#!/usr/bin/env bash
set -euo pipefail

START_STEP="base"
ASSUME_YES=false
INSTALL_DOCKER=true
INSTALL_OPENCLAW=true
EXPOSE_OPENCLAW_ZT=true
ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"

usage() {
  cat <<EOF
Usage: sudo bash bootstrap.sh [options]

Options:
  --from STEP                 Start from STEP and continue onward.
                              Steps: base, zerotier, docker, openclaw, proxy, reboot-check
  --zerotier-network-id ID    ZeroTier network ID to join.
  --yes                       Accept default answers for optional prompts.
  --skip-docker               Skip Docker installation.
  --skip-openclaw             Skip OpenClaw installation.
  --skip-proxy                Skip ZeroTier reverse proxy setup.
  --with-docker               Deprecated; Docker is installed by default.
  -h, --help                  Show this help.

Environment:
  ZT_NETWORK_ID               ZeroTier network ID to join.

Examples:
  sudo bash bootstrap.sh
  sudo bash bootstrap.sh --zerotier-network-id 0123456789abcdef --yes
  sudo bash bootstrap.sh --from docker
  sudo bash bootstrap.sh --from proxy
EOF
}

step_number() {
  case "$1" in
    base|bootstrap) echo 1 ;;
    zerotier|zt) echo 2 ;;
    docker) echo 3 ;;
    openclaw) echo 4 ;;
    proxy|expose|zerotier-proxy) echo 5 ;;
    reboot-check|reboot) echo 6 ;;
    *)
      echo "Unknown step: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
}

should_run() {
  local step="$1"
  [[ "$(step_number "$step")" -ge "$(step_number "$START_STEP")" ]]
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer

  if $ASSUME_YES; then
    return 0
  fi

  if [[ "$default" == "y" ]]; then
    read -rp "$prompt [Y/n]: " answer
    [[ ! "$answer" =~ ^[Nn]$ ]]
  else
    read -rp "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

require_zerotier_network_id() {
  while [[ -z "$ZT_NETWORK_ID" ]]; do
    read -rp "Enter ZeroTier Network ID: " ZT_NETWORK_ID
  done

  if [[ ! "$ZT_NETWORK_ID" =~ ^[0-9a-fA-F]{16}$ ]]; then
    echo "Invalid ZeroTier Network ID format: $ZT_NETWORK_ID"
    echo "Expected a 16-character hexadecimal network ID."
    exit 1
  fi
}

run_script() {
  local script_path="$1"
  local label="$2"

  if [[ -f "$script_path" ]]; then
    echo "== $label =="
    bash "$script_path"
  else
    echo "Required script not found: $script_path"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      START_STEP="${2:-}"
      if [[ -z "$START_STEP" ]]; then
        echo "--from requires a step name."
        exit 1
      fi
      step_number "$START_STEP" >/dev/null
      shift 2
      ;;
    --zerotier-network-id)
      ZT_NETWORK_ID="${2:-}"
      if [[ -z "$ZT_NETWORK_ID" ]]; then
        echo "--zerotier-network-id requires a value."
        exit 1
      fi
      shift 2
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --skip-docker|--no-docker)
      INSTALL_DOCKER=false
      shift
      ;;
    --skip-openclaw|--no-openclaw)
      INSTALL_OPENCLAW=false
      shift
      ;;
    --skip-proxy|--no-proxy)
      EXPOSE_OPENCLAW_ZT=false
      shift
      ;;
    --with-docker)
      INSTALL_DOCKER=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash bootstrap.sh"
  exit 1
fi

echo "== Bootstrap start =="
echo "Starting from step: $START_STEP"

if should_run base; then
  echo "== Updating system =="
  apt update
  apt upgrade -y

  echo "== Installing base packages =="
  apt install -y \
    curl \
    git \
    ufw \
    fail2ban \
    ca-certificates \
    gnupg \
    lsb-release \
    unattended-upgrades

  echo "== Allowing SSH and ZeroTier through UFW =="
  ufw allow 22/tcp
  ufw allow 9993/udp
  #ufw allow 9993/tcp     # disabled for now
  ufw --force enable
fi

if should_run zerotier; then
  echo "== Installing ZeroTier =="
  if command -v zerotier-cli >/dev/null 2>&1; then
    echo "ZeroTier already installed"
  else
    curl -s https://install.zerotier.com | bash
  fi

  echo "== Enabling ZeroTier service =="
  systemctl enable --now zerotier-one

  if systemctl list-unit-files fail2ban.service >/dev/null 2>&1; then
    systemctl enable --now fail2ban
  else
    echo "fail2ban service not found; skipping service enable."
  fi

  until zerotier-cli info >/dev/null 2>&1; do
    echo "Waiting for ZeroTier service..."
    sleep 1
  done

  echo "ZeroTier node ID:"
  zerotier-cli info

  require_zerotier_network_id

  if zerotier-cli listnetworks 2>/dev/null | awk '{ print $3 }' | grep -qi "^${ZT_NETWORK_ID}$"; then
    echo "Already joined ZeroTier network: $ZT_NETWORK_ID"
  else
    echo "Joining ZeroTier network: $ZT_NETWORK_ID"
    zerotier-cli join "$ZT_NETWORK_ID"
  fi
fi

if should_run docker && $INSTALL_DOCKER; then
  if prompt_yes_no "Install Docker now?" "y"; then
    run_script "scripts/install-docker.sh" "Installing Docker"
  else
    echo "Skipping Docker install"
  fi
fi

if should_run openclaw && $INSTALL_OPENCLAW; then
  if prompt_yes_no "Install OpenClaw now?" "y"; then
    run_script "scripts/install-openclaw.sh" "Installing OpenClaw"
  else
    echo "Skipping OpenClaw install"
  fi
fi

if should_run proxy && $EXPOSE_OPENCLAW_ZT; then
  if prompt_yes_no "Expose OpenClaw on ZeroTier with a reverse proxy now?" "y"; then
    run_script "scripts/expose-openclaw-zerotier.sh" "Configuring OpenClaw ZeroTier reverse proxy"
  else
    echo "Skipping OpenClaw ZeroTier reverse proxy"
  fi
fi

if should_run reboot-check; then
  echo "== Checking reboot requirement =="
  if [[ -f /var/run/reboot-required ]]; then
    echo "Reboot required. Run: sudo reboot"
  else
    echo "No reboot required."
  fi
fi

echo "== Done =="
