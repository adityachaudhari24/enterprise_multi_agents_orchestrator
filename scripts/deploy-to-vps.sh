#!/usr/bin/env bash
# =============================================================================
# deploy-to-vps.sh — Build OpenClaw image locally and deploy to Hostinger VPS
#
# Usage (set VPS_HOST once in your shell profile, then just run the script):
#   VPS_HOST=root@YOUR_VPS_IP ./scripts/deploy-to-vps.sh
#
# Optional env vars:
#   IMAGE_TAG         — Docker image tag to build (default: openclaw:local)
#   PLATFORM          — Target platform (default: linux/amd64 for Hostinger KVM)
#   VPS_PROJECT_DIR   — Path on VPS where docker-compose.yml lives (default: ~/openclaw)
#   SKIP_BUILD        — Set to 1 to skip build and only transfer existing image
#   LOCAL_WORKSPACE   — Local workspace dir to sync to VPS (default: ~/.openclaw/workspace)
# =============================================================================

set -euo pipefail

# ---------- configuration (override via env vars) ----------------------------
VPS_HOST="${VPS_HOST:-}"
IMAGE_TAG="${IMAGE_TAG:-openclaw:local}"
PLATFORM="${PLATFORM:-linux/amd64}"
VPS_PROJECT_DIR="${VPS_PROJECT_DIR:-~/openclaw}"
COMPOSE_FILE="docker-compose.yml"
SKIP_BUILD="${SKIP_BUILD:-0}"
LOCAL_WORKSPACE="${LOCAL_WORKSPACE:-$HOME/.openclaw/workspace}"

# ---------- colours ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${BOLD}===> $*${NC}"; }

# ---------- banner -----------------------------------------------------------
echo ""
echo -e "${BOLD}========================================"
echo "  OpenClaw — Deploy to Hostinger VPS"
echo -e "========================================${NC}"
echo ""

# ---------- 1. Validate inputs -----------------------------------------------
step "1/7  Validating prerequisites"

if [ -z "$VPS_HOST" ]; then
  fail "VPS_HOST is not set. Usage:\n  VPS_HOST=root@YOUR_VPS_IP ./scripts/deploy-to-vps.sh\n\nTip: add 'export VPS_HOST=root@YOUR_VPS_IP' to ~/.zshrc so you never need to type it."
fi
info "Target VPS: $VPS_HOST"
info "Image tag:  $IMAGE_TAG"
info "Platform:   $PLATFORM"

# Check Docker is available locally
if ! command -v docker &>/dev/null; then
  fail "Docker not found on this machine. Install Docker Desktop and try again."
fi

# Check SSH connectivity (5s timeout so failure is fast)
info "Testing SSH connection to VPS..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$VPS_HOST" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
  fail "Cannot SSH into $VPS_HOST.
  - Make sure your SSH key is added to the VPS (~/.ssh/authorized_keys)
  - Test manually: ssh $VPS_HOST 'echo ok'"
fi
ok "SSH connection works"

# Ensure project dir exists on VPS
ssh "$VPS_HOST" "mkdir -p $VPS_PROJECT_DIR"

# ---------- 2. Build image ---------------------------------------------------
step "2/7  Building Docker image ($PLATFORM)"

if [ "$SKIP_BUILD" = "1" ]; then
  warn "SKIP_BUILD=1 — skipping build, using existing local image: $IMAGE_TAG"
else
  # Check buildx is available (needed for cross-platform builds on M-series Macs)
  if ! docker buildx version &>/dev/null; then
    fail "docker buildx not available. Update Docker Desktop to a recent version."
  fi

  # Ensure a buildx builder exists that can handle the target platform
  BUILDER=$(docker buildx ls | grep -E "linux/amd64" | head -1 | awk '{print $1}' || true)
  if [ -z "$BUILDER" ]; then
    info "Creating a new buildx builder for multi-platform support..."
    docker buildx create --name openclaw-builder --use --bootstrap
  fi

  info "Building image — this takes a few minutes on first run..."
  # --load puts the image into the local Docker daemon (required for docker save)
  docker buildx build \
    --platform "$PLATFORM" \
    --tag "$IMAGE_TAG" \
    --load \
    .
  ok "Image built: $IMAGE_TAG"
fi

# ---------- 3. Transfer image via SSH pipe -----------------------------------
step "3/7  Transferring image to VPS (SSH pipe + gzip)"

IMAGE_SIZE=$(docker image inspect "$IMAGE_TAG" --format='{{.Size}}' 2>/dev/null || echo "unknown")
if [ "$IMAGE_SIZE" != "unknown" ]; then
  IMAGE_SIZE_MB=$(( IMAGE_SIZE / 1024 / 1024 ))
  info "Uncompressed image size: ~${IMAGE_SIZE_MB} MB (gzip will reduce transfer significantly)"
fi

