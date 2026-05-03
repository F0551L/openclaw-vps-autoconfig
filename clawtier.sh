#!/usr/bin/env bash
set -euo pipefail

START_STEP="base"
INSTALL_DOCKER=true
INSTALL_OPENCLAW=true
EXPOSE_OPENCLAW_ZT=true
APPROVE_OPENCLAW_DEVICE=true
CREATE_ADMIN_USER=true
ADMIN_USER="${ADMIN_USER:-ocadmin}"
OPENCLAW_DEFAULTS=false
LOCK_BOOTSTRAP_USER_ON_SUCCESS=false
ADMIN_USER_READY=false
ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"
NONINTERACTIVE="${NONINTERACTIVE:-false}"
WAIT_ZT_ADDRESS="${WAIT_ZT_ADDRESS:-true}"
ZT_ADDRESS_TIMEOUT="${ZT_ADDRESS_TIMEOUT:-}"
ZT_DETECT_INTERVAL="${ZT_DETECT_INTERVAL:-10}"
DEFAULT_UPDATE_SOURCE="https://github.com/F0551L/ClawTier.git"
UPDATE_SCRIPTS=false
UPDATE_SCRIPTS_ONLY=false
UPDATE_COMPONENTS=""
UPDATE_SOURCE="${UPDATE_SOURCE:-}"
UPDATE_REF="${UPDATE_REF:-}"
ENV_FILE="${ENV_FILE:-}"
PASSTHROUGH_ARGS=()

usage() {
  cat <<EOF
Usage: sudo bash clawtier.sh [options]

Options:
  -n, --zerotier-network-id ID
                              ZeroTier network ID to join.
  -u, -us, --update-scripts   Update this bootstrap checkout before continuing.
  -uso, --update-scripts-only Update this bootstrap checkout, then exit.
  -uc, --update-components LIST
                              Update installed components (all, c/caddy, oc/openclaw, zt/zerotier).
                              Use comma-delimited values, e.g. oc,zt.
  -s, -source, --update-source URL
                              Override Git source for script updates.
  -r, -ref, --update-ref REF  Override Git ref for script updates. Default: current branch.
  --env-file FILE             Load bootstrap environment values from FILE.
  -y, --non-interactive       Never prompt; fail or skip when input is missing.
  --wait-zt-address           Wait for ZeroTier address assignment before proxy setup. Default.
  --no-wait-zt-address        Skip proxy setup if no ZeroTier address is assigned yet.
  --zt-address-timeout SECONDS
                              Maximum time to wait for ZeroTier address assignment.
  --zt-detect-interval SECONDS
                              Seconds between ZeroTier address detection attempts. Default: 10.
  -f, --from STEP             Start from STEP and continue onward.
                              Steps: b/base, au/admin-user, zt/zerotier, d/docker,
                                     oc/openclaw, p/proxy, ad/approve-device,
                                     rc/reboot-check.
  -au, --admin-user USER      Admin sudo user to create. Default: ocadmin.
  -sau, --skip-admin-user     Skip admin user creation.
  -lbu, --lock-bootstrap-user Lock the original sudo user after admin user setup succeeds.
  -sd, --skip-docker          Skip Docker installation.
  -soc, --skip-openclaw       Skip OpenClaw installation.
  -ocd, -ud, --openclaw-defaults, --use-defaults
                              Run OpenClaw setup with opinionated local defaults.
  -sp, --skip-proxy           Skip ZeroTier reverse proxy setup.
  -sad, --skip-approve-device Skip interactive OpenClaw device approval.
  -h, --help                  Show this help.

Environment:
  ZT_NETWORK_ID               ZeroTier network ID to join.
  NONINTERACTIVE              Set true to disable prompts.
  WAIT_ZT_ADDRESS             Set false to skip proxy setup when no ZeroTier address is assigned.
  ZT_ADDRESS_TIMEOUT          Maximum time to wait for ZeroTier address assignment.
  ZT_DETECT_INTERVAL          Seconds between ZeroTier address detection attempts.
  ENV_FILE                    Environment file to load before setup.
  UPDATE_SOURCE               Git URL/path to fetch when updating scripts.
  UPDATE_REF                  Git ref to fetch when updating scripts.
  ADMIN_USER                  Admin sudo user to create.
  ADMIN_SSH_PUBLIC_KEY        SSH public key to install for the admin user.
  ADMIN_SSH_PUBLIC_KEY_FILE   File containing an SSH public key to install.
  ADMIN_PASSWORD_PROMPT       Set true to prompt for an admin user password.
  ADMIN_PASSWORD_FILE         File containing the admin user password.
  LOCK_BOOTSTRAP_USER_ON_SUCCESS
                              Set true to lock the original sudo user after admin user setup.

Examples:
  sudo bash clawtier.sh -u -n 0123456789abcdef
  sudo bash clawtier.sh -y -n 0123456789abcdef -ocd -sad
  sudo bash clawtier.sh -n 0123456789abcdef -au openclaw
  sudo bash clawtier.sh -n 0123456789abcdef -f d
  sudo bash clawtier.sh -n 0123456789abcdef -f p
  sudo bash clawtier.sh -n 0123456789abcdef -ocd -sad
  sudo bash clawtier.sh -f ad
  sudo bash clawtier.sh -uc all
  sudo bash clawtier.sh -uc c,oc,zt
EOF
}

