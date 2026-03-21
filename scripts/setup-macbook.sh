#!/usr/bin/env bash
# =============================================================================
# MacBook Setup — install everything needed before connecting to remote dev
# =============================================================================
# Run from MacBook: ./scripts/setup-macbook.sh
# Safe to re-run — skips steps that are already done.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\n\033[1;34m[setup]\033[0m %s\n" "$*"; }
ok()    { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
skip()  { printf "  \033[1;33m–\033[0m %s (already installed)\n" "$*"; }
ask()   { printf "\033[1;36m?\033[0m %s " "$*"; }

confirm() {
  ask "$1 [Y/n]"
  read -r answer
  [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
}

# Ensure we're on macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script is for macOS only." >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "  MacBook Setup for Remote Development"
echo "=========================================="
echo ""
echo "This will install and configure everything you need"
echo "to connect to your Hetzner remote dev server."
echo ""

# ---------------------------------------------------------------------------
# 1. Homebrew
# ---------------------------------------------------------------------------
info "Checking Homebrew..."

if command -v brew &>/dev/null; then
  skip "Homebrew"
else
  echo "  Homebrew is not installed."
  if confirm "Install Homebrew?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to path for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  else
    echo "  Skipping Homebrew — some steps below may fail without it."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Tailscale
# ---------------------------------------------------------------------------
info "Checking Tailscale..."

if command -v tailscale &>/dev/null || [[ -d "/Applications/Tailscale.app" ]]; then
  skip "Tailscale"
else
  echo "  Tailscale is not installed."
  echo "  Option 1: brew install --cask tailscale"
  echo "  Option 2: Install from Mac App Store (recommended for auto-updates)"
  echo ""
  if confirm "Install via Homebrew?"; then
    brew install --cask tailscale
    ok "Tailscale installed via Homebrew"
    echo "  Open Tailscale from Applications and sign in."
  else
    echo "  Please install Tailscale from the Mac App Store, then re-run this script."
  fi
fi

# ---------------------------------------------------------------------------
# 3. VS Code CLI
# ---------------------------------------------------------------------------
info "Checking VS Code CLI (code command)..."

if command -v code &>/dev/null; then
  skip "VS Code CLI"
else
  echo "  The 'code' command is not in your PATH."
  echo ""
  echo "  If VS Code is installed, open it and run:"
  echo "    Cmd+Shift+P → 'Shell Command: Install code command in PATH'"
  echo ""
  echo "  If VS Code is NOT installed:"
  if confirm "Install VS Code via Homebrew?"; then
    brew install --cask visual-studio-code
    ok "VS Code installed"
    echo "  Open VS Code, then Cmd+Shift+P → 'Shell Command: Install code command in PATH'"
    echo "  Then re-run this script to install extensions."
  else
    echo "  Install VS Code manually, then re-run this script."
  fi
fi

# ---------------------------------------------------------------------------
# 4. VS Code Extensions
# ---------------------------------------------------------------------------
info "Checking VS Code extensions..."

if command -v code &>/dev/null; then
  INSTALLED_EXTENSIONS=$(code --list-extensions 2>/dev/null || true)

  install_extension() {
    local ext_id="$1"
    local ext_name="$2"
    if echo "$INSTALLED_EXTENSIONS" | grep -qi "$ext_id"; then
      skip "$ext_name"
    else
      code --install-extension "$ext_id" --force
      ok "$ext_name installed"
    fi
  }

  install_extension "ms-vscode-remote.remote-ssh" "Remote - SSH"
  install_extension "ms-vscode-remote.remote-containers" "Dev Containers"
else
  echo "  Skipping — 'code' command not available. Install VS Code first."
fi

# ---------------------------------------------------------------------------
# 5. SSH Key
# ---------------------------------------------------------------------------
info "Checking SSH key..."

SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ -f "$SSH_KEY" ]]; then
  skip "SSH key ($SSH_KEY)"
