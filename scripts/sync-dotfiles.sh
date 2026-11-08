#!/usr/bin/env bash
# =============================================================================
# Sync dotfiles and credentials from MacBook to remote server
# =============================================================================
# Run from your MacBook: ./scripts/sync-dotfiles.sh
#
# Zero-to-hero: handles the case where SSH keys, GPG keys, git config, and
# gh CLI auth don't exist yet.
#
# Flags:
#   --generate    Create all missing credentials locally before syncing
#   --dry-run     Show what would be synced without doing it
#   --help        Show usage
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# --- Flags -------------------------------------------------------------------
GENERATE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --generate) GENERATE=true ;;
    --dry-run)  DRY_RUN=true ;;
    --help|-h)
      echo "Usage: $0 [--generate] [--dry-run]"
      echo ""
      echo "  --generate   Create missing SSH keys, GPG keys, git config, gh auth locally"
      echo "  --dry-run    Show what would happen without making changes"
      echo ""
      echo "Requires .env with SERVER_IP or TAILSCALE_HOSTNAME set."
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg (use --help)" >&2
      exit 1
      ;;
  esac
done

# --- Helpers -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[sync]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Track what we synced for the summary
declare -a SYNCED=()
declare -a SKIPPED=()
declare -a GENERATED=()

# --- Load .env ---------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  err ".env not found at ${ENV_FILE}"
  echo "  Run: cp .env.example .env && vim .env" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

DEV_USER="${DEV_USER:-dev}"

# =============================================================================
# PHASE 1: Local credential generation (--generate)
# =============================================================================

generate_ssh_key() {
  if [ -f ~/.ssh/id_ed25519 ]; then
    log "SSH key already exists: ~/.ssh/id_ed25519"
    return 0
  fi

  if [ "$GENERATE" = false ]; then
    warn "No SSH key found at ~/.ssh/id_ed25519"
    warn "  Run with --generate to create one, or create manually:"
    warn "  ssh-keygen -t ed25519 -C \"your-email@example.com\""
    SKIPPED+=("SSH key (not found, use --generate)")
    return 1
  fi

  log "Generating SSH key..."
  local email
  email=$(git config --global user.email 2>/dev/null || true)
  if [ -z "$email" ]; then
    read -rp "Email for SSH key comment: " email
  fi

  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -t ed25519 -C "$email" -f ~/.ssh/id_ed25519
  GENERATED+=("SSH key: ~/.ssh/id_ed25519")

  echo ""
  log "Add this public key to GitHub: https://github.com/settings/ssh/new"
  echo ""
  cat ~/.ssh/id_ed25519.pub
  echo ""
  read -rp "Press Enter after adding the key to GitHub (or Ctrl-C to abort)..."
}

generate_gpg_key() {
  local has_keys
  has_keys=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -c '^sec' || true)
  if [ "$has_keys" -gt 0 ]; then
    log "GPG secret key(s) already exist"
    return 0
  fi

  if [ "$GENERATE" = false ]; then
    warn "No GPG secret keys found"
    warn "  Run with --generate to create one, or create manually:"
    warn "  gpg --full-generate-key"
    SKIPPED+=("GPG key (not found, use --generate)")
    return 1
  fi

  log "Generating GPG key..."
  local name email
  name=$(git config --global user.name 2>/dev/null || true)
  email=$(git config --global user.email 2>/dev/null || true)

  if [ -z "$name" ]; then
    read -rp "Full name for GPG key: " name
  fi
  if [ -z "$email" ]; then
    read -rp "Email for GPG key: " email
  fi

  # Generate key non-interactively with sane defaults
  gpg --batch --gen-key <<GPGEOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: ecdh
Subkey-Curve: cv25519
Name-Real: ${name}
Name-Email: ${email}
Expire-Date: 2y
%commit
GPGEOF

  local key_id
  key_id=$(gpg --list-secret-keys --keyid-format long 2>/dev/null \
    | grep '^sec' | head -1 | sed 's/.*\/\([A-F0-9]*\).*/\1/')

  GENERATED+=("GPG key: ${key_id}")

  echo ""
  log "Add this GPG key to GitHub: https://github.com/settings/gpg/new"
  echo ""
  gpg --armor --export "$key_id"
  echo ""
  read -rp "Press Enter after adding the key to GitHub (or Ctrl-C to abort)..."

  # Configure git to use the new key
  git config --global user.signingkey "$key_id"
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  log "Git configured to sign commits with ${key_id}"
}

