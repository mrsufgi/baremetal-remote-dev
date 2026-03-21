#!/usr/bin/env bash
# =============================================================================
# Clone repo and start the devcontainer on the remote server
# =============================================================================
# Run from MacBook: ./scripts/setup-devcontainer.sh
# This SSHes into the server and runs everything there.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env" >&2
  exit 1
fi
source "$ENV_FILE"

DEV_USER="${DEV_USER:-dev}"
REPO_URL="${REPO_URL:?Set REPO_URL in .env}"
BRANCH="${BRANCH:-main}"

if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  SERVER="${DEV_USER}@${TAILSCALE_HOSTNAME}"
else
  SERVER="${DEV_USER}@${SERVER_IP:?Set SERVER_IP in .env}"
fi

# Maximum retries for devcontainer build (network flakes are common on first try)
MAX_RETRIES="${MAX_RETRIES:-2}"

# --- Helper: run a command on the remote server via SSH ---
# Uses a script passed via stdin to avoid heredoc variable interpolation issues.
# All variables are passed explicitly as environment vars via SendEnv/AcceptEnv
# or injected at the top of the script.
remote_exec() {
  local description="$1"
  shift
  echo "[setup] ==> ${description}"
  # Pass the script as an argument to bash -s, with variables injected at top
  ssh -A -o LogLevel=ERROR "${SERVER}" "bash -s" <<< "$@"
}

# =============================================================================
# Phase 0: Verify remote prerequisites (Docker running, user in docker group)
# =============================================================================
echo "[setup] ==> Verifying remote prerequisites on ${SERVER}..."
ssh -A -o LogLevel=ERROR "${SERVER}" 'bash -s' << 'PREREQ'
set -euo pipefail

# Check Docker daemon is running
if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not running or current user cannot access it." >&2
  echo "" >&2
  echo "Fixes to try:" >&2
  echo "  sudo systemctl start docker" >&2
  echo "  sudo usermod -aG docker $(whoami) && newgrp docker" >&2
  exit 1
fi
echo "  Docker: OK ($(docker --version | head -1))"

# Check user is in docker group (avoid sudo requirement)
if ! groups | grep -qw docker; then
  echo "WARNING: User '$(whoami)' is not in the 'docker' group." >&2
  echo "  Docker commands may require sudo. Fix with:" >&2
  echo "  sudo usermod -aG docker $(whoami) && newgrp docker" >&2
fi

# Verify devcontainer bind mount prerequisites
# These HOST paths must exist before devcontainer up or Docker will fail
for dir in ~/.config ~/.ssh ~/.gnupg; do
  if [ ! -d "$dir" ]; then
    echo "  Creating missing directory: $dir"
    mkdir -p "$dir"
    chmod 700 "$dir"
  fi
done
if [ ! -f ~/.gitconfig ]; then
  echo "  Creating missing file: ~/.gitconfig"
  touch ~/.gitconfig
fi
echo "  Bind mount paths: OK"

echo "  Prerequisites: OK"
PREREQ

# =============================================================================
# Phase 1: Install devcontainer CLI (if needed) — no nodesource, use proto/npm
# =============================================================================
echo "[setup] ==> Installing devcontainer CLI (if needed)..."
ssh -A -o LogLevel=ERROR "${SERVER}" 'bash -s' << 'INSTALL_CLI'
set -euo pipefail

if command -v devcontainer &>/dev/null; then
  echo "  devcontainer CLI: already installed ($(devcontainer --version 2>/dev/null || echo 'unknown'))"
  exit 0
fi

echo "  devcontainer CLI: not found, installing..."

# Strategy: use whatever Node/npm is already available via proto, nvm, or system.
# Do NOT install Node from nodesource — it conflicts with proto/nvm.
if command -v npm &>/dev/null; then
  echo "  Using npm at: $(command -v npm)"
  npm install -g @devcontainers/cli
elif command -v proto &>/dev/null; then
  echo "  Installing Node via proto..."
  proto install node lts
  proto install npm
  # Ensure proto shims are on PATH for this session
  export PATH="$HOME/.proto/shims:$HOME/.proto/bin:$PATH"
  npm install -g @devcontainers/cli
elif [ -d "$HOME/.nvm" ]; then
  echo "  Loading nvm and installing Node..."
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
  npm install -g @devcontainers/cli
