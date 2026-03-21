#!/usr/bin/env bash
# =============================================================================
# Pre-teardown safety check + credential cleanup
# =============================================================================
# Run from MacBook: ./scripts/teardown.sh [OPTIONS]
#
# Options:
#   --force           Skip confirmation prompt (for scripted teardown)
#   --backup-db       pg_dump all databases before tearing down
#   --backup-work     Tar and download unsaved work before tearing down
#   --shred           Shred sensitive files instead of rm (slower, more secure)
#   --revoke-ssh-key  Revoke the server-specific GitHub SSH key via gh CLI
#   --hourly-rate N   Hourly rate in EUR for cost estimate (default: 0.0777)
#
# Examples:
#   ./scripts/teardown.sh                          # Interactive
#   ./scripts/teardown.sh --force                  # Scripted, no prompts
#   ./scripts/teardown.sh --backup-db --shred      # Backup DBs, shred creds
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found" >&2
  exit 1
fi
source "$ENV_FILE"

# -------------------------------------------------------------------
# Parse arguments
# -------------------------------------------------------------------
FORCE=false
BACKUP_DB=false
BACKUP_WORK=false
SHRED=false
REVOKE_SSH_KEY=false
HOURLY_RATE="${HOURLY_RATE:-0.0777}"  # Hetzner AX52 default EUR/hr

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)        FORCE=true; shift ;;
    --backup-db)    BACKUP_DB=true; shift ;;
    --backup-work)  BACKUP_WORK=true; shift ;;
    --shred)        SHRED=true; shift ;;
    --revoke-ssh-key) REVOKE_SSH_KEY=true; shift ;;
    --hourly-rate)  HOURLY_RATE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^# ====.*$/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

DEV_USER="${DEV_USER:-dev}"

if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  SERVER="${DEV_USER}@${TAILSCALE_HOSTNAME}"
else
  SERVER="${DEV_USER}@${SERVER_IP:?Set SERVER_IP in .env}"
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Helper: make URLs clickable via OSC 8 hyperlinks (supported by iTerm2, kitty, etc.)
link() {
  local url="$1"
  local text="${2:-$1}"
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$text"
}

echo "============================================"
echo "  SERVER TEARDOWN -- ${SERVER}"
echo "============================================"
echo ""

# -------------------------------------------------------------------
# Phase 1: Pre-flight check (read-only)
# -------------------------------------------------------------------
echo "=== Phase 1: Pre-flight Check ==="
echo ""

ssh "${SERVER}" << 'CHECK'
WARNINGS=0

# Check for uncommitted/unpushed git repos
echo "--- Git Repositories ---"
while IFS= read -r gitdir; do
  repo=$(dirname "$gitdir")
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
  unpushed=$(git -C "$repo" log --oneline --branches --not --remotes 2>/dev/null | wc -l)
  stashes=$(git -C "$repo" stash list 2>/dev/null | wc -l)
  if [ "$dirty" -gt 0 ] || [ "$unpushed" -gt 0 ] || [ "$stashes" -gt 0 ]; then
    echo "WARNING: $repo"
    [ "$dirty" -gt 0 ] && echo "  - $dirty uncommitted changes"
    [ "$unpushed" -gt 0 ] && echo "  - $unpushed unpushed commits"
    [ "$stashes" -gt 0 ] && echo "  - $stashes stashes"
    WARNINGS=$((WARNINGS + 1))
  fi
done < <(find /home /root /opt -name .git -type d 2>/dev/null)
[ "$WARNINGS" -eq 0 ] && echo "OK: No unsaved git state"
echo ""

# Running containers
echo "--- Docker ---"
CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
if [ "$CONTAINERS" -gt 0 ]; then
  echo "INFO: $CONTAINERS running containers"
  docker ps --format "  {{.Names}} ({{.Image}})" 2>/dev/null