step_number() {
  case "$1" in
    b|base|bootstrap) echo 1 ;;
    au|admin-user|admin|user) echo 2 ;;
    zt|zerotier) echo 3 ;;
    d|docker) echo 4 ;;
    oc|openclaw) echo 5 ;;
    p|proxy|expose|zerotier-proxy) echo 6 ;;
    ad|approve-device|approve|device|pairing) echo 7 ;;
    rc|reboot-check|reboot) echo 8 ;;
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

is_true() {
  [[ "${1:-}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy])$ ]]
}

load_env_file() {
  local env_file="$1"
  local perms

  if [[ -z "$env_file" ]]; then
    return 0
  fi

  if [[ ! -f "$env_file" ]]; then
    echo "Environment file not found: $env_file"
    exit 1
  fi

  if [[ "$(stat -c "%u" "$env_file")" != "0" ]]; then
    echo "Environment file must be owned by root: $env_file"
    exit 1
  fi

  perms="$(stat -c "%A" "$env_file")"
  if [[ "${perms:5:1}" == "w" || "${perms:8:1}" == "w" ]]; then
    echo "Environment file must not be writable by group or other users: $env_file"
    echo "Run: sudo chmod 600 $env_file"
    exit 1
  fi

  echo "== Loading environment file =="
  echo "Env file: $env_file"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

require_zerotier_network_id() {
  while [[ -z "$ZT_NETWORK_ID" ]]; do
    if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
      echo "ZeroTier network ID is required. Pass it with -n ID."
      exit 1
    fi

    read -rp "Enter ZeroTier Network ID: " ZT_NETWORK_ID
  done

  if [[ ! "$ZT_NETWORK_ID" =~ ^[0-9a-fA-F]{16}$ ]]; then
    echo "Invalid ZeroTier Network ID format: $ZT_NETWORK_ID"
    echo "Expected a 16-character hexadecimal network ID."
    exit 1
  fi
}

ensure_zerotier_installed() {
  echo "== Installing ZeroTier =="
  if command -v zerotier-cli >/dev/null 2>&1; then
    echo "ZeroTier already installed"
  else
    curl -s https://install.zerotier.com | bash
  fi
}

ensure_zerotier_service() {
  echo "== Enabling ZeroTier service =="
  systemctl enable --now zerotier-one

  until zerotier-cli info >/dev/null 2>&1; do
    echo "Waiting for ZeroTier service..."
    sleep 1
  done
}

show_zerotier_node() {
  echo "ZeroTier node ID:"
  zerotier-cli info
}

show_zerotier_networks() {
  local networks network_summary

  networks="$(zerotier-cli listnetworks 2>/dev/null || true)"
  if [[ -z "$networks" ]]; then
    echo "No joined ZeroTier networks found."
    return 0
  fi

  echo "Joined ZeroTier networks:"
  network_summary="$(awk '/^200 listnetworks/ { printf "  Network ID: %s", $3; if ($4 != "") printf "  Name: %s", $4; if ($6 != "") printf "  Status: %s", $6; if ($8 != "") printf "  Interface: %s", $8; if ($9 != "") printf "  Addresses: %s", $9; print "" }' <<<"$networks")"
  if [[ -n "$network_summary" ]]; then
    echo "$network_summary"
  else
    echo "$networks"
  fi
}

zerotier_has_connected_network() {
  command -v zerotier-cli >/dev/null 2>&1 || return 1
  zerotier-cli listnetworks 2>/dev/null | awk '/^200 listnetworks/ && $6 == "OK" { found = 1 } END { exit found ? 0 : 1 }'
}

join_zerotier_network() {
  require_zerotier_network_id

  if zerotier-cli listnetworks 2>/dev/null | awk '{ print $3 }' | grep -qi "^${ZT_NETWORK_ID}$"; then
    echo "Already joined ZeroTier network: $ZT_NETWORK_ID"
  else
    echo "Joining ZeroTier network: $ZT_NETWORK_ID"
    zerotier-cli join "$ZT_NETWORK_ID"
  fi
}

ensure_zerotier_connected_for_resume() {
  if ! { [[ "$(step_number "$START_STEP")" == "$(step_number docker)" || "$(step_number "$START_STEP")" == "$(step_number openclaw)" ]]; }; then
    return 0
  fi

  if zerotier_has_connected_network; then
    return 0
  fi

  echo "== ZeroTier resume preflight =="
  echo "No connected ZeroTier network found."

  if ! command -v zerotier-cli >/dev/null 2>&1; then
    echo "ZeroTier is not installed. Resume from the zerotier step instead:"
    echo "  sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -f zt"
    exit 1
  fi

  ensure_zerotier_service
  show_zerotier_node
  show_zerotier_networks
  join_zerotier_network
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

update_scripts() {
  local source="$UPDATE_SOURCE"
  local ref="$UPDATE_REF"
  local before after
  local git_cmd=(git -c "safe.directory=$PWD")
  local restart_args=("${PASSTHROUGH_ARGS[@]}")

  if ! command -v git >/dev/null 2>&1; then
    echo "Git is required to update scripts."
    exit 1
  fi

  if ! "${git_cmd[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Script update requires this directory to be a Git checkout."
    exit 1
  fi

  if [[ -n "$("${git_cmd[@]}" status --porcelain)" ]]; then
    echo "Refusing to update scripts with local changes present."
    echo "Commit, stash, or discard local changes before rerunning with -u."
    exit 1
  fi

  if [[ -z "$source" ]]; then
    source="$("${git_cmd[@]}" remote get-url origin 2>/dev/null || true)"
  fi

  if [[ -z "$source" ]]; then
    source="$DEFAULT_UPDATE_SOURCE"
  fi

  if [[ -z "$ref" ]]; then
    ref="$("${git_cmd[@]}" branch --show-current 2>/dev/null || true)"
  fi

  if [[ -z "$ref" ]]; then
    ref="main"
  fi

  echo "== Updating bootstrap scripts =="
  echo "Source: $source"
  echo "Ref:    $ref"

  before="$("${git_cmd[@]}" rev-parse HEAD)"
  "${git_cmd[@]}" fetch "$source" "$ref"
  "${git_cmd[@]}" merge --ff-only FETCH_HEAD
  after="$("${git_cmd[@]}" rev-parse HEAD)"

  if [[ "$before" == "$after" ]]; then
    echo "Scripts already up to date."
  else
    echo "Scripts updated: ${before}..${after}"
  fi

  if $UPDATE_SCRIPTS_ONLY; then
    echo "== Script update complete =="
    exit 0
  fi

  echo "== Restarting bootstrap after script update =="
  exec bash "$0" "${restart_args[@]}"
}

normalize_component_token() {
  local token="${1,,}"
  token="${token//[[:space:]]/}"

  case "$token" in
    all) echo "all" ;;
    c|caddy|proxy) echo "caddy" ;;
    oc|openclaw) echo "openclaw" ;;
    zt|zerotier) echo "zerotier" ;;
    *)
      echo "Unknown component: $1"
      echo "Supported values: all, c/caddy, oc/openclaw, zt/zerotier"
      exit 1
      ;;
  esac
}