generate_gitconfig() {
  if [ -f ~/.gitconfig ]; then
    log "Git config already exists: ~/.gitconfig"
    return 0
  fi

  if [ "$GENERATE" = false ]; then
    warn "No ~/.gitconfig found"
    warn "  Run with --generate to create one, or configure manually:"
    warn "  git config --global user.name \"Your Name\""
    warn "  git config --global user.email \"you@example.com\""
    SKIPPED+=("Git config (not found, use --generate)")
    return 1
  fi

  log "Creating ~/.gitconfig..."
  local name email
  read -rp "Full name for git: " name
  read -rp "Email for git: " email

  git config --global user.name "$name"
  git config --global user.email "$email"
  git config --global init.defaultBranch main
  git config --global pull.rebase true

  GENERATED+=("Git config: ~/.gitconfig")
  log "Created ~/.gitconfig for ${name} <${email}>"
}

ensure_gh_auth() {
  if gh auth status &>/dev/null; then
    log "GitHub CLI already authenticated"
    return 0
  fi

  if [ "$GENERATE" = false ]; then
    warn "GitHub CLI (gh) not authenticated"
    warn "  Run with --generate to authenticate, or manually: gh auth login"
    SKIPPED+=("gh CLI auth (not authenticated, use --generate)")
    return 1
  fi

  log "Authenticating GitHub CLI..."
  echo "  Select: GitHub.com > HTTPS > Login with a web browser"
  echo ""
  gh auth login
  GENERATED+=("gh CLI auth")
}

# Run local generation checks
log "=== Phase 1: Checking local credentials ==="
echo ""

# SSH key is required for everything else; bail if missing and not generating
ssh_ok=true
generate_ssh_key || ssh_ok=false

generate_gpg_key || true
generate_gitconfig || true
ensure_gh_auth || true

if [ "$ssh_ok" = false ]; then
  err "Cannot sync without an SSH key. Run with --generate or create one manually."
  exit 1
fi

if [ ! -f ~/.gitconfig ]; then
  err "Cannot sync without ~/.gitconfig. Run with --generate or create one manually."
  exit 1
fi

echo ""

# =============================================================================
# PHASE 2: Connect to server
# =============================================================================

# Build server address
if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  SERVER="${DEV_USER}@${TAILSCALE_HOSTNAME}"
elif [ -n "${SERVER_IP:-}" ]; then
  SERVER="${DEV_USER}@${SERVER_IP}"
else
  err "Neither TAILSCALE_HOSTNAME nor SERVER_IP is set in .env"
  exit 1
fi

log "=== Phase 2: Syncing to ${SERVER} ==="
echo ""

# --- Quick Tailscale reachability check (non-blocking) -----------------------
if [ -n "${TAILSCALE_HOSTNAME:-}" ] && command -v tailscale &>/dev/null; then
  if ! tailscale ping --timeout=3s "${TAILSCALE_HOSTNAME}" &>/dev/null 2>&1; then
    warn "Tailscale ping to '${TAILSCALE_HOSTNAME}' failed."
    warn "  Ensure Tailscale is connected: tailscale status"
    warn "  Falling back to SSH connectivity test..."
  fi
fi

