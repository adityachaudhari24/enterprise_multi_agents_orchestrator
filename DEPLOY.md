# OpenClaw — Docker Deployment to Hostinger VPS

This is the canonical runbook for building the OpenClaw Docker image locally and deploying it to the Hostinger VPS. The workflow is designed to be run many times.

---

## Architecture Overview

```
Your Mac
  └── docker buildx build --platform linux/amd64
        └── docker save | gzip | ssh VPS_HOST 'gunzip | docker load'
              └── Hostinger VPS (Ubuntu 24.04 KVM 2)
                    ├── ~/openclaw/docker-compose.yml
                    ├── ~/openclaw/.env          (secrets — never committed)
                    ├── ~/openclaw-data/config/  (gateway state — persists across redeploys)
                    └── ~/openclaw-data/workspace/
```

**No Docker registry is used.** The image is piped directly over SSH.

---

## Prerequisites

### On your Mac

| Requirement | How to check | How to install |
|-------------|-------------|----------------|
| Docker Desktop (with buildx) | `docker buildx version` | [docs.docker.com](https://docs.docker.com/desktop/install/mac-install/) |
| SSH key added to VPS | `ssh root@VPS_IP 'echo ok'` | See below |

**Add your SSH key to the VPS** (one-time):
```bash
# Copy your Mac's public key to the VPS
ssh-copy-id root@YOUR_VPS_IP

# Or manually:
cat ~/.ssh/id_ed25519.pub | ssh root@YOUR_VPS_IP 'cat >> ~/.ssh/authorized_keys'
```

**Enable buildx for cross-platform builds** (one-time, needed on M1/M2/M3 Macs):
```bash
docker buildx create --name openclaw-builder --use --bootstrap
```

### On the VPS (Ubuntu 24.04 KVM 2)

| Requirement | Check command | Fix |
|-------------|-------------|-----|
| Docker ≥ 24 | `docker --version` | `curl -fsSL https://get.docker.com \| sh` |
| Docker Compose plugin | `docker compose version` | `apt-get install docker-compose-plugin` |
| Docker daemon running | `systemctl is-active docker` | `systemctl enable --now docker` |
| Port 18789 open | `ufw status` | `ufw allow 18789/tcp && ufw reload` |
| ≥ 3 GB free disk | `df -h /` | `docker system prune -af` to free space |

---

## One-Time VPS Setup

Run this **once** to create the required directories and a `.env` template on the VPS.

```bash
# From your Mac — pipes the setup script into the VPS over SSH
ssh root@YOUR_VPS_IP 'bash -s' < scripts/vps-setup.sh
```

The script will:
- Create `~/openclaw/` (project dir: holds docker-compose.yml + .env)
- Create `~/openclaw-data/config/` and `~/openclaw-data/workspace/` (volume dirs)
- Set ownership to uid 1000 (the container's `node` user — required for write access)
- Open UFW port 18789
- Write a `.env` template at `~/openclaw/.env`

### Fill in your secrets on the VPS

```bash
ssh root@YOUR_VPS_IP
nano ~/openclaw/.env
```

Fill in these **required** values:

| Variable | What it is | How to get it |
|----------|-----------|---------------|
| `OPENCLAW_GATEWAY_TOKEN` | Auth token for agents to connect | `openssl rand -hex 32` |
| `ANTHROPIC_API_KEY` | Anthropic API key | [console.anthropic.com](https://console.anthropic.com) |
| `OPENCLAW_CONFIG_DIR` | Host path for config volume | `/root/openclaw-data/config` |
| `OPENCLAW_WORKSPACE_DIR` | Host path for workspace volume | `/root/openclaw-data/workspace` |

See [Environment Variables Reference](#environment-variables-reference) for the full list.

---

## Pulling Upstream Updates (openclaw/openclaw)

When the upstream openclaw repo releases new features or fixes, sync them into your fork:

```bash
# 1. Fetch latest upstream changes (no merging yet)
git fetch upstream

# 2. Merge into your dev branch
git checkout dev
git merge upstream/main
# Resolve any conflicts if prompted, then commit

# 3. Test locally
docker compose build && docker compose up -d
# Open: http://127.0.0.1:18789/chat?session=main

# 4. Promote to main when satisfied
git checkout main
git merge dev
git push origin main

# 5. Deploy to VPS
VPS_HOST=root@153.92.211.148 ./scripts/deploy-to-vps.sh
```

### Branch strategy

| Branch | Purpose |
|--------|---------|
| `dev` | Active development, personal changes, upstream merges |
| `main` | Stable, deploy-ready — always deploy from here |

**Always be on `main` when running `deploy-to-vps.sh`.** The script builds whatever is in your local working tree.

---

## Repeating Deploys (Normal Flow)

Every time you make changes and want to deploy:

```bash
# Set once in your shell profile (~/.zshrc or ~/.bashrc) — never type it again
export VPS_HOST=root@YOUR_VPS_IP

# Build image, pipe to VPS, restart services — one command
./scripts/deploy-to-vps.sh
```

### What the script does

| Step | What happens |
|------|-------------|
| Validate | Checks VPS_HOST is set and SSH works |
| Build | `docker buildx build --platform linux/amd64 -t openclaw:local --load .` |
| Transfer | `docker save \| gzip \| ssh VPS docker load` (~2–5 min on typical broadband) |
| Sync compose | Copies `docker-compose.yml` to `~/openclaw/` on VPS |
| Restart | `docker compose up -d --remove-orphans` on VPS |
| Status | Shows `docker compose ps` output |

### Optional flags

```bash
# Skip the build step (re-deploy the existing local image without rebuilding)
SKIP_BUILD=1 ./scripts/deploy-to-vps.sh

# Use a different image tag
IMAGE_TAG=openclaw:v2 ./scripts/deploy-to-vps.sh

# Override VPS project directory
VPS_PROJECT_DIR=/opt/openclaw ./scripts/deploy-to-vps.sh
```

---

## Editing VPS Settings (Models, Heartbeat, Tools)

Gateway settings — agent models, heartbeat schedule, tools profile, session config — live in:

```
gateway-config/openclaw.vps.json   ← edit this file in the repo
```

This file is tracked in git and synced to the VPS on every `deploy-to-vps.sh` run. It is **safe to commit** — it contains no secrets (the gateway auth token comes from `OPENCLAW_GATEWAY_TOKEN` in `.env`).

### Common edits

**Change primary model:**
```json
"agents": { "defaults": { "model": { "primary": "anthropic/claude-sonnet-4-6" } } }
```

**Change heartbeat frequency:**
```json
"heartbeat": { "every": "2h" }
```

**Change tools profile** (`coding`, `minimal`, `default`):
```json
"tools": { "profile": "minimal" }
```

After editing, redeploy:
```bash
./scripts/deploy-to-vps.sh
```

### Workspace files (AGENTS.md, SOUL.md, etc.)

Your local `~/.openclaw/workspace/` files are automatically synced to the VPS on every deploy:

```
~/.openclaw/workspace/   →   VPS:/root/openclaw-data/workspace/
```

To sync a different local workspace directory:
```bash
LOCAL_WORKSPACE=/path/to/workspace ./scripts/deploy-to-vps.sh
```

---

## Environment Variables Reference

The `.env` file lives at `~/openclaw/.env` on the VPS. Docker Compose reads it automatically.

### Required

| Variable | Description |
|----------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | Auth token. Generate: `openssl rand -hex 32`. Anyone with this can connect as an agent. |
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude models. |
| `OPENCLAW_CONFIG_DIR` | Absolute path on VPS host for config volume → `/root/openclaw-data/config` |
| `OPENCLAW_WORKSPACE_DIR` | Absolute path on VPS host for workspace volume → `/root/openclaw-data/workspace` |

### Optional — commonly used

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENCLAW_GATEWAY_BIND` | Network bind mode. Use `lan` to expose on all interfaces (required for VPS). | `lan` |
| `OPENCLAW_TZ` | Timezone (TZ database name, e.g. `Asia/Kolkata`) | `UTC` |
| `OPENCLAW_GATEWAY_PORT` | Host port for the gateway | `18789` |
| `OPENCLAW_BRIDGE_PORT` | Host port for the bridge | `18790` |
| `OPENCLAW_IMAGE` | Docker image tag to run | `openclaw:local` |
| `OPENAI_API_KEY` | OpenAI API key (if using GPT models) | — |

### Optional — channels

| Variable | Description |
|----------|-------------|
| `TELEGRAM_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token (raw token only — no `DISCORD_BOT_TOKEN=` prefix) |
| `CLAUDE_AI_SESSION_KEY` | Claude.ai web session key |
| `CLAUDE_WEB_SESSION_KEY` | Claude web session key |
| `CLAUDE_WEB_COOKIE` | Claude web cookie |

---

## Day-to-Day Commands (on VPS)

SSH in first: `ssh root@YOUR_VPS_IP` then `cd ~/openclaw`

```bash
# Tail live gateway logs
docker logs -f $(docker ps -qf name=openclaw-gateway)

# List devices waiting for approval
docker compose run --rm openclaw-cli devices list

# Approve a device pairing request
docker compose run --rm openclaw-cli devices approve REQUEST_ID_HERE

# Restart gateway only (without full redeploy)
docker compose restart openclaw-gateway

# Full stop and start
docker compose down && docker compose up -d

# Shell into the running gateway container
docker exec -it $(docker ps -qf name=openclaw-gateway) bash

# Health checks inside container
docker exec -it $(docker ps -qf name=openclaw-gateway) bash -c "openclaw gateway status"
docker exec -it $(docker ps -qf name=openclaw-gateway) bash -c "openclaw security audit"

# Quick health check from VPS (no SSH into container needed)
docker compose ps
curl http://localhost:18789/healthz

# Free up disk space (safe — only removes unused images/containers)
docker system prune -f
```

**Gateway UI** (open in browser):
```
http://YOUR_VPS_IP:18789/chat?session=main
```

---

## Volume Persistence

| Host path (VPS) | Container path | What's stored |
|-----------------|---------------|---------------|
| `~/openclaw-data/config/` | `/home/node/.openclaw` | Gateway config, paired devices, sessions, agent settings |
| `~/openclaw-data/workspace/` | `/home/node/.openclaw/workspace` | Workspace files used by agents |

These directories persist across redeploys. When you run `deploy-to-vps.sh`, the running container is replaced but the data directories are untouched — devices stay paired, sessions are preserved.

---

## Troubleshooting

### "exec format error" on VPS
The image was built for the wrong architecture. Always build with:
```bash
docker buildx build --platform linux/amd64 ...
```
Re-run `./scripts/deploy-to-vps.sh` — the script does this automatically.

### Port 18789 not reachable from browser
Check in order:
```bash
# 1. Is the container running?
ssh root@VPS docker compose -f ~/openclaw/docker-compose.yml ps

# 2. Is the port open in UFW?
ssh root@VPS 'ufw status | grep 18789'
# Fix: ssh root@VPS 'ufw allow 18789/tcp && ufw reload'

# 3. Is the gateway bound to 0.0.0.0 (not just 127.0.0.1)?
ssh root@VPS 'ss -ltnp | grep 18789'
# Fix: ensure OPENCLAW_GATEWAY_BIND=lan in ~/openclaw/.env

# 4. Check Hostinger panel — some plans have a separate firewall in the control panel
```

### Container keeps restarting
```bash
# Check logs for the actual error
ssh root@VPS 'docker logs $(docker ps -aqf name=openclaw-gateway) --tail 50'
# Common causes: missing required env var (ANTHROPIC_API_KEY, OPENCLAW_GATEWAY_TOKEN)
```

### SSH pipe transfer is very slow
The gzip compression already reduces transfer by ~60%. For faster transfers:
```bash
# Use zstd compression (faster than gzip, better ratio)
docker save openclaw:local | zstd | ssh root@VPS_IP 'zstd -d | docker load'
# Requires: brew install zstd (Mac) and apt-get install zstd (VPS)
```

### "Permission denied" errors in container logs
The config/workspace dirs on the VPS have wrong ownership. Fix:
```bash
ssh root@VPS_IP 'chown -R 1000:1000 ~/openclaw-data'
docker compose -f ~/openclaw/docker-compose.yml restart openclaw-gateway
```

### Need to rebuild the builder (buildx issues on Mac)
```bash
docker buildx rm openclaw-builder
docker buildx create --name openclaw-builder --use --bootstrap
```

---

## Quick Reference Card

```
# FIRST TIME: setup VPS
ssh root@VPS_IP 'bash -s' < scripts/vps-setup.sh
ssh root@VPS_IP 'nano ~/openclaw/.env'   # fill in GATEWAY_TOKEN + API keys

# EVERY DEPLOY: one command
export VPS_HOST=root@VPS_IP              # set once in ~/.zshrc
./scripts/deploy-to-vps.sh

# CHECK STATUS (on VPS)
ssh root@VPS_IP 'docker compose -f ~/openclaw/docker-compose.yml ps'
curl http://VPS_IP:18789/healthz

# GATEWAY UI
http://VPS_IP:18789/chat?session=main

# APPROVE DEVICE (on VPS)
ssh root@VPS_IP
cd ~/openclaw
docker compose run --rm openclaw-cli devices list
docker compose run --rm openclaw-cli devices approve REQUEST_ID
```