run_component_updates() {
  local raw_list="$1"
  local token normalized
  local -a requested=()
  local do_caddy=false
  local do_openclaw=false
  local do_zerotier=false

  IFS=',' read -r -a requested <<<"$raw_list"
  if [[ "${#requested[@]}" -eq 0 ]]; then
    echo "--update-components requires at least one component."
    exit 1
  fi

  for token in "${requested[@]}"; do
    normalized="$(normalize_component_token "$token")"
    case "$normalized" in
      all)
        do_caddy=true
        do_openclaw=true
        do_zerotier=true
        ;;
      caddy) do_caddy=true ;;
      openclaw) do_openclaw=true ;;
      zerotier) do_zerotier=true ;;
    esac
  done

  echo "== Updating selected components =="
  if $do_caddy; then
    echo "-- Updating Caddy proxy --"
    run_script "scripts/expose-openclaw-zerotier.sh"
  fi

  if $do_zerotier; then
    echo "-- Updating ZeroTier --"
    curl -s https://install.zerotier.com | bash
    ensure_zerotier_service
    zerotier-cli -v || true
  fi

  if $do_openclaw; then
    echo "-- Updating OpenClaw --"
    run_script "scripts/install-openclaw.sh"
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
    --from|-f)
      START_STEP="${2:-}"
      if [[ -z "$START_STEP" ]]; then
        echo "--from requires a step name."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      step_number "$START_STEP" >/dev/null
      shift 2
      ;;
    -n|--zerotier-network-id)
      ZT_NETWORK_ID="${2:-}"
      if [[ -z "$ZT_NETWORK_ID" ]]; then
        echo "$1 requires a value."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    -u|-us|--update-scripts)
      UPDATE_SCRIPTS=true
      shift
      ;;
    -uso|--update-scripts-only|-ous|--only-update-scripts)
      UPDATE_SCRIPTS=true
      UPDATE_SCRIPTS_ONLY=true
      shift
      ;;
    -uc|--update-components)
      UPDATE_COMPONENTS="${2:-}"
      if [[ -z "$UPDATE_COMPONENTS" ]]; then
        echo "$1 requires a value."
        exit 1
      fi
      shift 2
      ;;
    -s|-source|--update-source)
      UPDATE_SOURCE="${2:-}"
      if [[ -z "$UPDATE_SOURCE" ]]; then
        echo "$1 requires a value."
        exit 1
      fi
      shift 2
      ;;
    -r|-ref|--update-ref)
      UPDATE_REF="${2:-}"
      if [[ -z "$UPDATE_REF" ]]; then
        echo "$1 requires a value."
        exit 1
      fi
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      if [[ -z "$ENV_FILE" ]]; then
        echo "--env-file requires a value."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    -y|--non-interactive|--yes)
      NONINTERACTIVE=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --wait-zt-address)
      WAIT_ZT_ADDRESS=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --no-wait-zt-address)
      WAIT_ZT_ADDRESS=false
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --zt-address-timeout)
      ZT_ADDRESS_TIMEOUT="${2:-}"
      if [[ -z "$ZT_ADDRESS_TIMEOUT" ]]; then
        echo "--zt-address-timeout requires a value."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --zt-detect-interval)
      ZT_DETECT_INTERVAL="${2:-}"
      if [[ -z "$ZT_DETECT_INTERVAL" ]]; then
        echo "--zt-detect-interval requires a value."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --admin-user|-au)
      ADMIN_USER="${2:-}"
      if [[ -z "$ADMIN_USER" ]]; then
        echo "--admin-user requires a value."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --skip-admin-user|--no-admin-user|-sau)
      CREATE_ADMIN_USER=false
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --lock-bootstrap-user|--lock-permissions-on-success|-lbu)
      LOCK_BOOTSTRAP_USER_ON_SUCCESS=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --skip-docker|--no-docker|-sd)
      INSTALL_DOCKER=false
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --skip-openclaw|--no-openclaw|-soc)
      INSTALL_OPENCLAW=false
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --openclaw-defaults|--openclaw-setup-defaults|--use-defaults|-ocd|-ud)
      OPENCLAW_DEFAULTS=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --skip-proxy|--no-proxy|-sp)
      EXPOSE_OPENCLAW_ZT=false
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --skip-approve-device|--no-approve-device|-sad)
      APPROVE_OPENCLAW_DEVICE=false
      PASSTHROUGH_ARGS+=("$1")
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
  echo "Please run as root, e.g. sudo bash clawtier.sh"
  exit 1