fi
VOLUMES=$(docker volume ls -q 2>/dev/null | wc -l)
IMAGES=$(docker images -q 2>/dev/null | wc -l)
echo "INFO: $VOLUMES volumes, $IMAGES images on disk"
DOCKER_DISK=$(docker system df --format '{{.Size}}' 2>/dev/null | paste -sd', ' || echo "unknown")
echo "INFO: Docker disk usage: $DOCKER_DISK"
echo ""

# Background processes
echo "--- Background Processes ---"
BG_WARNINGS=0
if pgrep -f "ollama pull" >/dev/null 2>&1; then
  echo "WARNING: Ollama model pull in progress"
  ps aux | grep "[o]llama pull" | awk '{print "  PID " $2 ": " $11 " " $12}'
  BG_WARNINGS=$((BG_WARNINGS + 1))
fi
if pgrep -f "npm run build\|yarn build\|turbo build\|nx build\|pnpm.*build" >/dev/null 2>&1; then
  echo "WARNING: Build process in progress"
  ps aux | grep -E "[n]pm run build|[y]arn build|[t]urbo build|[n]x build|[p]npm.*build" | awk '{print "  PID " $2 ": " $11 " " $12}'
  BG_WARNINGS=$((BG_WARNINGS + 1))
fi
if pgrep -f "prisma migrate\|prisma db push" >/dev/null 2>&1; then
  echo "WARNING: Prisma migration in progress"
  BG_WARNINGS=$((BG_WARNINGS + 1))
fi
[ "$BG_WARNINGS" -eq 0 ] && echo "OK: No background builds or pulls detected"
echo ""

# Port forwarding / tunnels
echo "--- Active Tunnels & Port Forwards ---"
TUNNEL_WARNINGS=0
if ss -tlnp 2>/dev/null | grep -q "ssh.*LISTEN"; then
  echo "WARNING: SSH tunnels / port forwards active:"
  ss -tlnp 2>/dev/null | grep ssh | awk '{print "  " $4}'
  TUNNEL_WARNINGS=$((TUNNEL_WARNINGS + 1))
fi
if pgrep -f "ngrok\|cloudflared tunnel\|bore\|localhost.run" >/dev/null 2>&1; then
  echo "WARNING: Tunnel process detected:"
  ps aux | grep -E "[n]grok|[c]loudflared tunnel|[b]ore" | awk '{print "  PID " $2 ": " $11 " " $12}'
  TUNNEL_WARNINGS=$((TUNNEL_WARNINGS + 1))
fi
[ "$TUNNEL_WARNINGS" -eq 0 ] && echo "OK: No active tunnels or port forwards"
echo ""

# Crontab entries
echo "--- Crontab ---"
CRON_LINES=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | wc -l)
if [ "$CRON_LINES" -gt 0 ]; then
  echo "WARNING: $CRON_LINES crontab entries will be removed:"
  crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' | sed 's/^/  /'
else
  echo "OK: No crontab entries"
fi
echo ""

# Credentials on disk
echo "--- Credentials ---"
for f in ~/.ssh/id_rsa ~/.ssh/id_ed25519 ~/.git-credentials ~/.config/gh/hosts.yml; do
  [ -f "$f" ] && echo "WARNING: $f still on disk"
done
[ -d ~/.gnupg/private-keys-v1.d ] && echo "WARNING: GPG private keys on disk"
echo ""

# Server uptime
echo "--- Server Uptime ---"
BOOT_TS=$(date -d "$(who -b 2>/dev/null | awk '{print $3, $4}')" +%s 2>/dev/null || stat -c %Z /proc/1 2>/dev/null || echo "")
if [ -n "$BOOT_TS" ]; then
  NOW_TS=$(date +%s)
  UPTIME_SECS=$((NOW_TS - BOOT_TS))
  UPTIME_HOURS=$((UPTIME_SECS / 3600))
  UPTIME_MINS=$(( (UPTIME_SECS % 3600) / 60 ))
  echo "Active for: ${UPTIME_HOURS}h ${UPTIME_MINS}m"
  echo "UPTIME_SECS=${UPTIME_SECS}"