# --- Test connectivity -------------------------------------------------------
test_server_connection() {
  log "Testing connection to ${SERVER}..."

  # Accept host key on first connection (common for new servers)
  local ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

  # shellcheck disable=SC2086
  if ! ssh $ssh_opts "${SERVER}" "echo ok" &>/dev/null; then
    err "Cannot reach ${SERVER}"
    echo "" >&2
    echo "  Possible causes:" >&2
    echo "    1. Tailscale not connected: tailscale status" >&2
    echo "    2. Server not running: check cloud console" >&2
    echo "    3. Wrong IP/hostname: check .env" >&2
    echo "    4. SSH key not authorized: ssh-copy-id ${SERVER}" >&2
    if [ -n "${TAILSCALE_HOSTNAME:-}" ] && [ -n "${SERVER_IP:-}" ]; then
      echo "" >&2
      echo "  Tailscale hostname failed. Trying SERVER_IP fallback (${SERVER_IP})..." >&2
      SERVER="${DEV_USER}@${SERVER_IP}"
      # shellcheck disable=SC2086
      if ssh $ssh_opts "${SERVER}" "echo ok" &>/dev/null; then
        warn "Tailscale unreachable but SERVER_IP works. Using ${SERVER}"
        return 0
      fi
      err "SERVER_IP fallback also failed."
    fi
    exit 1
  fi
  log "Connection OK"
}

if [ "$DRY_RUN" = true ]; then
  log "(dry-run) Would connect to ${SERVER}"
else
  test_server_connection
fi

# SSH options used for all remote commands — accept new host keys automatically
SSH_OPTS="-o StrictHostKeyChecking=accept-new"

# Wrappers that add error context
run_rsync() {
  local label="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    log "(dry-run) Would rsync: ${label}"
    SYNCED+=("${label} (dry-run)")
    return 0
  fi
  # macOS bundled rsync (2.x) does not support --chmod; strip it and fix
  # permissions via a post-sync SSH command instead.
  local args=() chmod_spec="" remote_path=""
  for arg in "$@"; do
    if [[ "$arg" == --chmod=* ]]; then
      chmod_spec="${arg#--chmod=}"
    else
      args+=("$arg")
      # Track the last argument as the remote path (rsync convention: last arg is dest)
      remote_path="$arg"
    fi
  done

  if rsync "${args[@]}" 2>/tmp/sync-dotfiles-rsync-err; then
    # Apply permissions via SSH if --chmod was requested
    if [ -n "$chmod_spec" ] && [ -n "$remote_path" ]; then
      local remote_host="${remote_path%%:*}"
      local remote_dir="${remote_path#*:}"
      # Parse D### and F### from chmod spec (e.g. D700,F600)
      local dir_mode file_mode
      dir_mode=$(echo "$chmod_spec" | grep -oE 'D[0-9]+' | tr -d 'D')
      file_mode=$(echo "$chmod_spec" | grep -oE 'F[0-9]+' | tr -d 'F')
      # shellcheck disable=SC2086
      ssh $SSH_OPTS "$remote_host" "
        [ -n '${dir_mode}' ] && find ${remote_dir} -type d -exec chmod ${dir_mode} {} + 2>/dev/null
        [ -n '${file_mode}' ] && find ${remote_dir} -type f -exec chmod ${file_mode} {} + 2>/dev/null
      " || true
    fi
    SYNCED+=("$label")
  else
    local rc=$?
    err "rsync failed for ${label} (exit ${rc}):"
    cat /tmp/sync-dotfiles-rsync-err >&2
    echo "  Hint: check SSH agent (ssh-add -l), disk space, and permissions." >&2
    SKIPPED+=("${label} (rsync failed)")
    return "$rc"
  fi
}

run_ssh() {
  local label="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    log "(dry-run) Would run on remote: ${label}"
    return 0
  fi
  # shellcheck disable=SC2086
  if ! ssh $SSH_OPTS "${SERVER}" "$@"; then
    local rc=$?
    err "Remote command failed for ${label} (exit ${rc})"
    SKIPPED+=("${label} (ssh command failed)")
    return "$rc"
  fi
}

run_scp() {
  local label="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    log "(dry-run) Would scp: ${label}"
    SYNCED+=("${label} (dry-run)")
    return 0
  fi
  if scp -q "$@" 2>/tmp/sync-dotfiles-scp-err; then
    SYNCED+=("$label")
  else
    local rc=$?
    err "scp failed for ${label} (exit ${rc}):"
    cat /tmp/sync-dotfiles-scp-err >&2
    SKIPPED+=("${label} (scp failed)")
    return "$rc"
  fi
}

# =============================================================================
# PHASE 3: Sync credentials to server
# =============================================================================

log "=== Phase 3: Syncing credentials ==="
echo ""

