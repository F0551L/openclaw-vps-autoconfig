#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_REPO="${OPENCLAW_REPO:-https://github.com/openclaw/openclaw.git}"
OPENCLAW_LATEST_RELEASE_URL="${OPENCLAW_LATEST_RELEASE_URL:-https://github.com/openclaw/openclaw/releases/latest}"
OPENCLAW_REF="${OPENCLAW_REF:-}"
OPENCLAW_SETUP_USE_DEFAULTS="${OPENCLAW_SETUP_USE_DEFAULTS:-false}"
OPENCLAW_SKIP_ONBOARDING="${OPENCLAW_SKIP_ONBOARDING:-}"

echo "== Installing OpenClaw via official Docker setup =="

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/install-docker.sh first."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is not installed. Run clawtier.sh first."
  exit 1
fi

resolve_openclaw_ref() {
  local latest_url latest_ref

  if [[ -n "$OPENCLAW_REF" ]]; then
    echo "$OPENCLAW_REF"
    return 0
  fi

  latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$OPENCLAW_LATEST_RELEASE_URL")"
  latest_ref="${latest_url##*/}"

  if [[ -z "$latest_ref" || "$latest_ref" == "latest" ]]; then
    echo "Unable to resolve latest OpenClaw release from $OPENCLAW_LATEST_RELEASE_URL" >&2
    exit 1
  fi

  echo "$latest_ref"
}

prepare_openclaw_defaults() {
  local setup_script="scripts/docker/setup.sh"
  local marker="OPENCLAW_SKIP_ONBOARDING"

  if [[ ! -f "$setup_script" ]]; then
    echo "OpenClaw Docker setup script not found: $setup_script"
    exit 1
  fi

  export OPENCLAW_SKIP_ONBOARDING="${OPENCLAW_SKIP_ONBOARDING:-1}"

  if grep -q "$marker" "$setup_script"; then
    echo "OpenClaw Docker setup supports OPENCLAW_SKIP_ONBOARDING."
    return 0
  fi

  if ! grep -q 'run_prestart_cli onboard --mode local --no-install-daemon' "$setup_script"; then
    echo "OpenClaw Docker setup does not support non-interactive defaults for this ref."
    echo "Expected onboarding command was not found in $setup_script."
    exit 1
  fi

  echo "Patching OpenClaw Docker setup to honor OPENCLAW_SKIP_ONBOARDING for this ref."
  sed -i \
    's/run_prestart_cli onboard --mode local --no-install-daemon/if [[ -n "${OPENCLAW_SKIP_ONBOARDING:-}" ]]; then\n  echo "==> Skipping onboarding (OPENCLAW_SKIP_ONBOARDING is set)"\nelse\n  run_prestart_cli onboard --mode local --no-install-daemon\nfi/' \
    "$setup_script"
}

OPENCLAW_RESOLVED_REF="$(resolve_openclaw_ref)"

if [[ ! -d "$OPENCLAW_DIR/.git" ]]; then
  git clone "$OPENCLAW_REPO" "$OPENCLAW_DIR"
else
  git -C "$OPENCLAW_DIR" remote set-url origin "$OPENCLAW_REPO"
  git -C "$OPENCLAW_DIR" fetch --tags --prune origin
fi

echo "== Checking out OpenClaw ref: $OPENCLAW_RESOLVED_REF =="
git -C "$OPENCLAW_DIR" checkout --force "$OPENCLAW_RESOLVED_REF"

cd "$OPENCLAW_DIR"

echo "== Running OpenClaw Docker setup =="
if [[ "$OPENCLAW_SETUP_USE_DEFAULTS" == "true" ]]; then
  echo "Using opinionated OpenClaw defaults: skip interactive onboarding."
  prepare_openclaw_defaults
  ./scripts/docker/setup.sh
else
  ./scripts/docker/setup.sh
fi

echo ""
echo "== OpenClaw setup complete =="
echo "Dashboard should be available from the VPS itself at:"
echo "  http://127.0.0.1:18789/"
echo ""
echo "For remote access, prefer ZeroTier or a locked-down reverse proxy."
