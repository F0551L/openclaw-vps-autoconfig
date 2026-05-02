# OpenClaw-over-ZeroTier VPS Bootstrap

Bootstrap and configuration scripts for a disposable Ubuntu VPS running OpenClaw with private access over ZeroTier.

---

## Quick Start

From a fresh Ubuntu VPS:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/F0551L/openclaw-vps-autoconfig.git
cd openclaw-vps-autoconfig
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID -sad
```

If ZeroTier Central has not assigned the VPS an address yet, authorize the printed node ID, then rerun the proxy step:

```bash
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID -f p -sad
```

During the proxy step, the script prints a tokenized Control UI URL. Open that URL from the browser/profile you want to use, trust the printed self-signed certificate if needed, then approve the pending browser device:

```bash
sudo bash bootstrap.sh -f ad
```

The `ad` step can be rerun any time a new browser/profile needs approval.

For unattended bootstrap runs that should not wait for ZeroTier address assignment, skip the proxy and approval handoffs until later:

```bash
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID --no-wait-zt-address -sad
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID -f p -sad
sudo bash bootstrap.sh -f ad
```

---

## Overview

This repo defines a **baseline configuration** for a fresh VPS, with a focus on repeatability, minimal manual intervention, and keeping OpenClaw off the public internet where possible.

ZeroTier is part of the baseline, not an optional add-on. The intended access model is SSH over the VPS public IP for initial provisioning, then OpenClaw over the private ZeroTier network.

### Goals

* Rebuild from scratch in minutes
* Avoid manual configuration drift
* Keep infrastructure simple and reproducible
* Prefer ephemeral / disposable servers
* Separate base system setup from application setup

---

## Usage

### 1. Provision VPS

* Create a new VPS (e.g. Contabo)
* Choose a standard Linux image (Ubuntu recommended)

---

### 2. Connect via SSH

```bash
ssh user@YOUR_IP
```

---

### 3. Run bootstrap

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/F0551L/openclaw-vps-autoconfig.git
cd openclaw-vps-autoconfig
sudo bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID
```

During bootstrap you may be prompted for:

* ZeroTier Network ID, if `-n` was not provided

Bootstrap creates a sudo-capable `ocadmin` user by default. Docker, OpenClaw, and the ZeroTier reverse proxy also run by default. Use the skip flags below when you want to stop before one of those stages.

To pull the latest bootstrap scripts from Git before continuing:

```bash
sudo bash bootstrap.sh -u -n YOUR_ZEROTIER_NETWORK_ID
```

To update the scripts and stop before running any setup:

```bash
sudo bash bootstrap.sh -uso
```

---

### 4. Optional: run non-interactively

```bash
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID -au openclaw -sad
```

`--zerotier-network-id` is also accepted as a longer alias for `-n`.

`-sad` skips the interactive Control UI device approval step. Run it later after opening the printed tokenized URL in the browser/profile you want to approve:

```bash
sudo bash bootstrap.sh -f ad
```

`-y, --non-interactive` disables prompts. Missing required values fail fast, and the device approval step prints the setup URL without polling.

To keep repeat rebuild inputs in one place, use a root-owned env file:

```bash
sudo install -m 600 -o root -g root /dev/null /root/openclaw-bootstrap.env
sudo nano /root/openclaw-bootstrap.env
sudo bash bootstrap.sh --env-file /root/openclaw-bootstrap.env -y -sad
```

Example env file:

```bash
ZT_NETWORK_ID=YOUR_ZEROTIER_NETWORK_ID
ADMIN_USER=ocadmin
ZT_ADDRESS_TIMEOUT=300
GATEWAY_TOKEN=optional-existing-token
```

To keep going without waiting for ZeroTier Central address assignment:

```bash
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID --no-wait-zt-address -sad
```

To wait longer for address assignment:

```bash
sudo bash bootstrap.sh -y -n YOUR_ZEROTIER_NETWORK_ID --zt-address-timeout 300 --zt-detect-interval 15 -sad
```

For forks or custom script sources, override the update source:

```bash
sudo bash bootstrap.sh -u -s https://github.com/YOUR_USERNAME/openclaw-vps-autoconfig.git -n YOUR_ZEROTIER_NETWORK_ID
```