info "Streaming image to $VPS_HOST ... (this is the slow part — ~2-5 min on typical broadband)"
docker save "$IMAGE_TAG" | gzip | ssh "$VPS_HOST" 'gunzip | docker load'
ok "Image loaded on VPS"

# ---------- 4. Sync docker-compose.yml ---------------------------------------
step "4/7  Syncing docker-compose.yml to VPS"

if [ -f "$COMPOSE_FILE" ]; then
  scp "$COMPOSE_FILE" "$VPS_HOST:$VPS_PROJECT_DIR/$COMPOSE_FILE"
  ok "docker-compose.yml synced"
else
  warn "No $COMPOSE_FILE found in current directory — skipping sync"
fi

# ---------- 5. Sync openclaw.json config to VPS ------------------------------
step "5/7  Syncing openclaw.json to VPS"

VPS_CONFIG_DIR=$(ssh "$VPS_HOST" "grep OPENCLAW_CONFIG_DIR $VPS_PROJECT_DIR/.env 2>/dev/null | cut -d= -f2" || echo "/root/openclaw-data/config")
VPS_CONFIG_DIR="${VPS_CONFIG_DIR:-/root/openclaw-data/config}"

ssh "$VPS_HOST" "mkdir -p $VPS_CONFIG_DIR && chown 1000:1000 $VPS_CONFIG_DIR"

if [ -f "gateway-config/openclaw.vps.json" ]; then
  scp gateway-config/openclaw.vps.json "$VPS_HOST:$VPS_CONFIG_DIR/openclaw.json"
  ssh "$VPS_HOST" "chown 1000:1000 $VPS_CONFIG_DIR/openclaw.json"
  ok "openclaw.json synced from gateway-config/openclaw.vps.json"
else
  warn "gateway-config/openclaw.vps.json not found — writing minimal fallback config"
  ssh "$VPS_HOST" "cat > $VPS_CONFIG_DIR/openclaw.json << 'JSONEOF'
{
  \"gateway\": {
    \"mode\": \"local\",
    \"controlUi\": {
      \"dangerouslyAllowHostHeaderOriginFallback\": true
    }
  }
}
JSONEOF
chown 1000:1000 $VPS_CONFIG_DIR/openclaw.json"
fi

# ---------- 6. Sync workspace files (AGENTS.md, SOUL.md, etc.) ---------------
step "6/7  Syncing workspace files to VPS"

LOCAL_WORKSPACE="${LOCAL_WORKSPACE:-$HOME/.openclaw/workspace}"
VPS_WORKSPACE_DIR=$(ssh "$VPS_HOST" "grep OPENCLAW_WORKSPACE_DIR $VPS_PROJECT_DIR/.env 2>/dev/null | cut -d= -f2" || echo "/root/openclaw-data/workspace")
VPS_WORKSPACE_DIR="${VPS_WORKSPACE_DIR:-/root/openclaw-data/workspace}"

if [ -d "$LOCAL_WORKSPACE" ]; then
  info "Syncing $LOCAL_WORKSPACE → VPS:$VPS_WORKSPACE_DIR"
  rsync -avz --exclude='.git/' "$LOCAL_WORKSPACE/" "$VPS_HOST:$VPS_WORKSPACE_DIR/"
  ssh "$VPS_HOST" "chown -R 1000:1000 $VPS_WORKSPACE_DIR/"
  ok "Workspace files synced"
else
  warn "LOCAL_WORKSPACE=$LOCAL_WORKSPACE not found — skipping workspace sync"
  info "Set LOCAL_WORKSPACE=/path/to/your/.openclaw/workspace to enable sync"
fi

# ---------- 7. Restart services on VPS --------------------------------------
step "7/7  Restarting services on VPS"

ssh "$VPS_HOST" "cd $VPS_PROJECT_DIR && docker compose up -d --remove-orphans"
ok "Services started"

# Wait a moment for health check to run
sleep 5

info "Container status:"
ssh "$VPS_HOST" "cd $VPS_PROJECT_DIR && docker compose ps" 2>/dev/null || ssh "$VPS_HOST" "docker ps --filter name=openclaw"

# ---------- done -------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}========================================"
echo "  Deploy complete!"
echo -e "========================================${NC}"
echo ""

# Extract VPS IP from VPS_HOST (strip user@ prefix if present)
VPS_IP="${VPS_HOST##*@}"
echo "  Gateway UI:   http://${VPS_IP}:18789/chat?session=main"
echo "  Health check: curl http://${VPS_IP}:18789/healthz"
echo ""
echo "  Useful commands (run on VPS: ssh $VPS_HOST):"
echo "    docker logs -f \$(docker ps -qf name=openclaw-gateway)"
echo "    docker compose -f $VPS_PROJECT_DIR/docker-compose.yml run --rm openclaw-cli devices list"
echo ""
