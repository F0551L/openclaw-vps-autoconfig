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
HARDEN_ZEROTIER="${HARDEN_ZEROTIER:-false}"
ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"
ZT_NETWORK_IDS=()
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
RESET_STEP="${RESET_STEP:-}"
FORCE=false
REINSTALL_AFTER_RESET=false
ENV_FILE="${ENV_FILE:-}"
PASSTHROUGH_ARGS=()

usage() {
  cat <<EOF
Usage: sudo clawtier [options]

Options:
  -n, --zerotier-network-id ID[,ID...]
                              ZeroTier network ID(s) to join. Use comma-delimited values.
  -u, -us, --update-scripts   Update this bootstrap checkout before continuing.
  -uso, --update-scripts-only Update this bootstrap checkout, then exit.
  -uc, --update-components LIST
                              Update installed components (all, c/caddy, oc/openclaw, zt/zerotier).
                              Use comma-delimited values, e.g. oc,zt.
  -s, -source, --update-source URL
                              Override Git source for script updates.
  -ref, --update-ref REF       Override Git ref for script updates. Default: current branch.
  -r, --reset STEP             Reset/reinstall from STEP or mode with cascade handling.
                              Modes: data/clawtier-data, full/all.
  --reinstall                  Continue bootstrap after --reset completes.
  --force                      Force reset without y/n prompt, and leave unspecified
                              ZeroTier networks without prompting when -n is provided.
  -ef, --env-file FILE         Load bootstrap environment values from FILE.
  -y, --non-interactive       Never prompt; fail or skip when input is missing.
  --wait-zt-address           Wait for ZeroTier address assignment before proxy setup. Default.
  --no-wait-zt-address        Skip proxy setup if no ZeroTier address is assigned yet.
  --zt-address-timeout SECONDS
                              Maximum time to wait for ZeroTier address assignment.
  --zt-detect-interval SECONDS
                              Seconds between ZeroTier address detection attempts. Default: 10.
  -f, --from STEP             Start from STEP and continue onward.
                              Steps: b/base, zt/zerotier, au/admin-user, d/docker,
                                     oc/openclaw, p/proxy, ad/approve-device,
                                     rc/reboot-check.
  -au, --admin-user USER      Admin sudo user to create. Default: ocadmin.
  -sau, --skip-admin-user     Skip admin user creation.
  -lbu, --lock-bootstrap-user Lock the original sudo user after admin user setup succeeds.
  --harden                    Apply the recommended ZeroTier Flow Rules baseline.
  -sd, --skip-docker          Skip Docker installation.
  -soc, --skip-openclaw       Skip OpenClaw installation.
  -ocd, -ud, --openclaw-defaults, --use-defaults
                              Run OpenClaw setup with opinionated local defaults.
  -sp, --skip-proxy           Skip ZeroTier reverse proxy setup.
  -sad, --skip-approve-device Skip interactive OpenClaw device approval.
  -h, --help                  Show this help.

Environment:
  ZT_NETWORK_ID               ZeroTier network ID(s) to join, comma-delimited for multiple networks.
  NONINTERACTIVE              Set true to disable prompts.
  WAIT_ZT_ADDRESS             Set false to skip proxy setup when no ZeroTier address is assigned.
  ZT_ADDRESS_TIMEOUT          Maximum time to wait for ZeroTier address assignment.
  ZT_DETECT_INTERVAL          Seconds between ZeroTier address detection attempts.
  ZEROTIER_API_TOKEN          ZeroTier Central API token for automatic node authorization.
  ZEROTIER_API_TOKEN_FILE     Root-owned file containing ZeroTier Central API token.
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
  HARDEN_ZEROTIER             Set true to apply the recommended ZeroTier Flow Rules baseline.

Examples:
  sudo clawtier -u -n 0123456789abcdef
  sudo clawtier -y -n 0123456789abcdef -ocd -sad
  sudo clawtier -n 0123456789abcdef -au openclaw
  sudo clawtier -n 0123456789abcdef -f d
  sudo clawtier -n 0123456789abcdef -f p
  sudo clawtier -n 0123456789abcdef -ocd -sad
  sudo clawtier -n 0123456789abcdef --harden
  sudo clawtier -f ad
  sudo clawtier -uc all
  sudo clawtier -uc c,oc,zt
  sudo clawtier -r zt --force
  sudo clawtier --reset full --reinstall --force -n 0123456789abcdef -ocd
EOF
}

