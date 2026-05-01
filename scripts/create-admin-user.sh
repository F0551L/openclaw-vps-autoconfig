#!/usr/bin/env bash
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-ocadmin}"
ADMIN_SSH_PUBLIC_KEY="${ADMIN_SSH_PUBLIC_KEY:-}"
ADMIN_SSH_PUBLIC_KEY_FILE="${ADMIN_SSH_PUBLIC_KEY_FILE:-}"
ADMIN_PASSWORD_FILE="${ADMIN_PASSWORD_FILE:-}"
ADMIN_PASSWORD_PROMPT="${ADMIN_PASSWORD_PROMPT:-false}"
SUDOERS_FILE="/etc/sudoers.d/${ADMIN_USER}"
AUTHORIZED_KEYS="/home/${ADMIN_USER}/.ssh/authorized_keys"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root, e.g. sudo bash scripts/create-admin-user.sh"
  exit 1
fi

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  echo "Invalid admin username: $ADMIN_USER"
  echo "Use a standard Linux username such as ocadmin."
  exit 1
fi

install_admin_key() {
  local key="$1"

  key="${key%$'\r'}"

  if [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]]; then
    return 0
  fi

  if grep -qxF "$key" "$AUTHORIZED_KEYS"; then
    echo "SSH public key already installed for $ADMIN_USER"
  else
    echo "$key" >> "$AUTHORIZED_KEYS"
    echo "Installed SSH public key for $ADMIN_USER"
  fi
}

set_admin_password() {
  local password="$1"

  if [[ -z "$password" ]]; then
    echo "Refusing to set an empty password for $ADMIN_USER"
    exit 1
  fi

  printf '%s:%s\n' "$ADMIN_USER" "$password" | chpasswd
  passwd --unlock "$ADMIN_USER" >/dev/null
  echo "Password login enabled for $ADMIN_USER"
}

if [[ "$(id -un)" == "$ADMIN_USER" || "${SUDO_USER:-}" == "$ADMIN_USER" ]]; then
  echo "Already running as admin user: $ADMIN_USER"
  exit 0
fi

echo "== Configuring admin user =="
echo "Admin user: $ADMIN_USER"

if id "$ADMIN_USER" >/dev/null 2>&1; then
  echo "User already exists: $ADMIN_USER"
else
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
  passwd --lock "$ADMIN_USER" >/dev/null
  echo "Created user: $ADMIN_USER"
fi

usermod -aG sudo "$ADMIN_USER"
echo "Added $ADMIN_USER to sudo group"

cat > "$SUDOERS_FILE" <<EOF
${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null
echo "Configured passwordless sudo for $ADMIN_USER"

echo "== Verifying admin user login shell =="
su - "$ADMIN_USER" -c "test \"\$(whoami)\" = '$ADMIN_USER'"
echo "Verified su login for $ADMIN_USER"

if [[ -n "$ADMIN_PASSWORD_FILE" ]]; then
  if [[ ! -f "$ADMIN_PASSWORD_FILE" ]]; then
    echo "Admin password file not found: $ADMIN_PASSWORD_FILE"
    exit 1
  fi

  set_admin_password "$(<"$ADMIN_PASSWORD_FILE")"
elif [[ "$ADMIN_PASSWORD_PROMPT" =~ ^([Tt]rue|1|[Yy]es)$ ]]; then
  read -rsp "Enter password for $ADMIN_USER: " ADMIN_PASSWORD
  echo ""
  read -rsp "Confirm password for $ADMIN_USER: " ADMIN_PASSWORD_CONFIRM
  echo ""

  if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
    echo "Passwords did not match."
    exit 1
  fi

  set_admin_password "$ADMIN_PASSWORD"
else
  echo "Password login remains locked for $ADMIN_USER"
fi

if [[ -n "$ADMIN_SSH_PUBLIC_KEY_FILE" ]]; then
  if [[ ! -f "$ADMIN_SSH_PUBLIC_KEY_FILE" ]]; then
    echo "SSH public key file not found: $ADMIN_SSH_PUBLIC_KEY_FILE"
    exit 1
  fi
fi

if [[ -n "$ADMIN_SSH_PUBLIC_KEY" || -n "$ADMIN_SSH_PUBLIC_KEY_FILE" ]]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
  touch "$AUTHORIZED_KEYS"
  chown "$ADMIN_USER:$ADMIN_USER" "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"

  if [[ -n "$ADMIN_SSH_PUBLIC_KEY_FILE" ]]; then
    while IFS= read -r key || [[ -n "$key" ]]; do
      install_admin_key "$key"
    done < "$ADMIN_SSH_PUBLIC_KEY_FILE"
  fi

  if [[ -n "$ADMIN_SSH_PUBLIC_KEY" ]]; then
    while IFS= read -r key || [[ -n "$key" ]]; do
      install_admin_key "$key"
    done <<< "$ADMIN_SSH_PUBLIC_KEY"
  fi
else
  echo "No SSH public key provided."
  echo "Add one later to /home/${ADMIN_USER}/.ssh/authorized_keys before disabling root SSH."
fi

echo ""
echo "Admin user ready:"
echo "  ssh ${ADMIN_USER}@YOUR_VPS_IP"
