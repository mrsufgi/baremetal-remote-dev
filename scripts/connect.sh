#!/usr/bin/env bash
# =============================================================================
# Generate SSH config for your MacBook and print connection instructions
# =============================================================================
# Run from MacBook: ./scripts/connect.sh
# Appends an entry to ~/.ssh/config (if not already there)
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
HOST_ALIAS="${TAILSCALE_HOSTNAME:-devbox}"

# Create sockets dir for multiplexing
mkdir -p ~/.ssh/sockets
chmod 700 ~/.ssh/sockets

# Check if config already exists
if grep -q "Host ${HOST_ALIAS}$" ~/.ssh/config 2>/dev/null; then
  echo "SSH config for '${HOST_ALIAS}' already exists in ~/.ssh/config"
else
  cat >> ~/.ssh/config << EOF

# Remote dev server (Hetzner via Tailscale)
Host ${HOST_ALIAS}
    HostName ${HOST_ALIAS}
    User ${DEV_USER}
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ForwardAgent yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
    Compression yes
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
    AddressFamily inet
EOF

  # Only add the -direct fallback if SERVER_IP is set
  if [ -n "${SERVER_IP:-}" ]; then
    cat >> ~/.ssh/config << EOF

# Fallback via public IP
Host ${HOST_ALIAS}-direct
    HostName ${SERVER_IP}
    User ${DEV_USER}
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ForwardAgent yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
    Compression yes
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
EOF
  fi

  echo "Added SSH config for '${HOST_ALIAS}' to ~/.ssh/config"
fi

echo ""
echo "=== Connection Methods ==="
echo ""
echo "SSH (terminal):"
echo "  ssh ${HOST_ALIAS}"
echo ""
echo "SSH + tmux (persistent session):"
echo "  ssh ${HOST_ALIAS} -t 'tmux attach-session -t work || tmux new-session -s work'"
echo ""
echo "VS Code Remote SSH:"
echo "  code --remote ssh-remote+${HOST_ALIAS} ~/workspace"
echo ""
echo "VS Code URI (bookmark this):"
echo "  vscode://vscode-remote/ssh-remote+${HOST_ALIAS}/home/${DEV_USER}/workspace"
echo ""
echo "Verify Tailscale direct connection:"
echo "  tailscale ping ${HOST_ALIAS}"
echo ""
echo "Fallback (public IP, if Tailscale is down):"
echo "  ssh ${HOST_ALIAS}-direct"