else
  echo "ERROR: No Node.js runtime found (npm, proto, or nvm)." >&2
  echo "  Install proto: curl -fsSL https://moonrepo.dev/install/proto.sh | bash" >&2
  echo "  Then:          proto install node lts && proto install npm" >&2
  exit 1
fi

echo "  devcontainer CLI: installed ($(devcontainer --version 2>/dev/null || echo 'ok'))"
INSTALL_CLI

# =============================================================================
# Phase 2: Clone or update repo, handle branch
# =============================================================================
echo "[setup] ==> Setting up repository..."
# Use a regular heredoc with explicit variable injection at the top
ssh -A -o LogLevel=ERROR "${SERVER}" "bash -s" << CLONE_REPO
set -euo pipefail

REPO_URL="${REPO_URL}"
BRANCH="${BRANCH}"
WORKSPACE="\$HOME/workspace"

if [ -d "\$WORKSPACE/.git" ]; then
  cd "\$WORKSPACE"
  CURRENT_BRANCH=\$(git rev-parse --abbrev-ref HEAD)

  if [ "\$CURRENT_BRANCH" != "\$BRANCH" ]; then
    echo "  Repo exists on branch '\$CURRENT_BRANCH', switching to '\$BRANCH'..."
    # Fetch first so we have the remote branch
    git fetch origin "\$BRANCH" 2>/dev/null || git fetch origin
    # Stash any local changes before switching
    git stash --include-untracked 2>/dev/null || true
    git checkout "\$BRANCH" 2>/dev/null || git checkout -b "\$BRANCH" "origin/\$BRANCH"
    echo "  Switched to '\$BRANCH'"
  fi

  echo "  Pulling latest..."
  git pull --ff-only 2>/dev/null || echo "  Pull failed (diverged?) — using existing state"
else
  echo "  Cloning \$REPO_URL (branch: \$BRANCH)..."
  git clone --branch "\$BRANCH" "\$REPO_URL" "\$WORKSPACE"
  cd "\$WORKSPACE"
fi

echo "  Repo: OK (branch: \$(git rev-parse --abbrev-ref HEAD), commit: \$(git rev-parse --short HEAD))"
CLONE_REPO

# =============================================================================
# Phase 3: Pre-pull Docker images in parallel (speeds up devcontainer build)
# =============================================================================
echo "[setup] ==> Pre-pulling Docker images in parallel (background)..."
ssh -A -o LogLevel=ERROR "${SERVER}" 'bash -s' << 'PREPULL'
set -euo pipefail

WORKSPACE="$HOME/workspace"

# Extract image names from docker-compose.yml (only lines with 'image:')
COMPOSE_FILE="$WORKSPACE/.devcontainer/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "  No docker-compose.yml found, skipping pre-pull"
  exit 0
fi

# Source the .env for variable substitution in image tags
if [ -f "$WORKSPACE/.devcontainer/.env" ]; then
  set -a
  source "$WORKSPACE/.devcontainer/.env"
  set +a
fi