install_cli_wrapper() {
  local script_path wrapper_path
  script_path="$(realpath "$0")"
  wrapper_path="/usr/local/bin/clawtier"

  install -d -m 755 /usr/local/bin
  cat > "${wrapper_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec bash "${script_path}" "\$@"
EOF
  chmod 755 "${wrapper_path}"
  echo "Installed ${wrapper_path} -> ${script_path}"
  echo "You can now run: sudo clawtier [options]"
}

uninstall_cli_wrapper() {
  local wrapper_path="/usr/local/bin/clawtier"
  if [[ -e "${wrapper_path}" ]]; then
    rm -f "${wrapper_path}"
    echo "Removed ${wrapper_path}"
  fi
}

step_number() {
  case "$1" in
    b|base|bootstrap) echo 1 ;;
    zt|zerotier) echo 2 ;;
    au|admin-user|admin|user) echo 3 ;;
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

normalize_reset_target() {
  case "$1" in
    data|clawtier-data|wipe-data|delete-data|app-data) echo "data" ;;
    full|all|scratch|from-scratch|full-reset) echo "full" ;;
    *) step_number "$1" >/dev/null; echo "$1" ;;
  esac
}

reset_reinstall_start_step() {
  case "$(normalize_reset_target "$1")" in
    full) echo "base" ;;
    data) echo "zerotier" ;;
    *) echo "$1" ;;
  esac
}

should_run() {
  local step="$1"
  [[ "$(step_number "$step")" -ge "$(step_number "$START_STEP")" ]]
}