else
  echo "Active for: $(uptime -p)"
fi
echo ""

echo "--- Summary ---"
echo "Review above. If any git work is unsaved, push it now."
CHECK

echo ""

# -------------------------------------------------------------------
# Cost estimate
# -------------------------------------------------------------------
echo -e "${CYAN}--- Cost Estimate ---${NC}"
# Try to extract uptime seconds from the pre-flight output (we re-query for simplicity)
UPTIME_SECS=$(ssh "${SERVER}" 'stat -c %Z /proc/1 2>/dev/null && date +%s' 2>/dev/null | {
  read -r boot_ts
  read -r now_ts
  if [ -n "$boot_ts" ] && [ -n "$now_ts" ]; then
    echo $((now_ts - boot_ts))
  else
    echo ""
  fi
} || echo "")

if [ -n "$UPTIME_SECS" ] && [ "$UPTIME_SECS" -gt 0 ] 2>/dev/null; then
  UPTIME_HOURS_DECIMAL=$(awk "BEGIN {printf \"%.2f\", $UPTIME_SECS / 3600}")
  UPTIME_DISPLAY_H=$((UPTIME_SECS / 3600))
  UPTIME_DISPLAY_M=$(( (UPTIME_SECS % 3600) / 60 ))
  ESTIMATED_COST=$(awk "BEGIN {printf \"%.2f\", $UPTIME_HOURS_DECIMAL * $HOURLY_RATE}")
  echo -e "Server uptime:  ${BOLD}${UPTIME_DISPLAY_H}h ${UPTIME_DISPLAY_M}m${NC}"
  echo -e "Hourly rate:    EUR ${HOURLY_RATE}/hr"
  echo -e "Estimated cost: ${BOLD}EUR ~${ESTIMATED_COST}${NC}"
else
  echo "Could not determine uptime for cost estimate."
fi
echo ""

# -------------------------------------------------------------------
# Confirmation
# -------------------------------------------------------------------
if [ "$FORCE" = false ]; then
  read -p "Continue with cleanup? [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# -------------------------------------------------------------------
# Phase 2: Backups (optional)
# -------------------------------------------------------------------
if [ "$BACKUP_DB" = true ] || [ "$BACKUP_WORK" = true ]; then
  echo ""
  echo "=== Phase 2a: Backups ==="
  BACKUP_DIR="${SCRIPT_DIR}/../backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
fi

