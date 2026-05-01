#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-/opt/openclaw}"
OPENCLAW_REPO="${OPENCLAW_REPO:-https://github.com/openclaw/openclaw.git}"
OPENCLAW_LATEST_RELEASE_URL="${OPENCLAW_LATEST_RELEASE_URL:-https://github.com/openclaw/openclaw/releases/latest}"
OPENCLAW_REF="${OPENCLAW_REF:-}"

echo "== Installing OpenClaw via official Docker setup =="

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/install-docker.sh first."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is not installed. Run bootstrap.sh first."
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
./scripts/docker/setup.sh

echo ""
echo "== OpenClaw setup complete =="
echo "Dashboard should be available from the VPS itself at:"
echo "  http://127.0.0.1:18789/"
echo ""
echo "For remote access, prefer ZeroTier or a locked-down reverse proxy."