is_true() {
  [[ "${1:-}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy])$ ]]
}

configure_fail2ban_sshd_jail() {
  local jail_dir="/etc/fail2ban/jail.d"
  local jail_file="${jail_dir}/clawtier-sshd.local"

  mkdir -p "$jail_dir"
  cat >"$jail_file" <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 6
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.rndtime = 5m
EOF

  echo "Configured fail2ban SSH jail: $jail_file"
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

parse_zerotier_network_ids() {
  local raw token existing
  local -a parsed=()

  ZT_NETWORK_IDS=()
  if [[ -z "$ZT_NETWORK_ID" ]]; then
    return 0
  fi

  raw="${ZT_NETWORK_ID//[[:space:]]/}"
  IFS=',' read -r -a parsed <<<"$raw"

  for token in "${parsed[@]}"; do
    if [[ -z "$token" ]]; then
      echo "Invalid ZeroTier network list: $ZT_NETWORK_ID"
      echo "Use comma-delimited 16-character hexadecimal network IDs."
      exit 1
    fi

    if [[ ! "$token" =~ ^[0-9a-fA-F]{16}$ ]]; then
      echo "Invalid ZeroTier Network ID format: $token"
      echo "Expected a 16-character hexadecimal network ID."
      exit 1
    fi

    for existing in "${ZT_NETWORK_IDS[@]}"; do
      if [[ "${existing,,}" == "${token,,}" ]]; then
        continue 2
      fi
    done

    ZT_NETWORK_IDS+=("$token")
  done
}

require_zerotier_network_id() {
  while [[ -z "$ZT_NETWORK_ID" ]]; do
    if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
      echo "ZeroTier network ID is required. Pass it with -n ID."
      exit 1
    fi

    read -rp "Enter ZeroTier Network ID: " ZT_NETWORK_ID
  done

  parse_zerotier_network_ids
}

zerotier_has_joined_network() {
  command -v zerotier-cli >/dev/null 2>&1 || return 1
  zerotier-cli listnetworks 2>/dev/null | awk '/^200 listnetworks/ { found = 1 } END { exit found ? 0 : 1 }'
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

list_joined_zerotier_network_ids() {
  zerotier-cli listnetworks 2>/dev/null | awk '/^200 listnetworks/ { print $3 }'
}

zerotier_network_requested() {
  local network_id="$1"
  local requested

  for requested in "${ZT_NETWORK_IDS[@]}"; do
    if [[ "${requested,,}" == "${network_id,,}" ]]; then
      return 0
    fi
  done

  return 1
}

reconcile_zerotier_networks() {
  local joined answer

  if [[ "${#ZT_NETWORK_IDS[@]}" -eq 0 ]]; then
    return 0
  fi

  while read -r joined; do
    if [[ -z "$joined" ]] || zerotier_network_requested "$joined"; then
      continue
    fi

    if $FORCE; then
      echo "Leaving unspecified ZeroTier network due to --force: $joined"
      zerotier-cli leave "$joined"
      continue
    fi

    if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
      echo "Joined ZeroTier network is not listed in -n: $joined"
      echo "Pass all desired network IDs with -n, or rerun with --force to leave unspecified networks."
      exit 1
    fi

    read -rp "Leave unspecified ZeroTier network $joined? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      zerotier-cli leave "$joined"
    else
      echo "Keeping ZeroTier network: $joined"
    fi
  done < <(list_joined_zerotier_network_ids)
}

join_zerotier_networks() {
  local network_id

  if [[ -z "$ZT_NETWORK_ID" ]] && zerotier_has_joined_network; then
    echo "ZeroTier is already joined to a network; skipping network join."
    return 0
  fi

  require_zerotier_network_id

  for network_id in "${ZT_NETWORK_IDS[@]}"; do
    if zerotier-cli listnetworks 2>/dev/null | awk '{ print $3 }' | grep -qi "^${network_id}$"; then
      echo "Already joined ZeroTier network: $network_id"
    else
      echo "Joining ZeroTier network: $network_id"
      zerotier-cli join "$network_id"
    fi
  done

  reconcile_zerotier_networks
}

ensure_jq_installed() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing jq for ZeroTier Central API payload handling..."
  apt-get update
  apt-get install -y jq
}

load_zerotier_api_token() {
  local perms

  if [[ -z "$ZEROTIER_API_TOKEN_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$ZEROTIER_API_TOKEN_FILE" ]]; then
    echo "ZeroTier API token file not found: $ZEROTIER_API_TOKEN_FILE"
    exit 1
  fi

  if [[ "$(stat -c "%u" "$ZEROTIER_API_TOKEN_FILE")" != "0" ]]; then
    echo "ZeroTier API token file must be owned by root: $ZEROTIER_API_TOKEN_FILE"
    exit 1
  fi

  perms="$(stat -c "%A" "$ZEROTIER_API_TOKEN_FILE")"
  if [[ "${perms:5:1}" == "w" || "${perms:8:1}" == "w" ]]; then
    echo "ZeroTier API token file must not be writable by group or other users: $ZEROTIER_API_TOKEN_FILE"
    echo "Run: sudo chmod 600 $ZEROTIER_API_TOKEN_FILE"
    exit 1
  fi

  ZEROTIER_API_TOKEN="$(head -n 1 "$ZEROTIER_API_TOKEN_FILE" | tr -d '\r')"
}

resolve_zerotier_network_id_for_api() {
  local networks count network_id

  if [[ -n "$ZT_NETWORK_ID" ]]; then
    echo "$ZT_NETWORK_ID"
    return 0
  fi

  networks="$(zerotier-cli listnetworks 2>/dev/null || true)"
  count="$(awk '/^200 listnetworks/ { count += 1 } END { print count + 0 }' <<<"$networks")"

  if [[ "$count" -eq 1 ]]; then
    awk '/^200 listnetworks/ { print $3; exit }' <<<"$networks"
    return 0
  fi

  if [[ "$count" -eq 0 ]]; then
    echo "No joined ZeroTier networks found; pass -n NETWORK_ID before using --harden." >&2
  else
    echo "Multiple joined ZeroTier networks found; pass -n NETWORK_ID with --harden." >&2
  fi
  exit 1
}

default_zerotier_flow_rules_source() {
  cat <<'EOF'
# Allow SSH
accept
  ipprotocol tcp
  and dport 22;

# Allow HTTP/HTTPS
accept
  ipprotocol tcp
  and dport 80 or dport 443;

# Block new TCP connections that are not explicitly allowed
break
  chr tcp_syn
  and not chr tcp_ack;

# Allow remaining traffic (reply packets, ICMP, other required protocols)
accept;
EOF
}

harden_zerotier_network() {
  local network_id api_url response_file network_json rules_source payload http_code

  if ! is_true "$HARDEN_ZEROTIER"; then
    return 0
  fi

  echo "== Applying ZeroTier Flow Rules hardening =="
  load_zerotier_api_token

  if [[ -z "$ZEROTIER_API_TOKEN" ]]; then
    echo "--harden requires ZEROTIER_API_TOKEN_FILE or ZEROTIER_API_TOKEN."
    exit 1
  fi

  ensure_jq_installed
  network_id="$(resolve_zerotier_network_id_for_api)"

  if [[ ! "$network_id" =~ ^[0-9a-fA-F]{16}$ ]]; then
    echo "Invalid ZeroTier Network ID format: $network_id"
    echo "Expected a 16-character hexadecimal network ID."
    exit 1
  fi

  api_url="https://api.zerotier.com/api/v1/network/${network_id}"
  response_file="$(mktemp)"

  echo "Network ID: $network_id"
  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: token ${ZEROTIER_API_TOKEN}" \
    "$api_url" || true)"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "ZeroTier Central network fetch failed (HTTP ${http_code:-unknown})."
    if [[ -s "$response_file" ]]; then
      cat "$response_file"
      echo ""
    fi
    rm -f "$response_file"
    exit 1
  fi

  network_json="$(cat "$response_file")"
  rules_source="$(default_zerotier_flow_rules_source)"
  payload="$(jq --arg rulesSource "$rules_source" '.rulesSource = $rulesSource' <<<"$network_json")"

  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    -H "Authorization: token ${ZEROTIER_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$api_url" || true)"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "ZeroTier Flow Rules hardening applied (HTTP ${http_code})."
    rm -f "$response_file"
    return 0
  fi

  echo "ZeroTier Flow Rules hardening failed (HTTP ${http_code:-unknown})."
  if [[ -s "$response_file" ]]; then
    cat "$response_file"
    echo ""
  fi
  rm -f "$response_file"
  exit 1
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
    echo "  sudo clawtier -n YOUR_ZEROTIER_NETWORK_ID -f zt"
    exit 1
  fi

  ensure_zerotier_service
  show_zerotier_node
  show_zerotier_networks
  join_zerotier_networks
}

run_script() {
  local script_path="$1"
  shift || true

  if [[ -f "$script_path" ]]; then
    bash "$script_path" "$@"
  else
    echo "Required script not found: $script_path"
    exit 1
  fi
}

run_script_as_admin_user() {
  local script_path="$1"
  shift || true

  if [[ -z "${ADMIN_USER:-}" ]]; then
    echo "ADMIN_USER is not set; cannot run script as admin user."
    exit 1
  fi

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    echo "Admin user not found: $ADMIN_USER"
    exit 1
  fi

  if [[ ! -f "$script_path" ]]; then
    echo "Required script not found: $script_path"
    exit 1
  fi

  local quoted_script quoted_args cmd
  quoted_script="$(printf '%q' "$PWD/$script_path")"
  quoted_args=""
  while (($#)); do
    quoted_args+=" $(printf '%q' "$1")"
    shift
  done

  cmd="sudo -E bash ${quoted_script}${quoted_args}"
  su - "$ADMIN_USER" -c "$cmd"
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
    OPENCLAW_FORCE_INSTALL=true run_script "scripts/install-openclaw.sh"
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
    -ref|--update-ref)
      UPDATE_REF="${2:-}"
      if [[ -z "$UPDATE_REF" ]]; then
        echo "$1 requires a value."
        exit 1
      fi
      shift 2
      ;;
    -r|--reset)
      RESET_STEP="${2:-}"
      if [[ -z "$RESET_STEP" ]]; then
        echo "--reset requires a step name."
        exit 1
      fi
      PASSTHROUGH_ARGS+=("$1" "$2")
      normalize_reset_target "$RESET_STEP" >/dev/null
      shift 2
      ;;
    --reinstall|--reset-reinstall|--reinstall-after-reset)
      REINSTALL_AFTER_RESET=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --force)
      FORCE=true
      NONINTERACTIVE=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --env-file|-ef)
      ENV_FILE="${2:-}"
      if [[ -z "$ENV_FILE" ]]; then
        echo "$1 requires a value."
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
    --harden)
      HARDEN_ZEROTIER=true
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
  echo "Please run as root, e.g. sudo clawtier"
  exit 1
