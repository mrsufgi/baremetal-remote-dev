#!/usr/bin/env bash
# =============================================================================
# Add an additional developer user to an existing devbox
# =============================================================================
# Run this from your MacBook — it ssh's into the box as root and provisions a
# new non-sudo user with Docker access, isolated workspace on /data, their own
# SSH keypair for git push/sign, and npm global prefix under ~/.npm-global.
#
#   ./scripts/add-dev-user.sh <username> <github_email> "<Full Name>" <path/to/their_mac_pubkey.pub>
#
# Example:
#   ./scripts/add-dev-user.sh alice alice@example.com "Alice Example" ~/alice_key.pub
#
# Pre-reqs:
#   - SERVER_IP in .env points at the devbox
#   - ROOT_PASSWORD in .env (we use 2FA via expect)
#   - /usr/bin/expect is available (ships with macOS)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "  ${CYAN}ℹ${RESET}  $1"; }
success() { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
error()   { echo -e "  ${RED}✖${RESET}  $1"; exit 1; }

# ---------------------------------------------------------------------------
# Args + env
# ---------------------------------------------------------------------------
if [ "$#" -ne 4 ]; then
  cat <<USAGE
Usage: $0 <username> <github_email> "<Full Name>" <path/to/their_mac_pubkey.pub>

The pubkey file is the teammate's *MacBook* SSH public key — the one they'll
use to ssh into the devbox. (A separate server-side key is generated for them
for git push/sign.)
USAGE
  exit 1
fi

NEW_USER="$1"
NEW_EMAIL="$2"
NEW_NAME="$3"
PUBKEY_PATH="$4"

[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || error "Invalid username: $NEW_USER"
[ -f "$PUBKEY_PATH" ] || error "Pubkey file not found: $PUBKEY_PATH"
grep -qE '^(ssh-(ed25519|rsa|ecdsa)|ecdsa-sha2)' "$PUBKEY_PATH" \
  || error "Pubkey file doesn't look like an SSH public key"

[ -f "$ENV_FILE" ] || error ".env not found — run ./run.sh first"
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${ROOT_PASSWORD:?ROOT_PASSWORD must be set in .env (2FA requires password)}"
command -v expect >/dev/null || error "/usr/bin/expect not found"

# Prefer Tailscale hostname (public SSH is firewalled after bootstrap Phase 13).
# Fall back to SERVER_IP only if Tailscale isn't reachable.
SSH_TARGET="${TAILSCALE_HOSTNAME:-${SERVER_IP:-}}"
[ -n "$SSH_TARGET" ] || error "Need TAILSCALE_HOSTNAME or SERVER_IP in .env"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "root@${SSH_TARGET}" true 2>/dev/null; then
  # A BatchMode probe will fail on 2FA (expects password), but we can still detect "host unreachable"
  # Try a plain TCP probe
  if ! nc -z -w 5 "${SSH_TARGET}" 22 2>/dev/null; then
    warn "Cannot reach ${SSH_TARGET}:22 over Tailscale — is your Mac's tailscaled running?"
    warn "(Falling back to SERVER_IP=${SERVER_IP:-unset} — will fail unless public SSH is open.)"
    SSH_TARGET="${SERVER_IP:-$SSH_TARGET}"
  fi
fi

PUBKEY_CONTENT=$(cat "$PUBKEY_PATH")

info "Will add user ${BOLD}${NEW_USER}${RESET} to ${BOLD}${SSH_TARGET}${RESET}"
info "  email:  $NEW_EMAIL"
info "  name:   $NEW_NAME"
info "  pubkey: $PUBKEY_PATH"
echo -en "  ${YELLOW}?${RESET} Proceed? [y/N]: "
read -r answer
[[ "${answer}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Build the provisioning script
# ---------------------------------------------------------------------------
REMOTE_SCRIPT=$(mktemp)
trap 'rm -f "$REMOTE_SCRIPT"' EXIT

cat > "$REMOTE_SCRIPT" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail

NEW_USER="${NEW_USER}"
NEW_EMAIL="${NEW_EMAIL}"
NEW_NAME="${NEW_NAME}"
PUBKEY="${PUBKEY_CONTENT}"

# 'developers' group is created by bootstrap.sh Phase 6 and owns /data/workspace.
# Adding the new user to it gives them shared access to the team's workspace.
groupadd -f developers

if id -u "\$NEW_USER" &>/dev/null; then
  echo "User \$NEW_USER already exists — re-running is idempotent."
  usermod -a -G docker,developers "\$NEW_USER"
else
  # -G docker,developers only — no sudo. They can run devcontainers via the docker group
  # and collaborate on /data/workspace via the developers group.
  # Shell: zsh (oh-my-zsh was installed by bootstrap; new users get a skeleton .zshrc).
  useradd -m -s /bin/zsh -G docker,developers "\$NEW_USER"
  echo "Created user \$NEW_USER (groups: docker, developers)"
fi

# Explicitly NO sudoers entry — keep /etc/sudoers.d/\$NEW_USER absent.
rm -f "/etc/sudoers.d/\$NEW_USER"

# --- SSH access (from their MacBook) ---
install -d -m 700 -o "\$NEW_USER" -g "\$NEW_USER" "/home/\$NEW_USER/.ssh"
echo "\$PUBKEY" > "/home/\$NEW_USER/.ssh/authorized_keys"
chown "\$NEW_USER:\$NEW_USER" "/home/\$NEW_USER/.ssh/authorized_keys"
chmod 600 "/home/\$NEW_USER/.ssh/authorized_keys"

# --- Shared workspace: symlink to /data/workspace (group-owned by 'developers') ---
# All devs collaborate on the same tree. Setgid on /data/workspace + umask 002 from
# /etc/profile.d/developers-umask.sh means new files are group-writable automatically.
if [ ! -L "/home/\$NEW_USER/workspace" ] && [ ! -e "/home/\$NEW_USER/workspace" ]; then
  ln -s /data/workspace "/home/\$NEW_USER/workspace"
  chown -h "\$NEW_USER:\$NEW_USER" "/home/\$NEW_USER/workspace"
fi
# Ensure /data/workspace exists with the right group/mode (harmless if bootstrap already did it)
if [ ! -d /data/workspace ]; then
  mkdir -p /data/workspace
  chgrp developers /data/workspace
  chmod 2775 /data/workspace
fi

# --- Config dirs expected by devcontainers (same as dev user gets from bootstrap) ---
su - "\$NEW_USER" -c 'mkdir -p ~/.config ~/.claude ~/.gnupg && chmod 700 ~/.gnupg && touch ~/.gitconfig'

# --- Their own server-side SSH keypair (for git push + signing) ---
if [ ! -f "/home/\$NEW_USER/.ssh/id_ed25519" ]; then
  su - "\$NEW_USER" -c "ssh-keygen -t ed25519 -C 'devbox-\$(hostname)-\$NEW_USER' -f ~/.ssh/id_ed25519 -N ''"
fi
su - "\$NEW_USER" -c "ssh-keyscan -t rsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null; sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts"

# --- Git identity + SSH commit signing ---
su - "\$NEW_USER" -c "git config --global user.name '\$NEW_NAME'"
su - "\$NEW_USER" -c "git config --global user.email '\$NEW_EMAIL'"
su - "\$NEW_USER" -c "git config --global init.defaultBranch main"
su - "\$NEW_USER" -c "git config --global pull.rebase true"
su - "\$NEW_USER" -c "git config --global push.autoSetupRemote true"
su - "\$NEW_USER" -c "git config --global gpg.format ssh"
su - "\$NEW_USER" -c "git config --global user.signingkey ~/.ssh/id_ed25519.pub"
su - "\$NEW_USER" -c "git config --global commit.gpgsign true"
su - "\$NEW_USER" -c "git config --global tag.gpgsign true"
su - "\$NEW_USER" -c "mkdir -p ~/.config/git && printf '%s %s\n' \"\\\$(git config user.email)\" \"\\\$(cat ~/.ssh/id_ed25519.pub)\" > ~/.config/git/allowed_signers"
su - "\$NEW_USER" -c "git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers"

# --- npm global prefix under their home (avoids the /usr chown landmine) ---
if command -v npm &>/dev/null; then
  su - "\$NEW_USER" -c "mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global"
fi

# NOTE: Don't ACL .ssh / .gnupg / .config to grant UID 1000 access.
# That breaks SSH's StrictModes (it rejects private keys with any non-owner perms,
# and POSIX ACL mask exposes group bits via stat()). Devcontainers must use
# updateRemoteUserUID=true so the in-container vscode UID matches the host user's UID.

# --- User-level limits (match dev user) ---
LIMITS_FILE="/etc/security/limits.d/99-\$NEW_USER.conf"
cat > "\$LIMITS_FILE" <<LIM
\$NEW_USER soft nofile 65536
\$NEW_USER hard nofile 65536
\$NEW_USER soft nproc  65536
\$NEW_USER hard nproc  65536
LIM

echo ""
echo "=== Provisioning summary ==="
id "\$NEW_USER"
echo "Workspace: /home/\$NEW_USER/workspace -> /data/\$NEW_USER/workspace ($(du -sh /data/\$NEW_USER/workspace 2>/dev/null | awk '{print \$1}'))"
echo ""
echo "=== Git config ==="
su - "\$NEW_USER" -c "git config --global --get-regexp '^(user|gpg|commit|tag)\.' | grep -iE 'name|email|format|sign'"
echo ""
echo "=== Public key to register on GitHub (Settings → SSH and GPG keys) ==="
echo "=== Add as BOTH 'Authentication Key' AND 'Signing Key' ==="
echo "-----BEGIN DEVBOX-SIDE PUBKEY-----"
cat "/home/\$NEW_USER/.ssh/id_ed25519.pub"
echo "-----END DEVBOX-SIDE PUBKEY-----"
REMOTE

# ---------------------------------------------------------------------------
# Ship and execute via 2FA root SSH
# ---------------------------------------------------------------------------
info "Provisioning via dev@${SSH_TARGET} + sudo -n (avoids Tailscale SSH check-mode for root)..."
# Pipe the script over stdin to ssh dev@... and execute via passwordless sudo.
# This is robust regardless of Tailscale SSH ACL `check` rules on root.
ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "dev@${SSH_TARGET}" "sudo -n bash -s" < "$REMOTE_SCRIPT" \
  || error "Remote provisioning failed. User was NOT created."

echo ""
success "User ${BOLD}${NEW_USER}${RESET} provisioned on ${SSH_TARGET}."
echo ""
info "Next steps for ${NEW_USER}:"
echo "    1. Add the DEVBOX-SIDE PUBKEY above to github.com/settings/keys"
echo "       (as BOTH 'Authentication Key' and 'Signing Key')"
echo "    2. From their MacBook:"
echo "         ssh ${NEW_USER}@${TAILSCALE_HOSTNAME:-${SERVER_IP}}"
echo "         gh auth login                      # their own account"
echo "    3. Optionally clone a repo into ~/workspace and open in VSCode Remote-SSH"
