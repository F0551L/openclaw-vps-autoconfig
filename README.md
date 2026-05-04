# [ClawTier](https://github.com/F0551L/ClawTier): [OpenClaw](https://github.com/openclaw/openclaw)-via-[ZeroTier](https://www.zerotier.com/) VPS Bootstrap

*Bootstrap scripts for running OpenClaw on a disposable Ubuntu VPS with private ZeroTier access.*

> ✨ **In short:** fast, repeatable OpenClaw setup with a ZeroTier-first access model.

---

## 🧭 Overview

ClawTier defines a **baseline configuration** for a fresh VPS, with a focus on repeatability, minimal manual intervention, and keeping OpenClaw off the public internet where possible.

ZeroTier is part of the baseline, not an optional add-on. The intended access model is SSH over the VPS public IP for initial provisioning, then OpenClaw over the private ZeroTier network.

### 🎯 Goals

* Rebuild from scratch in minutes
* Avoid manual configuration drift
* Keep infrastructure simple and reproducible
* Prefer ephemeral / disposable servers
* Separate base system setup from application setup

---

## 🚀 Quick Start

From a fresh Ubuntu VPS:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/F0551L/ClawTier.git
cd ClawTier
sudo install -m 600 -o root -g root /dev/null /root/clawtier-bootstrap.env
sudo install -m 600 -o root -g root /dev/null /root/zerotier-central.token
sudo nano /root/clawtier-bootstrap.env
sudo nano /root/zerotier-central.token
sudo bash clawtier.sh -ef /root/clawtier-bootstrap.env -y -n YOUR_ZEROTIER_NETWORK_ID -ocd
```

Suggested `/root/clawtier-bootstrap.env` contents:

```bash
ZT_NETWORK_ID=YOUR_ZEROTIER_NETWORK_ID
ADMIN_USER=ocadmin
ZT_ADDRESS_TIMEOUT=300
ZEROTIER_API_TOKEN_FILE=/root/zerotier-central.token
```

Suggested `/root/zerotier-central.token` contents (single line):

```text
YOUR_ZEROTIER_CENTRAL_API_TOKEN
```

⚠️ If [ZeroTier Central](https://my.zerotier.com/) has not assigned the VPS an address yet, authorize the printed node ID, then rerun the proxy step:

```bash
sudo bash clawtier.sh -f p -sad
```

To answer the OpenClaw onboarding prompts yourself instead of skipping onboarding for later, omit `-ocd`:

```bash
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -sad
```

During the proxy step, the script prints a tokenized Control UI URL. Open that URL from the browser/profile you want to use, trust the printed self-signed certificate if needed, then approve the pending browser device:

```bash
sudo bash clawtier.sh -f ad
```

The `ad` step can be rerun any time a new browser/profile needs approval.

🤖 For unattended bootstrap runs that should not wait for ZeroTier address assignment, skip the proxy and approval handoffs until later:

```bash
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ocd --no-wait-zt-address -sad
sudo bash clawtier.sh -f p -sad
sudo bash clawtier.sh -f ad
```

---

## 🛠️ Usage

Recommended reading order (for quickest success):

1. **Quick Start** for a first successful run.
2. **Non-interactive options** if you want unattended provisioning.
3. **Step resume and skip flags** for troubleshooting and partial reruns.
4. **Security notes** to understand hardening choices.

### 1️⃣ Provision VPS

* Create a new VPS (e.g. Contabo)
* Choose a standard Linux image (Ubuntu recommended)

---

### 2️⃣ Connect via SSH

```bash
ssh user@YOUR_IP
```

---

### 3️⃣ Run bootstrap

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/F0551L/ClawTier.git
cd ClawTier
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID
```

During bootstrap you may be prompted for:

* ZeroTier Network ID, if `-n` was not provided

Bootstrap creates a sudo-capable `ocadmin` user by default. Docker, OpenClaw, and the ZeroTier reverse proxy also run by default. Use the skip flags below when you want to stop before one of those stages.