fi

export ADMIN_USER
export LOCK_BOOTSTRAP_USER_ON_SUCCESS
export NONINTERACTIVE
export WAIT_ZT_ADDRESS
export ZT_ADDRESS_TIMEOUT
export ZT_DETECT_INTERVAL

if [[ -z "$ENV_FILE" && -n "${BOOTSTRAP_ENV_FILE:-}" ]]; then
  ENV_FILE="$BOOTSTRAP_ENV_FILE"
fi

load_env_file "$ENV_FILE"

if $UPDATE_SCRIPTS; then
  update_scripts
fi

if [[ -n "$UPDATE_COMPONENTS" ]]; then
  run_component_updates "$UPDATE_COMPONENTS"
fi

echo "== Bootstrap start =="
echo "Starting from step: $START_STEP"

if [[ "$(step_number "$START_STEP")" -lt "$(step_number docker)" ]]; then
  require_zerotier_network_id
fi

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
    openssl \
    jq \
    unattended-upgrades

  echo "== Allowing SSH through UFW =="
  ufw allow 22/tcp
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
  ensure_zerotier_installed
  ensure_zerotier_service

  if systemctl list-unit-files fail2ban.service >/dev/null 2>&1; then
    systemctl enable --now fail2ban
  else
    echo "fail2ban service not found; skipping service enable."
  fi

  show_zerotier_node
  join_zerotier_network
  show_zerotier_networks
fi

ensure_zerotier_connected_for_resume

if should_run docker; then
  if $INSTALL_DOCKER; then
    run_script "scripts/install-docker.sh"
  else
    echo "Skipping Docker install"
  fi
fi

if should_run openclaw; then
  if $INSTALL_OPENCLAW; then
    if $OPENCLAW_DEFAULTS; then
      OPENCLAW_SETUP_USE_DEFAULTS=true run_script "scripts/install-openclaw.sh"
    else
      run_script "scripts/install-openclaw.sh"
    fi
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

if should_run approve-device; then
  if $APPROVE_OPENCLAW_DEVICE; then
    run_script "scripts/approve-openclaw-device.sh"
  else
    echo "Skipping OpenClaw device approval"
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
