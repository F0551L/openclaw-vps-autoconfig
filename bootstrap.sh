#!/usr/bin/env bash
set -euo pipefail

START_STEP="base"
INSTALL_DOCKER=true
INSTALL_OPENCLAW=true
EXPOSE_OPENCLAW_ZT=true
CREATE_ADMIN_USER=true
ADMIN_USER="${ADMIN_USER:-ocadmin}"
LOCK_BOOTSTRAP_USER_ON_SUCCESS=false
ADMIN_USER_READY=false
ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"

usage() {
  cat <<EOF
Usage: sudo bash bootstrap.sh [options]

Options:
  --from STEP                 Start from STEP and continue onward.
                              Steps: base, admin-user, zerotier, docker, openclaw, proxy, reboot-check
  --admin-user USER           Admin sudo user to create. Default: ocadmin.
  --zerotier-network-id ID    ZeroTier network ID to join.
  --skip-admin-user           Skip admin user creation.
  --lock-bootstrap-user       Lock the original sudo user after admin user setup succeeds.
  --skip-docker               Skip Docker installation.
  --skip-openclaw             Skip OpenClaw installation.
  --skip-proxy                Skip ZeroTier reverse proxy setup.
  --with-docker               Deprecated; Docker is installed by default.
  -h, --help                  Show this help.

Environment:
  ZT_NETWORK_ID               ZeroTier network ID to join.
  ADMIN_USER                  Admin sudo user to create.
  ADMIN_SSH_PUBLIC_KEY        SSH public key to install for the admin user.
  ADMIN_SSH_PUBLIC_KEY_FILE   File containing an SSH public key to install.
  ADMIN_PASSWORD_PROMPT       Set true to prompt for an admin user password.
  ADMIN_PASSWORD_FILE         File containing the admin user password.
  LOCK_BOOTSTRAP_USER_ON_SUCCESS
                              Set true to lock the original sudo user after admin user setup.

Examples:
  sudo bash bootstrap.sh
  sudo bash bootstrap.sh --zerotier-network-id 0123456789abcdef
  sudo bash bootstrap.sh --admin-user albert
  sudo bash bootstrap.sh --from docker
  sudo bash bootstrap.sh --from proxy
EOF
}

step_number() {
  case "$1" in
    base|bootstrap) echo 1 ;;
    admin-user|admin|user) echo 2 ;;
    zerotier|zt) echo 3 ;;
    docker) echo 4 ;;
    openclaw) echo 5 ;;
    proxy|expose|zerotier-proxy) echo 6 ;;
    reboot-check|reboot) echo 7 ;;
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

  if [[ -f "$script_path" ]]; then
    bash "$script_path"
  else
    echo "Required script not found: $script_path"
    exit 1
  fi
}

lock_bootstrap_user() {
  local bootstrap_user="${SUDO_USER:-}"

  if [[ "$LOCK_BOOTSTRAP_USER_ON_SUCCESS" != "true" ]]; then
    return 0
  fi

  if ! $ADMIN_USER_READY; then
    echo "Admin user setup did not run successfully in this bootstrap session; skipping bootstrap user lock."
    return 0
  fi

  if [[ -z "$bootstrap_user" || "$bootstrap_user" == "root" || "$bootstrap_user" == "$ADMIN_USER" ]]; then
    echo "No separate bootstrap user to lock."
    return 0
  fi

  if ! id "$bootstrap_user" >/dev/null 2>&1; then
    echo "Bootstrap user not found, skipping lock: $bootstrap_user"
    return 0
  fi

  echo "== Locking bootstrap user =="
  passwd --lock "$bootstrap_user" >/dev/null
  echo "Locked password login for bootstrap user: $bootstrap_user"
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
    --admin-user)
      ADMIN_USER="${2:-}"
      if [[ -z "$ADMIN_USER" ]]; then
        echo "--admin-user requires a value."
        exit 1
      fi
      shift 2
      ;;
    --skip-admin-user|--no-admin-user)
      CREATE_ADMIN_USER=false
      shift
      ;;
    --lock-bootstrap-user|--lock-permissions-on-success)
      LOCK_BOOTSTRAP_USER_ON_SUCCESS=true
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

export ADMIN_USER
export LOCK_BOOTSTRAP_USER_ON_SUCCESS

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
    sudo \
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

if should_run admin-user; then
  if $CREATE_ADMIN_USER; then
    run_script "scripts/create-admin-user.sh"
    ADMIN_USER_READY=true
  else
    echo "Skipping admin user creation"
  fi
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

if should_run docker; then
  if $INSTALL_DOCKER; then
    run_script "scripts/install-docker.sh"
  else
    echo "Skipping Docker install"
  fi
fi

if should_run openclaw; then
  if $INSTALL_OPENCLAW; then
    run_script "scripts/install-openclaw.sh"
  else
    echo "Skipping OpenClaw install"
  fi
fi

if should_run proxy; then
  if $EXPOSE_OPENCLAW_ZT; then
    run_script "scripts/expose-openclaw-zerotier.sh"
  else
    echo "Skipping OpenClaw ZeroTier reverse proxy"
  fi
fi

if should_run reboot-check; then
  lock_bootstrap_user

  echo "== Checking reboot requirement =="
  if [[ -f /var/run/reboot-required ]]; then
    echo "Reboot required. Run: sudo reboot"
  else
    echo "No reboot required."
  fi
fi

echo "== Done =="
