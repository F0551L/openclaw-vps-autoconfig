#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash bootstrap.sh"
  exit 1
fi

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

echo "== Installing ZeroTier =="
curl -s https://install.zerotier.com | bash

echo "== Enabling services =="
systemctl enable --now zerotier-one
systemctl enable --now fail2ban

until zerotier-cli info >/dev/null 2>&1; do
  echo "Waiting for ZeroTier service..."
  sleep 1
done

echo "ZeroTier node ID:"
zerotier-cli info

read -rp "Enter ZeroTier Network ID (leave blank to skip): " ZT_NETWORK_ID

if [[ -n "$ZT_NETWORK_ID" ]]; then
  if [[ "$ZT_NETWORK_ID" =~ ^[0-9a-fA-F]{16}$ ]]; then
    echo "Joining ZeroTier network..."
    zerotier-cli join "$ZT_NETWORK_ID"
  else
    echo "Invalid Network ID format. Skipping join."
  fi
else
  echo "Skipping ZeroTier join."
fi

echo ""
INSTALL_DOCKER_FLAG=false

if [[ "${1:-}" == "--with-docker" ]]; then
  INSTALL_DOCKER_FLAG=true
fi

if $INSTALL_DOCKER_FLAG; then
  RUN_DOCKER="y"
else
  read -rp "Install Docker now? [y/N]: " RUN_DOCKER
fi

if [[ "$RUN_DOCKER" =~ ^[Yy]$ ]]; then
  if [[ -f scripts/install-docker.sh ]]; then
    echo "== Installing Docker =="
    bash scripts/install-docker.sh
  else
    echo "Docker install script not found: scripts/install-docker.sh"
  fi
fi

echo ""
read -rp "Install OpenClaw now? [y/N]: " INSTALL_OPENCLAW

if [[ "$INSTALL_OPENCLAW" =~ ^[Yy]$ ]]; then
  if [[ -f scripts/install-openclaw.sh ]]; then
    echo "== Installing OpenClaw =="
    bash scripts/install-openclaw.sh
  else
    echo "OpenClaw install script not found: scripts/install-openclaw.sh"
  fi
else
  echo "Skipping OpenClaw install"
fi

echo ""
read -rp "Expose OpenClaw on ZeroTier with a reverse proxy now? [y/N]: " EXPOSE_OPENCLAW_ZT

if [[ "$EXPOSE_OPENCLAW_ZT" =~ ^[Yy]$ ]]; then
  if [[ -f scripts/expose-openclaw-zerotier.sh ]]; then
    echo "== Configuring OpenClaw ZeroTier reverse proxy =="
    bash scripts/expose-openclaw-zerotier.sh
  else
    echo "ZeroTier reverse proxy script not found: scripts/expose-openclaw-zerotier.sh"
  fi
else
  echo "Skipping OpenClaw ZeroTier reverse proxy"
fi

echo "== Checking reboot requirement =="
if [[ -f /var/run/reboot-required ]]; then
  echo "Reboot required. Run: sudo reboot"
else
  echo "No reboot required."
fi

echo "== Done =="
