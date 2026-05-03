#!/usr/bin/env bash
set -euo pipefail

docker_compose_available() {
  docker compose version >/dev/null 2>&1
}

if command -v docker >/dev/null 2>&1 && docker_compose_available; then
  echo "Docker already installed"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    echo "== Enabling Docker =="
    systemctl enable --now docker
  fi
  echo "== Docker version =="
  docker --version
  docker compose version
  exit 0
fi

echo "== Installing Docker =="
curl -fsSL https://get.docker.com | sh

echo "== Enabling Docker =="
systemctl enable --now docker

echo "== Docker version =="
docker --version
docker compose version
