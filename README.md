# openclaw-vps-autoconfig

Bootstrap and configuration scripts for a disposable VPS setup, intended for running OpenClaw and related services.

---

## Overview

This repo defines the **baseline configuration** for a fresh VPS, with a focus on repeatability and minimal manual intervention.

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
git clone https://github.com/YOUR_USERNAME/openclaw-vps-autoconfig.git
cd openclaw-vps-autoconfig
sudo bash bootstrap.sh
```

During bootstrap you may be prompted for:

* ZeroTier Network ID (optional)
* Whether to install Docker
* Whether to expose OpenClaw on ZeroTier through a reverse proxy

---

### 4. Optional: run with Docker automatically

```bash
sudo bash bootstrap.sh --with-docker
```

---

### 5. Reboot (if required)

```bash
sudo reboot
```

---

## Structure

```
.
├── bootstrap.sh              # Base system setup (packages, firewall, ZeroTier)
├── scripts/
│   ├── install-docker.sh     # Docker installation
│   ├── install-openclaw.sh   # OpenClaw install (official Docker setup)
│   ├── expose-openclaw-zerotier.sh
│   │                           # Caddy reverse proxy bound to ZeroTier only
│   └── harden-ssh.sh         # Optional SSH hardening
└── README.md
```

---

## Setup Stages

### Stage 1 — Bootstrap

Handled by `bootstrap.sh`:

* System update/upgrade
* Base package install (`curl`, `git`, `ufw`, `fail2ban`)
* Firewall configuration
* ZeroTier install and optional network join

This stage prepares a **secure, minimal, network-ready host**.

---

### Stage 2 — Services

Handled by scripts in `/scripts`:

* Docker installation (`install-docker.sh`)
* OpenClaw deployment (`install-openclaw.sh`)
* Optional SSH hardening

This separation allows:

* changing app stack without touching base config
* easier rebuilds and experimentation

OpenClaw is installed using its official Docker-based setup script, which manages its own containers and configuration.

### Stage 3 — ZeroTier-only OpenClaw access

Handled by `scripts/expose-openclaw-zerotier.sh`:

* Prints the ZeroTier node ID and joined network IDs
* Detects the VPS ZeroTier IPv4 address
* Prompts for retry if no ZeroTier address is available yet
* Generates a Caddy reverse proxy config
* Runs Caddy as a Docker container with host networking
* Binds the proxy to the ZeroTier address only
* Allows the proxy port through UFW on the ZeroTier interface only

By default, OpenClaw remains on the host loopback address at `127.0.0.1:18789`, and the proxy exposes it to ZeroTier peers at:

```bash
http://ZEROTIER_IP/
```

Run manually after OpenClaw is installed:

```bash
sudo bash scripts/expose-openclaw-zerotier.sh
```

Optional overrides:

```bash
sudo PROXY_PORT=8080 bash scripts/expose-openclaw-zerotier.sh
sudo OPENCLAW_UPSTREAM=127.0.0.1:18789 PROXY_PORT=8080 bash scripts/expose-openclaw-zerotier.sh
sudo ZT_DETECT_RETRIES=5 bash scripts/expose-openclaw-zerotier.sh
```

---

## Networking

* Primary access via ZeroTier private network
* Public exposure should be avoided where possible

Default open ports:

* `22/tcp` — SSH
* `9993/udp` — ZeroTier
* OpenClaw reverse proxy port — ZeroTier interface only, if enabled

Future option:

* Restrict SSH to ZeroTier only

---

## Security Notes

* Change passwords immediately after bootstrap
* Consider SSH key authentication (optional but recommended)
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
* Non-interactive bootstrap flags for fully automated rebuilds
* Automated rebuild workflow
* Optional SSH hardening script

---

## Notes

This setup is intentionally simple. Complexity should only be added when it provides clear value.

---