🔄 To pull the latest bootstrap scripts from Git before continuing:

```bash
sudo bash clawtier.sh -u -n YOUR_ZEROTIER_NETWORK_ID
```

⬆️ To update installed component versions (currently Caddy proxy, OpenClaw, and ZeroTier):

```bash
sudo bash clawtier.sh -uc all
sudo bash clawtier.sh -uc c,oc,zt
sudo bash clawtier.sh --update-components caddy,openclaw,zerotier
```

🧪 To update the scripts and stop before running any setup:

```bash
sudo bash clawtier.sh -uso
```

---

### 4️⃣ Optional: run non-interactively

```bash
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -au openclaw -ocd -sad
```

`--zerotier-network-id` is also accepted as a longer alias for `-n`.

`-ocd` / `-ud` / `--openclaw-defaults` / `--use-defaults` runs OpenClaw Docker setup in a non-interactive mode that skips the interactive onboarding wizard for later completion. It does not currently apply opinionated onboarding defaults; Docker still generates or reuses the gateway token, and provider/account configuration remains for a later manual pass.

If `ZEROTIER_API_TOKEN_FILE` (preferred) or `ZEROTIER_API_TOKEN` is set, the proxy step calls the ZeroTier Central API (`POST /api/v1/network/{networkID}/member/{memberID}` with `{"config":{"authorized":true}}`) so fresh joins can be auto-authorized before address detection retries continue. `ZEROTIER_API_TOKEN_FILE` must be root-owned and not group/other writable.

`--harden` uses the same ZeroTier Central API token inputs to apply the recommended starter Flow Rules from the security notes below: SSH (`22/tcp`), HTTP (`80/tcp`), HTTPS (`443/tcp`), default-deny for other new TCP connections, then allow remaining reply/control traffic. If more than one ZeroTier network is joined, pass `-n NETWORK_ID` so the script knows which network to update.

`-sad` skips the interactive Control UI device approval step. Run it later after opening the printed tokenized URL in the browser/profile you want to approve:

```bash
sudo bash clawtier.sh -f ad
```

`-y, --non-interactive` disables prompts. Missing required values fail fast, and the device approval step prints the setup URL without polling.

To keep repeat rebuild inputs in one place, use a root-owned env file:

```bash
sudo install -m 600 -o root -g root /dev/null /root/clawtier-bootstrap.env
sudo nano /root/clawtier-bootstrap.env
sudo bash clawtier.sh -ef /root/clawtier-bootstrap.env -y -ocd -sad
```

Example env file:

```bash
ZT_NETWORK_ID=YOUR_ZEROTIER_NETWORK_ID
ADMIN_USER=ocadmin
ZT_ADDRESS_TIMEOUT=300
ZEROTIER_API_TOKEN_FILE=/root/zerotier-central.token
HARDEN_ZEROTIER=true
GATEWAY_TOKEN=optional-existing-token
```

To keep going without waiting for ZeroTier Central address assignment:

```bash
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ocd --no-wait-zt-address -sad
```

To wait longer for address assignment:

```bash
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ocd --zt-address-timeout 300 --zt-detect-interval 15 -sad
```

For forks or custom script sources, override the update source:

```bash
sudo bash clawtier.sh -u -s https://github.com/YOUR_USERNAME/ClawTier.git -n YOUR_ZEROTIER_NETWORK_ID
```

To install an SSH public key for the admin user during bootstrap:

```bash
sudo env ADMIN_SSH_PUBLIC_KEY_FILE=/root/.ssh/authorized_keys bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID
```

By default, password login for the admin user remains locked. To set an initial password, prefer a hidden prompt:

```bash
sudo env ADMIN_PASSWORD_PROMPT=true bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID
```

For non-interactive rebuilds, use a root-only password file instead of putting the password directly in a command:

