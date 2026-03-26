#!/usr/bin/env bash
# =============================================================================
# vps-setup.sh — One-time setup for OpenClaw on Hostinger VPS (Ubuntu 24.04)
#
# Run this from your Mac:
#   ssh root@YOUR_VPS_IP 'bash -s' < scripts/vps-setup.sh
#
# Or copy to VPS and run directly:
#   scp scripts/vps-setup.sh root@YOUR_VPS_IP:~/vps-setup.sh
#   ssh root@YOUR_VPS_IP 'bash ~/vps-setup.sh'
# =============================================================================

set -euo pipefail

# ---------- colours ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo ""
echo "========================================"
echo "  OpenClaw VPS First-Time Setup"
echo "  Ubuntu 24.04 / Hostinger KVM 2"
echo "========================================"
echo ""

# ---------- 1. Check Docker --------------------------------------------------
info "Checking Docker..."
if ! command -v docker &>/dev/null; then
  fail "Docker not found. Install it first:
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker"
fi
DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
ok "Docker found: $DOCKER_VER"

# Check Compose plugin (v2)
if ! docker compose version &>/dev/null; then
  warn "Docker Compose plugin not found. Installing..."
  apt-get update -qq && apt-get install -y -qq docker-compose-plugin
fi
COMPOSE_VER=$(docker compose version --short)
ok "Docker Compose plugin: $COMPOSE_VER"

# ---------- 2. Check Docker daemon is running --------------------------------
if ! systemctl is-active --quiet docker; then
  info "Starting Docker daemon..."
  systemctl enable --now docker
fi
ok "Docker daemon is active"

# ---------- 3. Create project directories ------------------------------------
PROJECT_DIR="${HOME}/openclaw"
CONFIG_DIR="${HOME}/openclaw-data/config"
WORKSPACE_DIR="${HOME}/openclaw-data/workspace"

info "Creating project directory: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"

info "Creating config volume dir: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

info "Creating workspace volume dir: $WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR"

# The container runs as 'node' user (uid 1000). Fix ownership so it can write.
info "Setting ownership to uid:gid 1000:1000 (container 'node' user)..."
chown -R 1000:1000 "${HOME}/openclaw-data"
ok "Directories created and ownership set"

# ---------- 4. Open firewall port 18789 --------------------------------------
info "Checking UFW firewall for port 18789..."
if command -v ufw &>/dev/null; then
  if ufw status | grep -q "18789"; then
    ok "Port 18789 already allowed in UFW"
  else
    ufw allow 18789/tcp
    ok "Port 18789 opened in UFW"
  fi
else
  warn "UFW not found — make sure port 18789 is open in your Hostinger panel firewall"
fi

# ---------- 5. Check disk space ----------------------------------------------
info "Checking available disk space..."
AVAIL_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "$AVAIL_GB" -lt 3 ]; then
  warn "Only ${AVAIL_GB}GB free on /. Recommended: at least 3GB for Docker image (~1.5GB)."
else
  ok "Disk space: ${AVAIL_GB}GB free on /"
fi

# ---------- 6. Write openclaw.json config ------------------------------------
OPENCLAW_JSON="$CONFIG_DIR/openclaw.json"
if [ -f "$OPENCLAW_JSON" ]; then
  warn "openclaw.json already exists at $OPENCLAW_JSON — skipping"
else
  info "Creating openclaw.json config..."
  cat > "$OPENCLAW_JSON" <<'JSONEOF'
{
  "gateway": {
    "mode": "local",
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
JSONEOF
  chown 1000:1000 "$OPENCLAW_JSON"
  ok "openclaw.json created"
fi

# ---------- 7. Print .env template ------------------------------------------
ENV_FILE="$PROJECT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  warn ".env already exists at $ENV_FILE — skipping template creation"
else
  info "Creating .env template at $ENV_FILE ..."
  cat > "$ENV_FILE" <<'ENVEOF'
# =============================================================================
# OpenClaw Gateway — Environment Variables
# This file lives ONLY on the VPS. Never commit it to git.
# =============================================================================

# --- Required ----------------------------------------------------------------

# Gateway auth token — anyone with this token can connect as an agent.
# Generate a fresh one: openssl rand -hex 32
OPENCLAW_GATEWAY_TOKEN=REPLACE_ME_openssl_rand_hex_32

# Anthropic API key (get from console.anthropic.com)
ANTHROPIC_API_KEY=REPLACE_ME

# Host paths that get mounted into the container as volumes
OPENCLAW_CONFIG_DIR=/root/openclaw-data/config
OPENCLAW_WORKSPACE_DIR=/root/openclaw-data/workspace

# --- Optional ----------------------------------------------------------------

# Bind mode: 'lan' exposes on all interfaces (needed for VPS access)
OPENCLAW_GATEWAY_BIND=lan

# Timezone (TZ database name, e.g. Asia/Kolkata, America/New_York, UTC)
OPENCLAW_TZ=UTC

# OpenAI API key (if you want GPT models too)
OPENAI_API_KEY=

# Claude web session (for claude.ai web provider — not needed for API)
CLAUDE_AI_SESSION_KEY=
CLAUDE_WEB_SESSION_KEY=
CLAUDE_WEB_COOKIE=

# Telegram bot token (if using Telegram channel)
# TELEGRAM_TOKEN=

# Discord bot token (if using Discord channel)
# DISCORD_BOT_TOKEN=

# Gateway port mapping (change only if 18789 conflicts with another service)
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790

# Docker image tag (default: openclaw:local — matches what deploy script loads)
OPENCLAW_IMAGE=openclaw:local
ENVEOF
  ok ".env template created at $ENV_FILE"
fi

# ---------- 7. Summary -------------------------------------------------------
echo ""
echo "========================================"
echo -e "  ${GREEN}Setup complete!${NC}"
echo "========================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Fill in your secrets in: $ENV_FILE"
echo "     nano $ENV_FILE"
echo ""
echo "     Required fields:"
echo "       OPENCLAW_GATEWAY_TOKEN  (generate: openssl rand -hex 32)"
echo "       ANTHROPIC_API_KEY"
echo ""
echo "  2. From your Mac, run the deploy script to build & push the image:"
echo "     VPS_HOST=root@YOUR_VPS_IP ./scripts/deploy-to-vps.sh"
echo ""
echo "  3. Gateway UI (once deployed):"
echo "     http://YOUR_VPS_IP:18789/chat?session=main"
echo ""