To install an SSH public key for the admin user during bootstrap:

```bash
sudo env ADMIN_SSH_PUBLIC_KEY_FILE=/root/.ssh/authorized_keys bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID
```

By default, password login for the admin user remains locked. To set an initial password, prefer a hidden prompt:

```bash
sudo env ADMIN_PASSWORD_PROMPT=true bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID
```

For non-interactive rebuilds, use a root-only password file instead of putting the password directly in a command:

```bash
sudo install -m 600 /dev/null /root/ocadmin.password
sudo nano /root/ocadmin.password
sudo env ADMIN_PASSWORD_FILE=/root/ocadmin.password bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID
```

---

### 5. Resume from a specific step

If a run is interrupted, call `bootstrap.sh` again with `-f, --from`:

```bash
sudo bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID -f d
sudo bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID -f oc
sudo bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID -f p
sudo bash bootstrap.sh -f ad
```

When resuming from `docker` or `openclaw`, bootstrap checks whether ZeroTier is connected. If no connected ZeroTier network is found, it asks for `-n` interactively and tries to join before continuing.

Available steps:

* `b`, `base` — system packages, firewall, fail2ban
* `au`, `admin-user` — create a sudo-capable admin user, default `ocadmin`
* `zt`, `zerotier` — install ZeroTier and join the required network
* `d`, `docker` — install Docker
* `oc`, `openclaw` — install OpenClaw
* `p`, `proxy` — expose OpenClaw to ZeroTier peers through Caddy
* `ad`, `approve-device` — interactively approve a pending Control UI browser device
* `rc`, `reboot-check` — check whether the VPS needs a reboot

Useful skip flags:

```bash
sudo bash bootstrap.sh -sau
sudo bash bootstrap.sh -sd
sudo bash bootstrap.sh -soc
sudo bash bootstrap.sh -sp
sudo bash bootstrap.sh -sad
```

To lock the original sudo/bootstrap user after the `ocadmin` account is created successfully:

```bash
sudo bash bootstrap.sh -n YOUR_ZEROTIER_NETWORK_ID -lbu
```

---

### 6. Reboot (if required)

```bash
sudo reboot
```

---

## Structure

```
.
├── bootstrap.sh              # Base system setup (packages, firewall, ZeroTier)
├── scripts/
│   ├── create-admin-user.sh  # Sudo admin user creation
│   ├── install-docker.sh     # Docker installation
│   ├── install-openclaw.sh   # OpenClaw install (official Docker setup)
│   ├── approve-openclaw-device.sh # Interactive Control UI device approval
│   └── expose-openclaw-zerotier.sh # ZeroTier-only Caddy proxy
└── README.md
```

---

## Setup Stages

### Stage 1 — Bootstrap

Handled by `bootstrap.sh`:

* System update/upgrade
* Base package install (`curl`, `git`, `ufw`, `fail2ban`, `openssl`, `jq`)
* Firewall configuration
* Admin user creation
* ZeroTier install and required network join

This stage prepares a **secure, minimal, network-ready host**.

---

### Stage 2 — Services

Handled by scripts in `/scripts`:

* Docker installation (`install-docker.sh`)
* OpenClaw deployment (`install-openclaw.sh`)

This separation allows:

* changing app stack without touching base config
* easier rebuilds and experimentation

OpenClaw is installed using its official Docker-based setup script, which manages its own containers and configuration.
By default, `scripts/install-openclaw.sh` checks out GitHub's latest OpenClaw release tag instead of repository HEAD. To pin or test a different ref:

```bash
sudo OPENCLAW_REF=v2026.4.15 bash scripts/install-openclaw.sh
sudo OPENCLAW_REF=main bash scripts/install-openclaw.sh
```

### Stage 3 — ZeroTier-only OpenClaw access

Handled by `scripts/expose-openclaw-zerotier.sh`:

* Prints the ZeroTier node ID and joined network IDs
* Detects the VPS ZeroTier IPv4 address
* Prompts for retry in interactive mode, or polls in noninteractive mode, if no ZeroTier address is available yet
* Generates a self-signed HTTPS certificate for the ZeroTier IP
* Generates a Caddy reverse proxy config with HTTP redirected to HTTPS
* Runs Caddy as a Docker container with host networking
* Binds the proxy to the ZeroTier address only
* Adds both HTTP and HTTPS ZeroTier Control UI URLs to `gateway.controlUi.allowedOrigins`
* Enables token auth and syncs `gateway.remote.token` with `gateway.auth.token`
* Prints a tokenized Control UI URL for first browser setup
* Allows the proxy ports through UFW on the ZeroTier interface only

By default, OpenClaw remains on the host loopback address at `127.0.0.1:18789`, and the proxy exposes it to ZeroTier peers at:

```bash
https://ZEROTIER_IP/
```

The script prints the generated gateway token, a tokenized Control UI URL, and the device approval command at the end. Because the default HTTPS certificate is self-signed, install and trust the printed `.crt` file on any client device that will use the Control UI.

Run manually after OpenClaw is installed:

```bash
sudo bash scripts/expose-openclaw-zerotier.sh
```

Optional overrides:

```bash
sudo PROXY_PORT=8080 bash scripts/expose-openclaw-zerotier.sh
sudo HTTPS_PROXY_PORT=8443 bash scripts/expose-openclaw-zerotier.sh
sudo OPENCLAW_UPSTREAM=127.0.0.1:18789 PROXY_PORT=8080 bash scripts/expose-openclaw-zerotier.sh
sudo GATEWAY_TOKEN=existing-or-preferred-token bash scripts/expose-openclaw-zerotier.sh
sudo WAIT_ZT_ADDRESS=false bash scripts/expose-openclaw-zerotier.sh
sudo ZT_ADDRESS_TIMEOUT=300 ZT_DETECT_INTERVAL=15 bash scripts/expose-openclaw-zerotier.sh
sudo ZT_IP=192.168.194.99 bash scripts/expose-openclaw-zerotier.sh
sudo ZT_DETECT_RETRIES=5 bash scripts/expose-openclaw-zerotier.sh
```

### Stage 4 — Control UI device approval

Handled by `scripts/approve-openclaw-device.sh`:

* Prints the tokenized Control UI URL
* Waits for you to open it from the browser/profile you want to approve
* Polls OpenClaw for pending device requests
* Approves the only pending request automatically, or asks for the request ID if multiple are pending

Run manually after opening the printed Control UI URL:

```bash
sudo bash scripts/approve-openclaw-device.sh
```

Useful overrides:

```bash
sudo OPENCLAW_URL=https://ZEROTIER_IP/ bash scripts/approve-openclaw-device.sh
sudo APPROVAL_POLL_SECONDS=300 bash scripts/approve-openclaw-device.sh
sudo GATEWAY_TOKEN=existing-token bash scripts/approve-openclaw-device.sh
```

---

## Networking

* Primary access via ZeroTier private network
* Public exposure should be avoided where possible
* ZeroTier setup is required before exposing OpenClaw

Default open ports:

* `22/tcp` — SSH
* `9993/udp` — ZeroTier
* OpenClaw reverse proxy ports — ZeroTier interface only, if enabled

Future option:

* Restrict SSH to ZeroTier only

---

## Security Notes

* Change provider/root passwords immediately after bootstrap
* Prefer SSH key authentication
* Bootstrap creates a password-locked, passwordless-sudo `ocadmin` user by default
* Use `ADMIN_PASSWORD_PROMPT=true` or a root-only `ADMIN_PASSWORD_FILE` if password login is needed
* Use `-lbu` only after you have confirmed the new admin account works
* Keep exposed ports to a minimum
* Prefer private network access over public endpoints

---

## Design Principles

* **Disposable first**
  Servers should be treated as replaceable

* **Scripted over manual**
  No SSH tinkering — everything goes into scripts

* **Minimal exposure**
  Only required ports/services are enabled

* **Layered setup**

  * Bootstrap = OS + base tools
  * Scripts = services + applications

---

## Future Work

* Restrict SSH access to ZeroTier after initial provisioning
* Automated rebuild workflow
* Optional SSH hardening script

---

## Notes

This setup is intentionally simple. Complexity should only be added when it provides clear value.

---