# Pull images that are specified directly (not built from Dockerfile)
IMAGES=$(grep -E '^\s+image:' "$COMPOSE_FILE" | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" || true)

if [ -z "$IMAGES" ]; then
  echo "  No images to pre-pull"
  exit 0
fi

# Substitute env vars in image names using envsubst
RESOLVED_IMAGES=$(echo "$IMAGES" | envsubst || echo "$IMAGES")

echo "  Pulling $(echo "$RESOLVED_IMAGES" | wc -l) images in parallel..."

PIDS=()
for img in $RESOLVED_IMAGES; do
  # Skip images with unresolved variables
  if echo "$img" | grep -q '${'; then
    echo "  SKIP: $img (unresolved variable)"
    continue
  fi
  echo "  Pulling: $img"
  docker pull "$img" &>/dev/null &
  PIDS+=($!)
done

# Wait for all pulls — don't fail if some images can't be pulled
FAILED=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid" 2>/dev/null; then
    ((FAILED++))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo "  Warning: $FAILED image(s) failed to pre-pull (will be pulled during build)"
else
  echo "  All images pre-pulled successfully"
fi
PREPULL

# =============================================================================
# Phase 4: Prepare host dirs and .env.local
# =============================================================================
echo "[setup] ==> Preparing host directories and environment..."
# Inject variables that need interpolation; quote the rest
ssh -A -o LogLevel=ERROR "${SERVER}" "bash -s" << PREPARE
set -euo pipefail

WORKSPACE="\$HOME/workspace"

# Create required host dirs for devcontainer bind mounts
mkdir -p ~/.config ~/.ssh ~/.gnupg
touch ~/.gitconfig 2>/dev/null || true

# Build .env.local for the devcontainer
ENV_LOCAL="\$WORKSPACE/.devcontainer/.env.local"
: > "\$ENV_LOCAL"  # truncate or create

# Stripe key (for webhook forwarding)
STRIPE_KEY="${STRIPE_SECRET_KEY:-}"
if [ -n "\$STRIPE_KEY" ]; then
  echo "STRIPE_SECRET_KEY=\$STRIPE_KEY" >> "\$ENV_LOCAL"
  echo "  Added STRIPE_SECRET_KEY to .env.local"
fi

# Ollama host — devcontainer reaches host Ollama via host.docker.internal
# (extra_hosts: host.docker.internal:host-gateway is in docker-compose.yml)
echo "OLLAMA_HOST=http://host.docker.internal:11434" >> "\$ENV_LOCAL"
echo "  Added OLLAMA_HOST=http://host.docker.internal:11434 to .env.local"

echo "  Host directories: OK"
PREPARE

# =============================================================================
# Phase 5: Build and start the devcontainer (with retry + streamed output)
# =============================================================================
echo "[setup] ==> Building devcontainer (first run takes ~10-15 min)..."
echo "           Build output is streamed below."
echo "           ----------------------------------------"

ATTEMPT=0
BUILD_SUCCESS=false

while [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; do
  ATTEMPT=$((ATTEMPT + 1))

  if [ "$ATTEMPT" -gt 1 ]; then
    echo ""
    echo "[setup] ==> Retry $ATTEMPT/$MAX_RETRIES (waiting 5s for network settle)..."
    sleep 5
  fi

  # Stream build output directly to terminal (no heredoc — single command)
  # The -t flag allocates a pseudo-TTY so we get real-time output
  if ssh -A -o LogLevel=ERROR "${SERVER}" \
    "cd \$HOME/workspace && devcontainer up --workspace-folder \$HOME/workspace 2>&1"; then
    BUILD_SUCCESS=true
    break
  else
    echo ""
    echo "[setup] !!! Build attempt $ATTEMPT failed."
    if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
      echo "           Will retry (common causes: network timeout, image pull failure)."
    fi
  fi
done

echo "           ----------------------------------------"

if [ "$BUILD_SUCCESS" = false ]; then
  echo ""
  echo "[setup] ERROR: Devcontainer build failed after $MAX_RETRIES attempts." >&2
  echo "  Troubleshoot:" >&2
  echo "    ssh ${SERVER}" >&2
  echo "    cd ~/workspace && devcontainer up --workspace-folder ~/workspace" >&2
  exit 1
fi

# =============================================================================
# Phase 6: Verify host.docker.internal resolution inside the container
# =============================================================================
echo "[setup] ==> Verifying container networking..."
ssh -A -o LogLevel=ERROR "${SERVER}" 'bash -s' << 'VERIFY'
set -euo pipefail

WORKSPACE="$HOME/workspace"

# Check that host.docker.internal resolves inside the container
if devcontainer exec --workspace-folder "$WORKSPACE" \
  getent hosts host.docker.internal &>/dev/null; then
  echo "  host.docker.internal: OK"
else
  echo "  WARNING: host.docker.internal does not resolve inside the container."
  echo "  Ollama and other host services may not be reachable."
  echo "  Verify extra_hosts in .devcontainer/docker-compose.yml"
fi
VERIFY

# =============================================================================
# Done
# =============================================================================
CONNECT_HOST="${TAILSCALE_HOSTNAME:-${SERVER_IP:-localhost}}"

echo ""
echo "[setup] ==> Devcontainer is running!"
echo ""
echo "  Connect with VS Code:"
echo "    code --remote ssh-remote+${CONNECT_HOST} ~/workspace"
echo ""
echo "  Or attach directly:"
echo "    ssh ${SERVER} 'devcontainer exec --workspace-folder ~/workspace /bin/zsh'"
echo ""
echo "  Ollama (from inside container):"
echo "    curl http://host.docker.internal:11434/api/tags"
echo ""