# -------------------------------------------------------------------
# 1. SSH -- public keys and config only (use agent forwarding for private keys)
# -------------------------------------------------------------------
log ">>> SSH config + public keys (NO private keys)"
run_rsync "SSH public keys + config" \
  -avz -e "ssh ${SSH_OPTS}" --chmod=D700,F600 \
  --include='config' \
  --include='*.pub' \
  --include='allowed_signers' \
  --exclude='*' \
  ~/.ssh/ "${SERVER}:~/.ssh/" || true

# -------------------------------------------------------------------
# 2. GPG -- export and import with error checking
# -------------------------------------------------------------------
log ">>> GPG keys (export/import)"
GPG_KEY_COUNT=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -c '^sec' || true)
if [ "$GPG_KEY_COUNT" -gt 0 ]; then
  if [ "$DRY_RUN" = true ]; then
    log "(dry-run) Would export ${GPG_KEY_COUNT} GPG key(s) to remote"
    SYNCED+=("GPG keys (dry-run)")
  else
    # Export secret keys with error checking on both sides of the pipe
    gpg_export_tmp=$(mktemp)
    trust_export_tmp=$(mktemp)
    trap 'rm -f "$gpg_export_tmp" "$trust_export_tmp"' EXIT

    if ! gpg --export-secret-keys --armor > "$gpg_export_tmp" 2>/dev/null; then
      err "GPG secret key export failed locally"
      SKIPPED+=("GPG keys (local export failed)")
    elif [ ! -s "$gpg_export_tmp" ]; then
      err "GPG export produced empty output"
      SKIPPED+=("GPG keys (empty export)")
    else
      # Transfer and import as separate steps for better error visibility
      if scp -q "$gpg_export_tmp" "${SERVER}:/tmp/.gpg-import-$$"; then
        # shellcheck disable=SC2086
        import_output=$(ssh $SSH_OPTS "${SERVER}" "gpg --import /tmp/.gpg-import-$$ 2>&1; rm -f /tmp/.gpg-import-$$")
        import_rc=$?
        if [ $import_rc -ne 0 ]; then
          err "GPG key import failed on remote (exit ${import_rc}):"
          echo "  ${import_output}" >&2
          SKIPPED+=("GPG keys (remote import failed)")
        else
          SYNCED+=("GPG secret keys (${GPG_KEY_COUNT} key(s))")
          log "GPG keys imported: ${import_output}"
        fi
      else
        err "Failed to transfer GPG keys to remote"
        SKIPPED+=("GPG keys (scp failed)")
      fi
    fi

    # Ownertrust -- same pattern
    if gpg --export-ownertrust > "$trust_export_tmp" 2>/dev/null && [ -s "$trust_export_tmp" ]; then
      if scp -q "$trust_export_tmp" "${SERVER}:/tmp/.gpg-trust-$$"; then
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "${SERVER}" "gpg --import-ownertrust /tmp/.gpg-trust-$$ 2>/dev/null; rm -f /tmp/.gpg-trust-$$"
        SYNCED+=("GPG ownertrust")
      fi
    fi

    rm -f "$gpg_export_tmp" "$trust_export_tmp"
    trap - EXIT
  fi
else
  warn "No GPG secret keys found locally, skipping"
  SKIPPED+=("GPG keys (none found locally)")
fi

# -------------------------------------------------------------------
# 3. Git config -- copy and patch for Linux
# -------------------------------------------------------------------
log ">>> Git config"
run_scp "Git config (~/.gitconfig)" ~/.gitconfig "${SERVER}:~/.gitconfig" || true

if [ "$DRY_RUN" = false ]; then
  run_ssh "Git config Linux patches" << 'PATCH'
# Fix macOS-specific settings for Linux
git config --global --unset credential.helper 2>/dev/null || true
git config --global credential.helper cache
command -v gpg >/dev/null && git config --global gpg.program "$(command -v gpg)"
PATCH
fi

