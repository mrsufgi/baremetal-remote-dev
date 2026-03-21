#!/usr/bin/env bash
# =============================================================================
# Set up GitHub access on the remote server with a server-specific SSH key
# =============================================================================
# Run from MacBook: ./scripts/setup-github.sh
#
# Replaces SSH agent forwarding with a dedicated deploy key on the server.
# Cleaner and more secure for a temp dev server.
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
KEY_COMMENT="hetzner-devbox-temp"

# Use Tailscale hostname if available, fall back to IP
if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  SERVER="${DEV_USER}@${TAILSCALE_HOSTNAME}"
else
  SERVER="${DEV_USER}@${SERVER_IP:?Set SERVER_IP in .env}"
fi

log() { echo "[github] $*"; }

# -------------------------------------------------------------------
# 1. Read local git identity (or prompt)
# -------------------------------------------------------------------
GIT_NAME="${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || true)}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"

if [ -z "$GIT_NAME" ]; then
  read -rp "Git user.name: " GIT_NAME
fi
if [ -z "$GIT_EMAIL" ]; then
  read -rp "Git user.email: " GIT_EMAIL
fi

log "=== Setting up GitHub access on ${SERVER} ==="
log "Git identity: ${GIT_NAME} <${GIT_EMAIL}>"

# -------------------------------------------------------------------
# 2. Generate server-specific SSH key (if not already present)
# -------------------------------------------------------------------
log ">>> Generating server SSH key (ed25519)"
PUB_KEY=$(ssh "${SERVER}" bash -s -- "$KEY_COMMENT" << 'KEYGEN'
KEY_FILE="$HOME/.ssh/id_ed25519_github"
COMMENT="$1"

if [ -f "$KEY_FILE" ]; then
  echo "KEY_EXISTS" >&2
else
  ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_FILE" -N "" >&2
  echo "KEY_CREATED" >&2
fi

cat "${KEY_FILE}.pub"
KEYGEN
)

log "Server public key:"
echo ""
echo "  ${PUB_KEY}"
echo ""

# -------------------------------------------------------------------
# 3. Configure SSH config on the server for GitHub
# -------------------------------------------------------------------
log ">>> Configuring server ~/.ssh/config for GitHub"
ssh "${SERVER}" bash -s << 'SSHCONFIG'
CONFIG="$HOME/.ssh/config"
KEY_FILE="$HOME/.ssh/id_ed25519_github"

# Remove any existing GitHub block and rewrite it
if grep -q "Host github.com" "$CONFIG" 2>/dev/null; then
  # Use sed to remove the existing GitHub block (Host github.com until next Host or EOF)
  sed -i '/^Host github\.com$/,/^Host /{/^Host github\.com$/d;/^Host /!d}' "$CONFIG" 2>/dev/null || true
  # Clean approach: just remove lines with github.com reference and rewrite
  grep -v "github\.com" "$CONFIG" > "${CONFIG}.tmp" 2>/dev/null || true
  mv "${CONFIG}.tmp" "$CONFIG"
fi

cat >> "$CONFIG" << EOF

Host github.com
    HostName github.com
    User git
    IdentityFile ${KEY_FILE}
    IdentitiesOnly yes
EOF

chmod 600 "$CONFIG"
SSHCONFIG

# -------------------------------------------------------------------
# 4. Add key to GitHub (via gh CLI or manual instructions)
# -------------------------------------------------------------------
log ">>> Adding SSH key to GitHub"

# Try gh CLI on the server first
KEY_ADDED=false
if ssh "${SERVER}" "command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1"; then
  log "Found authenticated gh CLI on server — adding SSH key"
  if ssh "${SERVER}" "gh ssh-key add ~/.ssh/id_ed25519_github.pub --title '${KEY_COMMENT}' 2>&1"; then
    KEY_ADDED=true
    log "SSH key added to GitHub via server gh CLI"
  else
    log "WARNING: gh ssh-key add failed on server (key may already exist)"
    KEY_ADDED=true  # Likely already added
  fi
fi