if [ "$BACKUP_DB" = true ]; then
  echo ""
  echo ">>> Backing up PostgreSQL databases..."
  # Get list of non-template databases
  DBS=$(ssh "${SERVER}" 'docker exec $(docker ps -q --filter "ancestor=postgres" --filter "ancestor=postgres:*" | head -1) psql -U postgres -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != '\''postgres'\'';" 2>/dev/null || true')
  if [ -z "$DBS" ]; then
    # Fallback: try host-level pg_dump
    DBS=$(ssh "${SERVER}" 'sudo -u postgres psql -At -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != '\''postgres'\'';" 2>/dev/null || true')
  fi
  if [ -n "$DBS" ]; then
    for db in $DBS; do
      echo "  Dumping: $db"
      ssh "${SERVER}" "docker exec \$(docker ps -q --filter 'ancestor=postgres' --filter 'ancestor=postgres:*' | head -1) pg_dump -U postgres '$db' 2>/dev/null || sudo -u postgres pg_dump '$db' 2>/dev/null" \
        | gzip > "${BACKUP_DIR}/${db}.sql.gz" || echo "  WARNING: Failed to dump $db"
    done
    echo -e "${GREEN}Database backups saved to: ${BACKUP_DIR}${NC}"
  else
    echo "  No PostgreSQL databases found to back up."
  fi
fi

if [ "$BACKUP_WORK" = true ]; then
  echo ""
  echo ">>> Backing up unsaved work..."
  # Tar any git repos with dirty state
  ssh "${SERVER}" << 'TARWORK'
DIRTY_REPOS=""
while IFS= read -r gitdir; do
  repo=$(dirname "$gitdir")
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
  unpushed=$(git -C "$repo" log --oneline --branches --not --remotes 2>/dev/null | wc -l)
  stashes=$(git -C "$repo" stash list 2>/dev/null | wc -l)
  if [ "$dirty" -gt 0 ] || [ "$unpushed" -gt 0 ] || [ "$stashes" -gt 0 ]; then
    DIRTY_REPOS="$DIRTY_REPOS $repo"
  fi
done < <(find /home /root /opt -name .git -type d 2>/dev/null)
if [ -n "$DIRTY_REPOS" ]; then
  tar czf /tmp/unsaved-work.tar.gz $DIRTY_REPOS 2>/dev/null
  echo "TARFILE_READY"
else
  echo "NO_DIRTY_REPOS"
fi
TARWORK

  WORK_TAR_STATUS=$(ssh "${SERVER}" 'test -f /tmp/unsaved-work.tar.gz && echo "READY" || echo "NONE"')
  if [ "$WORK_TAR_STATUS" = "READY" ]; then
    scp "${SERVER}:/tmp/unsaved-work.tar.gz" "${BACKUP_DIR}/unsaved-work.tar.gz"
    ssh "${SERVER}" 'rm -f /tmp/unsaved-work.tar.gz'
    echo -e "${GREEN}Work backup saved to: ${BACKUP_DIR}/unsaved-work.tar.gz${NC}"
  else
    echo "  No dirty repos to back up."
  fi
fi

# -------------------------------------------------------------------
# Phase 2b (or 2): Cleanup
# -------------------------------------------------------------------
echo ""
echo "=== Phase 2: Credential & Resource Cleanup ==="

SHRED_FLAG="$SHRED"
ssh "${SERVER}" "SHRED_FLAG=${SHRED_FLAG}" << 'CLEANUP'
REMOVE_CMD="rm -rf"
REMOVE_FILE="rm -f"
if [ "$SHRED_FLAG" = "true" ] && command -v shred &>/dev/null; then
  echo ">>> Using shred for sensitive file removal"
  REMOVE_FILE="shred -vfzu"
  # shred doesn't handle directories; we'll shred files then rm dirs
fi

echo ">>> Stopping Docker containers..."
docker stop $(docker ps -q) 2>/dev/null || true

echo ">>> Removing Docker containers, volumes, and images..."
docker rm $(docker ps -aq) 2>/dev/null || true
docker volume rm $(docker volume ls -q) 2>/dev/null || true
docker system prune -af --volumes 2>/dev/null || true

echo ">>> Cleaning up crontab..."
crontab -r 2>/dev/null || true

echo ">>> Removing credentials..."
if [ "$SHRED_FLAG" = "true" ] && command -v shred &>/dev/null; then
  # Shred individual sensitive files before removing directories
  for f in ~/.ssh/id_rsa ~/.ssh/id_ed25519 ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub \
           ~/.ssh/authorized_keys ~/.git-credentials ~/.config/gh/hosts.yml \
           ~/.bash_history ~/.zsh_history; do
    [ -f "$f" ] && shred -vfzu "$f" 2>/dev/null || true
  done
  # Shred GPG private keys
  find ~/.gnupg/private-keys-v1.d -type f 2>/dev/null | while read -r f; do
    shred -vfzu "$f" 2>/dev/null || true
  done
  # Shred Claude/1Password config files
  find ~/.claude ~/.config/op -type f 2>/dev/null | while read -r f; do
    shred -vfzu "$f" 2>/dev/null || true
  done
  # Remove directories after shredding files
  rm -rf ~/.ssh/id_* ~/.gnupg ~/.config/gh ~/.claude ~/.config/op
else
  rm -rf ~/.ssh/id_* ~/.ssh/authorized_keys
  rm -rf ~/.gnupg
  rm -f ~/.gitconfig
  rm -rf ~/.config/gh
  rm -rf ~/.claude
  rm -rf ~/.config/op
  rm -f ~/.git-credentials
fi

echo ">>> Clearing shell history..."
> ~/.bash_history 2>/dev/null || true
> ~/.zsh_history 2>/dev/null || true
history -c 2>/dev/null || true

echo ">>> Disconnecting Tailscale..."
sudo tailscale logout 2>/dev/null || true

echo ">>> Done"
CLEANUP

# -------------------------------------------------------------------
# Phase 3: Revoke GitHub SSH key (optional)
# -------------------------------------------------------------------
if [ "$REVOKE_SSH_KEY" = true ]; then
  echo ""
  echo "=== Phase 3: Revoking GitHub SSH Key ==="

  # Find the key title matching this server
  KEY_TITLE="${TAILSCALE_HOSTNAME:-devbox}"
  if command -v gh &>/dev/null; then
    KEY_ID=$(gh ssh-key list 2>/dev/null | grep -i "$KEY_TITLE" | awk '{print $NF}' || echo "")
    if [ -n "$KEY_ID" ]; then
      echo ">>> Revoking GitHub SSH key: $KEY_TITLE (ID: $KEY_ID)"
      gh ssh-key delete "$KEY_ID" --yes 2>/dev/null && \
        echo -e "${GREEN}SSH key revoked.${NC}" || \
        echo -e "${YELLOW}Could not revoke SSH key. Do it manually at GitHub.${NC}"
    else
      echo "  No GitHub SSH key found matching '$KEY_TITLE'."
      echo "  Check manually: https://github.com/settings/keys"
    fi
  else
    echo -e "${YELLOW}gh CLI not installed locally. Revoke the key manually:${NC}"
    echo "  $(link 'https://github.com/settings/keys' 'GitHub SSH Keys')"
  fi
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo -e "${GREEN}=== Cleanup Complete ===${NC}"

# Print timing
if [ -n "${UPTIME_SECS:-}" ] && [ "$UPTIME_SECS" -gt 0 ] 2>/dev/null; then
  echo ""
  echo -e "Server was active for ${BOLD}${UPTIME_DISPLAY_H}h ${UPTIME_DISPLAY_M}m${NC}, estimated cost: ${BOLD}EUR ~${ESTIMATED_COST}${NC}"
fi

echo ""
echo "Post-teardown checklist (do these manually):"
echo ""
echo "  1. Cancel server in Hetzner Robot:"
echo "     $(link 'https://robot.hetzner.com' 'https://robot.hetzner.com') -> Servers -> Cancel"
echo ""
echo "  2. Remove Tailscale device:"
echo "     $(link 'https://login.tailscale.com/admin/machines' 'https://login.tailscale.com/admin/machines')"
echo ""
echo "  3. Revoke auth keys:"
echo "     $(link 'https://login.tailscale.com/admin/settings/keys' 'https://login.tailscale.com/admin/settings/keys')"
echo ""
echo "  4. Consider rotating credentials:"
echo "     - gh auth refresh          (GitHub CLI token)"
echo "     - $(link 'https://console.anthropic.com' 'Anthropic console')  (API key, if you want)"
echo ""
echo "  5. Clean local SSH known_hosts:"
echo "     ssh-keygen -R ${SERVER_IP:-unknown}"
echo "     ssh-keygen -R ${TAILSCALE_HOSTNAME:-devbox}"
echo ""
echo "  6. Remove local SSH config entry:"
echo "     Edit ~/.ssh/config and remove the '${TAILSCALE_HOSTNAME:-devbox}' block"
echo ""
if [ "$REVOKE_SSH_KEY" = false ]; then
  echo "  7. Revoke server SSH key from GitHub (if setup-github.sh was used):"
  echo "     $(link 'https://github.com/settings/keys' 'https://github.com/settings/keys')"
  echo ""
fi