else
  echo "  No ed25519 SSH key found."
  if confirm "Generate a new SSH key?"; then
    ask "Email for SSH key (used as comment):"
    read -r ssh_email
    ssh_email="${ssh_email:-$(git config user.email 2>/dev/null || echo "dev@local")}"

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -C "$ssh_email" -f "$SSH_KEY"
    ok "SSH key generated at $SSH_KEY"

    # Add to macOS keychain
    ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || ssh-add "$SSH_KEY" 2>/dev/null || true
    ok "SSH key added to agent"
  else
    echo "  Skipping — you'll need an SSH key before connecting to the server."
  fi
fi

# ---------------------------------------------------------------------------
# 6. SSH sockets directory (for multiplexing)
# ---------------------------------------------------------------------------
info "Checking SSH sockets directory..."

SOCKETS_DIR="$HOME/.ssh/sockets"
if [[ -d "$SOCKETS_DIR" ]]; then
  skip "~/.ssh/sockets"
else
  mkdir -p "$SOCKETS_DIR"
  chmod 700 "$SOCKETS_DIR"
  ok "Created ~/.ssh/sockets for connection multiplexing"
fi

# ---------------------------------------------------------------------------
# 7. GPG Key
# ---------------------------------------------------------------------------
info "Checking GPG key..."

if ! command -v gpg &>/dev/null; then
  echo "  gpg not found."
  if confirm "Install GnuPG via Homebrew?"; then
    brew install gnupg
    ok "GnuPG installed"
  else
    echo "  Skipping GPG setup — commit signing won't work without it."
  fi
fi

if command -v gpg &>/dev/null; then
  EXISTING_KEYS=$(gpg --list-secret-keys --keyid-format long 2>/dev/null || true)
  if [[ -n "$EXISTING_KEYS" ]]; then
    skip "GPG key"
    echo ""
    echo "  Existing GPG keys:"
    gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -E "^sec|^uid" || true
  else
    echo "  No GPG secret key found."
    if confirm "Generate a new GPG key for commit signing?"; then
      # Get name and email
      GIT_NAME="$(git config user.name 2>/dev/null || true)"
      GIT_EMAIL="$(git config user.email 2>/dev/null || true)"

      if [[ -z "$GIT_NAME" ]]; then
        ask "Full name for GPG key:"
        read -r GIT_NAME
      else
        echo "  Using git name: $GIT_NAME"
        if ! confirm "Correct?"; then
          ask "Full name for GPG key:"
          read -r GIT_NAME
        fi
      fi

      if [[ -z "$GIT_EMAIL" ]]; then
        ask "Email for GPG key:"
        read -r GIT_EMAIL
      else
        echo "  Using git email: $GIT_EMAIL"
        if ! confirm "Correct?"; then
          ask "Email for GPG key:"
          read -r GIT_EMAIL
        fi
      fi

      # Generate key non-interactively
      gpg --batch --gen-key <<GPGEOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Subkey-Type: ecdh
Subkey-Curve: cv25519
Subkey-Usage: encrypt
Name-Real: ${GIT_NAME}
Name-Email: ${GIT_EMAIL}
Expire-Date: 0
GPGEOF
      ok "GPG key generated"

      # Show the key ID
      GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null \
        | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)
      echo ""
      echo "  Your GPG key ID: $GPG_KEY_ID"
      echo ""
      echo "  To add this key to GitHub, run:"
      echo "    gpg --armor --export $GPG_KEY_ID | pbcopy"
      echo "    Then go to: https://github.com/settings/gpg/new"
    else
      echo "  Skipping — commits won't be signed without a GPG key."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 8. Git global config
# ---------------------------------------------------------------------------
info "Configuring git globals..."

# user.name
CURRENT_NAME="$(git config --global user.name 2>/dev/null || true)"
if [[ -n "$CURRENT_NAME" ]]; then
  skip "git user.name = $CURRENT_NAME"
else
  ask "Git user name:"
  read -r GIT_GLOBAL_NAME
  git config --global user.name "$GIT_GLOBAL_NAME"
  ok "git user.name set"
fi

# user.email
CURRENT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [[ -n "$CURRENT_EMAIL" ]]; then
  skip "git user.email = $CURRENT_EMAIL"
else
  ask "Git user email:"
  read -r GIT_GLOBAL_EMAIL
  git config --global user.email "$GIT_GLOBAL_EMAIL"
  ok "git user.email set"