# Try gh CLI locally if server didn't work
if [ "$KEY_ADDED" = false ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  log "Found authenticated gh CLI locally — adding SSH key"
  if echo "${PUB_KEY}" | gh ssh-key add --title "${KEY_COMMENT}" 2>&1; then
    KEY_ADDED=true
    log "SSH key added to GitHub via local gh CLI"
  else
    log "WARNING: gh ssh-key add failed locally (key may already exist)"
    KEY_ADDED=true  # Likely already added
  fi
fi

if [ "$KEY_ADDED" = false ]; then
  echo ""
  echo "================================================================"
  echo "  MANUAL STEP REQUIRED: Add the SSH key to GitHub"
  echo "================================================================"
  echo ""
  echo "  1. Copy this public key:"
  echo ""
  echo "     ${PUB_KEY}"
  echo ""
  echo "  2. Go to: https://github.com/settings/ssh/new"
  echo "  3. Title: ${KEY_COMMENT}"
  echo "  4. Key type: Authentication Key"
  echo "  5. Paste the key and click 'Add SSH key'"
  echo ""
  echo "  Press Enter after adding the key..."
  read -r
fi

# -------------------------------------------------------------------
# 5. Configure git identity on the server
# -------------------------------------------------------------------
log ">>> Configuring git identity on server"
ssh "${SERVER}" bash -s -- "$GIT_NAME" "$GIT_EMAIL" << 'GITCONFIG'
git config --global user.name "$1"
git config --global user.email "$2"
GITCONFIG

# -------------------------------------------------------------------
# 6. Configure GPG signing (if keys are present on the server)
# -------------------------------------------------------------------
log ">>> Checking GPG signing setup"
ssh "${SERVER}" bash -s -- "$GIT_EMAIL" << 'GPGSETUP'
EMAIL="$1"

# Check if any secret keys exist
if gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -q "sec"; then
  # Find key ID matching the git email
  KEY_ID=$(gpg --list-secret-keys --keyid-format long "$EMAIL" 2>/dev/null \
    | grep -oP '(?<=sec\s{3})[A-Za-z0-9]+/\K[A-F0-9]+' | head -1)

  if [ -z "$KEY_ID" ]; then
    # Try broader match
    KEY_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null \
      | grep -oP '[A-F0-9]{16}' | head -1)
  fi

  if [ -n "$KEY_ID" ]; then
    git config --global user.signingkey "$KEY_ID"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    git config --global gpg.program "$(command -v gpg)"
    echo "[github] GPG signing configured with key: $KEY_ID"
  else
    echo "[github] GPG keys found but none match ${EMAIL} — skipping signing config"
  fi
else
  echo "[github] No GPG secret keys on server — signing disabled"
  git config --global commit.gpgsign false 2>/dev/null || true
fi
GPGSETUP

# -------------------------------------------------------------------
# 7. Disable SSH agent forwarding in connect.sh config
# -------------------------------------------------------------------
log ">>> Updating SSH config (disabling ForwardAgent for security)"
if [ -f ~/.ssh/config ]; then
  HOST_ALIAS="${TAILSCALE_HOSTNAME:-devbox}"
  # Just note it — don't modify the user's config without asking
  if grep -A 5 "Host ${HOST_ALIAS}$" ~/.ssh/config 2>/dev/null | grep -q "ForwardAgent yes"; then
    log "NOTE: Your ~/.ssh/config still has 'ForwardAgent yes' for ${HOST_ALIAS}."
    log "      Since the server now has its own key, you can change it to 'ForwardAgent no'."
  fi
fi

# -------------------------------------------------------------------
# 8. Test GitHub SSH access
# -------------------------------------------------------------------
log ">>> Testing GitHub SSH access from server"
echo ""
ssh "${SERVER}" "ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true"
echo ""

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
log ""
log "=== GitHub setup complete ==="
log ""
log "Server key:     ~/.ssh/id_ed25519_github (${KEY_COMMENT})"
log "Git identity:   ${GIT_NAME} <${GIT_EMAIL}>"
log ""
log "To remove the key when tearing down the server:"
log "  gh ssh-key list                    # find the key ID"
log "  gh ssh-key delete <ID>             # remove it"
log ""
log "Or visit: https://github.com/settings/keys"