```bash
sudo install -m 600 /dev/null /root/ocadmin.password
sudo nano /root/ocadmin.password
sudo env ADMIN_PASSWORD_FILE=/root/ocadmin.password bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ocd -sad
```

---

### 5️⃣ Resume from a specific step

If a run is interrupted, call `clawtier.sh` again with `-f, --from`:

```bash
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -f d
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -f oc
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -f p
sudo bash clawtier.sh -f ad
```

When resuming from `docker` or `openclaw`, bootstrap checks whether ZeroTier is connected. If no connected ZeroTier network is found, it asks for `-n` interactively and tries to join before continuing.

Bootstrap steps are safe to rerun after partial or manual setup. Docker and ZeroTier installs are skipped when already installed, an existing ZeroTier network membership is reused when no network ID is provided, and OpenClaw setup is skipped when an existing Docker Compose install is detected. The proxy step remains rerunnable so it can refresh the ZeroTier address, Caddy config, allowed Control UI origins, and gateway token without reinstalling OpenClaw.

Available steps:

* `b`, `base` — system packages, firewall, fail2ban
* `au`, `admin-user` — create a sudo-capable admin user, default `ocadmin`
* `zt`, `zerotier` — install ZeroTier and join the requested network, or reuse an existing joined network
* `d`, `docker` — install Docker, or start/enable an existing Docker service
* `oc`, `openclaw` — install OpenClaw, or skip when an existing install is detected
* `p`, `proxy` — expose OpenClaw to ZeroTier peers through Caddy
* `ad`, `approve-device` — interactively approve a pending Control UI browser device
* `rc`, `reboot-check` — check whether the VPS needs a reboot

Useful skip flags:

```bash
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -sau
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -sd
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -soc
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -sp
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -sad
```

Useful non-interactive examples:

```bash
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ocd
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ud
sudo bash clawtier.sh -ef /root/clawtier-bootstrap.env -y -n YOUR_ZEROTIER_NETWORK_ID -ocd
sudo bash clawtier.sh -y -n YOUR_ZEROTIER_NETWORK_ID -ocd --no-wait-zt-address -sad
```

### 6️⃣ Reset and rebuild

For partial rebuilds, reset from a specific step and then rerun from that step:

```bash
sudo bash clawtier.sh --reset openclaw --force
sudo OPENCLAW_FORCE_INSTALL=true bash clawtier.sh -f openclaw
```

For a ClawTier data wipe that keeps Docker and ZeroTier packages installed, use `data`:

```bash
sudo bash clawtier.sh --reset data --force
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -f zerotier -ocd
```

For a full local rebuild, use `full`. This removes the OpenClaw stack and proxy, purges Docker packages/data, purges ZeroTier packages/state, and deletes the managed admin user when it is safe to do so. If the script is invoked via that admin user, it skips deleting the current/invoking account.

```bash
sudo bash clawtier.sh --reset full --reinstall --force -n YOUR_ZEROTIER_NETWORK_ID -ocd
```

`--reinstall` continues bootstrap after cleanup. Without it, reset stops after cleanup and prints the suggested resume command.

To lock the original sudo/bootstrap user after the `ocadmin` account is created successfully:

```bash
sudo bash clawtier.sh -n YOUR_ZEROTIER_NETWORK_ID -lbu
```

---

### 7️⃣ Reboot (if required)

```bash
sudo reboot
```

---

## Structure