# -------------------------------------------------------------------
# 4. GitHub CLI auth
# -------------------------------------------------------------------
if [ -f ~/.config/gh/hosts.yml ]; then
  log ">>> GitHub CLI auth"
  run_ssh "Create ~/.config/gh" "mkdir -p ~/.config/gh" || true
  run_rsync "gh CLI config" \
    -avz -e "ssh ${SSH_OPTS}" --chmod=D700,F600 \
    ~/.config/gh/ "${SERVER}:~/.config/gh/" || true
else
  warn "No gh CLI auth found locally. Run 'gh auth login' on the remote after connecting."
  SKIPPED+=("gh CLI auth (no local config)")
fi

# -------------------------------------------------------------------
# 5. Claude Code -- settings and plugins only
# -------------------------------------------------------------------
if [ -d ~/.claude ]; then
  log ">>> Claude Code config (settings + plugins)"
  run_ssh "Create ~/.claude" "mkdir -p ~/.claude" || true
  run_rsync "Claude Code config" \
    -avz -e "ssh ${SSH_OPTS}" --chmod=D700,F600 \
    --exclude='statsig/' \
    --exclude='*.log' \
    --exclude='logs/' \
    --exclude='worktrees/' \
    ~/.claude/ "${SERVER}:~/.claude/" || true
else
  SKIPPED+=("Claude Code config (no ~/.claude directory)")
fi

# -------------------------------------------------------------------
# 6. Set ANTHROPIC_API_KEY if provided
# -------------------------------------------------------------------
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  log ">>> Setting ANTHROPIC_API_KEY"
  if [ "$DRY_RUN" = false ]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SERVER}" "grep -q ANTHROPIC_API_KEY ~/.zshrc 2>/dev/null || echo 'export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"' >> ~/.zshrc"
    SYNCED+=("ANTHROPIC_API_KEY in ~/.zshrc")
  else
    SYNCED+=("ANTHROPIC_API_KEY (dry-run)")
  fi
else
  SKIPPED+=("ANTHROPIC_API_KEY (not set in .env)")
fi

# -------------------------------------------------------------------
# 7. Server config files (zshrc, tmux.conf from configs/)
# -------------------------------------------------------------------
CONFIGS_DIR="${SCRIPT_DIR}/../configs"

if [ -f "${CONFIGS_DIR}/zshrc" ]; then
  log ">>> Custom zshrc"
  run_scp "Custom zshrc (configs/zshrc)" "${CONFIGS_DIR}/zshrc" "${SERVER}:~/.zshrc" || true
else
  SKIPPED+=("Custom zshrc (configs/zshrc not found)")
fi

if [ -f "${CONFIGS_DIR}/tmux.conf" ]; then
  log ">>> Custom tmux.conf"
  run_scp "Custom tmux.conf (configs/tmux.conf)" "${CONFIGS_DIR}/tmux.conf" "${SERVER}:~/.tmux.conf" || true
else
  SKIPPED+=("Custom tmux.conf (configs/tmux.conf not found)")
fi

# -------------------------------------------------------------------
# 8. Fix ownership
# -------------------------------------------------------------------
if [ "$DRY_RUN" = false ]; then
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "${SERVER}" "sudo chown -R ${DEV_USER}:${DEV_USER} ~ 2>/dev/null || true"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}=== Sync Summary ===${NC}"
echo ""

if [ ${#GENERATED[@]} -gt 0 ]; then
  echo -e "${GREEN}Generated locally:${NC}"
  for item in "${GENERATED[@]}"; do
    echo "  + ${item}"
  done
  echo ""
fi

if [ ${#SYNCED[@]} -gt 0 ]; then
  echo -e "${GREEN}Synced to ${SERVER}:${NC}"
  for item in "${SYNCED[@]}"; do
    echo "  -> ${item}"
  done
  echo ""
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo -e "${YELLOW}Skipped:${NC}"
  for item in "${SKIPPED[@]}"; do
    echo "  -- ${item}"
  done
  echo ""
fi

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}(dry-run mode -- no changes were made)${NC}"
  echo ""
fi

echo -e "${BOLD}Verify on remote:${NC}"
echo "  ssh ${SERVER}"
echo "  ssh -T git@github.com        # GitHub access"
echo "  gpg --list-secret-keys       # GPG keys"
echo "  gh auth status               # GitHub CLI"
echo ""