fi

# commit.gpgsign
CURRENT_SIGN="$(git config --global commit.gpgsign 2>/dev/null || true)"
if [[ "$CURRENT_SIGN" == "true" ]]; then
  skip "git commit.gpgsign = true"
else
  if command -v gpg &>/dev/null && gpg --list-secret-keys 2>/dev/null | grep -q "^sec"; then
    git config --global commit.gpgsign true
    ok "Enabled commit signing (commit.gpgsign = true)"

    # Set gpg.program to the full path
    GPG_PATH="$(command -v gpg)"
    git config --global gpg.program "$GPG_PATH"
    ok "Set gpg.program = $GPG_PATH"

    # Set the signing key
    GPG_KEY_ID="${GPG_KEY_ID:-$(gpg --list-secret-keys --keyid-format long 2>/dev/null \
      | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)}"
    if [[ -n "$GPG_KEY_ID" ]]; then
      git config --global user.signingkey "$GPG_KEY_ID"
      ok "Set user.signingkey = $GPG_KEY_ID"
    fi
  else
    echo "  Skipping commit signing — no GPG key available."
  fi
fi

# ---------------------------------------------------------------------------
# 9. GitHub CLI
# ---------------------------------------------------------------------------
info "Checking GitHub CLI..."

if command -v gh &>/dev/null; then
  skip "GitHub CLI (gh)"
else
  if confirm "Install GitHub CLI (gh) via Homebrew?"; then
    brew install gh
    ok "GitHub CLI installed"
  else
    echo "  Skipping — you'll need gh for auth and PR workflows."
  fi
fi

if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null 2>&1; then
    skip "GitHub CLI auth"
  else
    echo "  GitHub CLI is not authenticated."
    if confirm "Run 'gh auth login' now?"; then
      gh auth login
      ok "GitHub CLI authenticated"
    else
      echo "  Run 'gh auth login' later before using gh commands."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 10. Print SSH public key
# ---------------------------------------------------------------------------
info "Your SSH public key:"

if [[ -f "${SSH_KEY}.pub" ]]; then
  echo ""
  echo "  ┌──────────────────────────────────────────────────────────────┐"
  echo "  │  Copy this key and paste it into Hetzner when ordering      │"
  echo "  │  your server (Add SSH Key step).                            │"
  echo "  └──────────────────────────────────────────────────────────────┘"
  echo ""
  cat "${SSH_KEY}.pub"
  echo ""

  # Copy to clipboard
  if command -v pbcopy &>/dev/null; then
    cat "${SSH_KEY}.pub" | pbcopy
    ok "Public key copied to clipboard"
  fi
else
  echo "  No SSH public key found at ${SSH_KEY}.pub"
  echo "  Generate one by re-running this script."
fi

# ---------------------------------------------------------------------------
# 11. Next steps
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Order your Hetzner server"
echo "     - Paste the SSH public key above during setup"
echo "     - Choose Ubuntu 24.04, CPX31 or higher"
echo ""
echo "  2. Configure this repo"
echo "     - cp .env.example .env"
echo "     - Fill in SERVER_IP, TAILSCALE_AUTH_KEY, etc."
echo ""
echo "  3. Provision the server"
echo "     - ./scripts/provision.sh   (if you have one)"
echo ""
echo "  4. Set up SSH config and connect"
echo "     - ./scripts/connect.sh"
echo "     - ./scripts/setup-devcontainer.sh"
echo ""
echo "  5. Open in VS Code"
echo "     - code --remote ssh-remote+devbox ~/workspace"
echo ""

if command -v gpg &>/dev/null; then
  GPG_KEY_ID="${GPG_KEY_ID:-$(gpg --list-secret-keys --keyid-format long 2>/dev/null \
    | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)}"
  if [[ -n "$GPG_KEY_ID" ]]; then
    echo "  Don't forget to add your GPG key to GitHub:"
    echo "    gpg --armor --export $GPG_KEY_ID | pbcopy"
    echo "    https://github.com/settings/gpg/new"
    echo ""
  fi
fi