fi

install_cli_wrapper

if $REINSTALL_AFTER_RESET && [[ -z "$RESET_STEP" ]]; then
  echo "--reinstall requires --reset STEP."
  exit 1
fi

export ADMIN_USER
export HARDEN_ZEROTIER
export LOCK_BOOTSTRAP_USER_ON_SUCCESS
export NONINTERACTIVE
export WAIT_ZT_ADDRESS
export ZT_ADDRESS_TIMEOUT
export ZT_DETECT_INTERVAL
export ZT_NETWORK_ID
export ZEROTIER_API_TOKEN
export ZEROTIER_API_TOKEN_FILE

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

if [[ -n "$RESET_STEP" ]]; then
  echo "== Reset/reinstall management =="
  if $FORCE || is_true "$NONINTERACTIVE"; then
    run_script "scripts/reset-reinstall.sh" --reset "$RESET_STEP" --force
  else
    run_script "scripts/reset-reinstall.sh" --reset "$RESET_STEP"
  fi

  if ! $REINSTALL_AFTER_RESET; then
    if [[ "$(normalize_reset_target "$RESET_STEP")" == "full" ]]; then
      uninstall_cli_wrapper
    fi
    exit 0
  fi

  START_STEP="$(reset_reinstall_start_step "$RESET_STEP")"
  echo "== Continuing bootstrap after reset =="
  echo "Starting from step: $START_STEP"
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

  echo "== Configuring fail2ban SSH protections =="
  configure_fail2ban_sshd_jail
fi

if should_run zerotier; then
  ensure_zerotier_installed
  ensure_zerotier_service

  if systemctl list-unit-files fail2ban.service >/dev/null 2>&1; then
    systemctl enable --now fail2ban
    systemctl restart fail2ban
  else
    echo "fail2ban service not found; skipping service enable."
  fi

  show_zerotier_node
  join_zerotier_networks
  show_zerotier_networks
  harden_zerotier_network
fi

if should_run admin-user; then
  if $CREATE_ADMIN_USER; then
    run_script "scripts/create-admin-user.sh"
    ADMIN_USER_READY=true
  else
    echo "Skipping admin user creation"
  fi
fi

ensure_zerotier_connected_for_resume

if should_run docker; then
  if $INSTALL_DOCKER; then
    run_script_as_admin_user "scripts/install-docker.sh"
  else
    echo "Skipping Docker install"
  fi
fi

if should_run openclaw; then
  if $INSTALL_OPENCLAW; then
    if $OPENCLAW_DEFAULTS; then
      OPENCLAW_SETUP_USE_DEFAULTS=true run_script_as_admin_user "scripts/install-openclaw.sh"
    else
      run_script_as_admin_user "scripts/install-openclaw.sh"
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