```
.
├── .github/
│   └── CODEOWNERS            # Repository-wide ownership rules
├── .gitignore
├── AGENTS.md                 # Agent workflow instructions
├── clawtier.sh              # Base system setup (packages, firewall, ZeroTier)
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

Handled by `clawtier.sh`:

* System update/upgrade
* Base package install (`curl`, `git`, `ufw`, `fail2ban`, `openssl`, `jq`)
* Fail2ban SSH jail baseline tuned to slow brute-force attempts without banning too aggressively on occasional typos
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

[OpenClaw](https://github.com/openclaw/openclaw) is installed using its official Docker-based setup script, which manages its own containers and configuration.
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

## Security Hardening Notes

This bootstrap is designed to reduce exposed attack surface for a disposable VPS pattern.

### Network controls

* `ufw` is enabled during bootstrap.
* SSH (`22/tcp`) is allowed.
* OpenClaw is kept on loopback (`127.0.0.1:18789`) and not exposed directly on the public interface.
* The Caddy reverse proxy binds to the ZeroTier interface/IP so Control UI access is limited to ZeroTier peers.
* In ZeroTier Central, keep **Access Control** set to a **Private** network (not **Public**) so member authorization remains required and devices can be de-authorized when needed.
* ⚠️ **Strong warning:** if the network is set to **Public** instead of **Private**, anyone who discovers your Network ID can join and reach your OpenClaw Control UI endpoint.
* For terminology and platform guidance, see ZeroTier docs on [Network access control (Public vs Private)](https://docs.zerotier.com/networks/) and [ZeroTier Security](https://docs.zerotier.com/security/).
* In ZeroTier Central **Flow Rules**, apply a default-deny policy that only permits remote-management and OpenClaw web ports (SSH 22/TCP, HTTP 80/TCP, HTTPS 443/TCP). The ZeroTier Rules Engine docs include a near-exact starter example (**"Example 1: Allow Only SSH and Web Traffic"**) for this pattern.
* Suggested starting Flow Rules (adapt from docs to your environment):

```text
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
```

* After applying Flow Rules, test from an authorized node: SSH should work, OpenClaw via HTTP/HTTPS should work, and non-approved new inbound TCP ports should fail.
* ZeroTier rule behavior is stateless; validate both directions of any traffic you intentionally allow and keep this in mind when tightening policies.

### Access controls

* A dedicated sudo admin account (`ocadmin` by default) is created.
* Optional `-lbu` / `--lock-bootstrap-user` locks the original bootstrap sudo user's password after successful admin-user setup.
* Device approval is explicit (`-sad` lets you postpone approval until you are ready).

### Service hardening

* `fail2ban` is installed and enabled when available.
* Baseline SSH jail defaults are written to `/etc/fail2ban/jail.d/clawtier-sshd.local`: `maxretry=6`, `findtime=10m`, `bantime=1h`, with incremental bans enabled for repeated offenders.
* `unattended-upgrades` is installed as part of baseline packages.
* OpenClaw auth and remote token values are synchronized by the proxy setup script.

### Operational guidance

* Prefer SSH keys over passwords for admin access.
* If you must set a password non-interactively, use a root-only file (`ADMIN_PASSWORD_FILE`) and avoid inline secrets in shell history.
* Rebuild frequently from automation rather than mutating long-lived servers manually.

---

## Networking

* Primary access via [ZeroTier](https://www.zerotier.com/) private network
* Public exposure should be avoided where possible
* ZeroTier setup is required before exposing OpenClaw

Default open ports:

* `22/tcp` — SSH
* OpenClaw reverse proxy ports — ZeroTier interface only, if enabled

Future option:

* Restrict SSH to ZeroTier only

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

## Contributing

* See `AGENTS.md` for the active agent workflow and sticky branch conventions
* Prefer **Squash and merge** for PRs
* Use stacked PRs to merge implementation branches back into their feature branch
* Merge the completed feature branch into `main`
* Avoid merge commits

---

## Future Work

* Multi-network exposure support
* ZeroTier route profile management with a fast override path for per-network defaults (including default-route behavior), plus interactive warnings when a selected network advertises catch-all routes (for example `0.0.0.0/0`) that require enabling Forward Traffic on the remote endpoint to avoid external connectivity loss and lockout
* Distro-aware setup script
* Optional script self-update when run from a Git repo, balancing safety with the existing opt-in update flag
* Restrict SSH access to ZeroTier after initial provisioning
* Automated rebuild workflow
* Optional SSH hardening script
* Investigate options for automatically configuring OpenClaw onboarding with opinionated defaults

---
