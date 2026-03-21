#!/usr/bin/env bash
# =============================================================================
# Bare Metal Dev Server Bootstrap
# =============================================================================
# Run on a fresh Hetzner server (Ubuntu 24.04) as root:
#   ssh root@SERVER_IP 'bash -s' < bootstrap.sh
#
# Or with env vars:
#   ssh root@SERVER_IP 'TAILSCALE_AUTHKEY=tskey-auth-xxx bash -s' < bootstrap.sh
#
# This script is idempotent — safe to re-run.
# Supports resuming from a specific phase: RESUME_FROM=8 bash bootstrap.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars)
# ---------------------------------------------------------------------------
DEV_USER="${DEV_USER:-dev}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-devbox}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-$TAILSCALE_HOSTNAME}"
OLLAMA_MODELS="${OLLAMA_MODELS:-}"
DATA_DISK="${DATA_DISK:-}"
DATA_MOUNT="${DATA_MOUNT:-/data}"
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
TIMEZONE="${TIMEZONE:-UTC}"
RESUME_FROM="${RESUME_FROM:-0}"

# ---------------------------------------------------------------------------
# Logging & error handling
# ---------------------------------------------------------------------------
PHASE_FILE="/var/tmp/bootstrap-phase"

log()  { echo "[bootstrap] $(date '+%H:%M:%S') $*" >&2; }
warn() { echo "[bootstrap] $(date '+%H:%M:%S') WARNING: $*" >&2; }
die()  { echo "[bootstrap] $(date '+%H:%M:%S') FATAL: $*" >&2; exit 1; }

# Write completed phase to disk so a re-run can skip past it
mark_phase() { echo "$1" > "$PHASE_FILE"; }

should_run() {
  local phase="$1"
  [[ "$phase" -ge "$RESUME_FROM" ]]
}

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    local completed
    completed=$(cat "$PHASE_FILE" 2>/dev/null || echo "0")
    warn "Bootstrap FAILED (exit $exit_code) after completing phase $completed"
    warn "To resume: RESUME_FROM=$((completed + 1)) bash bootstrap.sh"
  fi
  # Reap any background jobs
  jobs -p | xargs -r kill 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

log "=== Bare Metal Dev Server Bootstrap ==="
log "Resume from: phase $RESUME_FROM"

# ---------------------------------------------------------------------------
# Phase 1: System packages
# ---------------------------------------------------------------------------
if should_run 1; then
  log ">>> Phase 1: System packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq \
    curl wget git jq unzip htop tmux vim nano \
    build-essential ca-certificates gnupg lsb-release \
    zsh fzf ripgrep fd-find bat \
    openssh-server fail2ban ufw \
    unattended-upgrades \
    lm-sensors smartmontools nvme-cli \
    postgresql-client \
    mosh \
    locales

  # Symlink bat -> batcat (Ubuntu ships it as batcat to avoid name collision)
  if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
    ln -sf "$(command -v batcat)" /usr/local/bin/bat
  fi

  mark_phase 1
fi

# ---------------------------------------------------------------------------
# Phase 2: Hostname, timezone, locale
# ---------------------------------------------------------------------------
if should_run 2; then
  log ">>> Phase 2: Hostname, timezone, locale"

  # Hostname
  if [[ "$(hostname)" != "$SERVER_HOSTNAME" ]]; then
    hostnamectl set-hostname "$SERVER_HOSTNAME"
    # Update /etc/hosts if not already there
    if ! grep -q "$SERVER_HOSTNAME" /etc/hosts; then
      sed -i "s/^127.0.1.1.*/127.0.1.1\t$SERVER_HOSTNAME/" /etc/hosts 2>/dev/null || \
        echo "127.0.1.1	$SERVER_HOSTNAME" >> /etc/hosts
    fi
  fi

  # Timezone
  timedatectl set-timezone "$TIMEZONE"

  # Locale — ensure en_US.UTF-8 exists
  if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    locale-gen en_US.UTF-8
  fi
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

  mark_phase 2
fi

# ---------------------------------------------------------------------------
# Phase 3: Data disk (second NVMe — skip RAID, use separately)
# ---------------------------------------------------------------------------
if should_run 3; then
  if [ -n "$DATA_DISK" ] && [ -b "$DATA_DISK" ]; then
    log ">>> Phase 3: Setting up data disk: $DATA_DISK -> $DATA_MOUNT"
    if ! mount | grep -q "$DATA_MOUNT"; then
      # Only format if not already formatted
      if ! blkid "$DATA_DISK" | grep -q ext4; then
        mkfs.ext4 -L data "$DATA_DISK"
      fi
      mkdir -p "$DATA_MOUNT"
      # Add to fstab if not already there
      if ! grep -q "$DATA_MOUNT" /etc/fstab; then
        echo "LABEL=data $DATA_MOUNT ext4 defaults,noatime,discard 0 2" >> /etc/fstab
      fi
      mount -a
    fi
    log "Data disk mounted at $DATA_MOUNT"
  else
    log ">>> Phase 3: No DATA_DISK set, skipping second disk setup"
  fi

  # Enable periodic TRIM for NVMe drives
  systemctl enable --now fstrim.timer

  mark_phase 3
fi

# ---------------------------------------------------------------------------
# Phase 4: sysctl tuning
# ---------------------------------------------------------------------------
if should_run 4; then
  log ">>> Phase 4: Applying sysctl tuning"
  cat > /etc/sysctl.d/99-dev-server.conf << 'SYSCTL'
# inotify — critical for Node.js file watchers across containers
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events = 32768

# File descriptors
fs.file-max = 2097152
fs.nr_open = 2097152

# Memory
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10

# Network
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.somaxconn = 4096

# Containers
kernel.pid_max = 4194304

# Bubblewrap (Claude Code sandboxing)
kernel.unprivileged_userns_clone = 1
SYSCTL
  sysctl -p /etc/sysctl.d/99-dev-server.conf

  mark_phase 4
fi

# ---------------------------------------------------------------------------
# Phase 5: Swap (8GB — OOM killer buffer)
# ---------------------------------------------------------------------------
if should_run 5; then
  if [ ! -f /swapfile ]; then
    log ">>> Phase 5: Creating 8GB swap"
    dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q swapfile /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  else
    log ">>> Phase 5: Swap already exists, skipping"
  fi

  mark_phase 5
fi

# ---------------------------------------------------------------------------
# Phase 6: Create dev user
# ---------------------------------------------------------------------------
if should_run 6; then
  log ">>> Phase 6: Creating dev user: $DEV_USER"
  if ! id -u "$DEV_USER" &>/dev/null; then
    useradd -m -s /bin/zsh -G sudo "$DEV_USER"
    echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$DEV_USER"
    chmod 440 "/etc/sudoers.d/$DEV_USER"
  fi

  # Copy root's authorized_keys
  mkdir -p "/home/$DEV_USER/.ssh"
  if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys "/home/$DEV_USER/.ssh/authorized_keys"
  fi
  chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.ssh"
  chmod 700 "/home/$DEV_USER/.ssh"
  chmod 600 "/home/$DEV_USER/.ssh/authorized_keys" 2>/dev/null || true

  # Generate SSH keypair for GitHub deploy key
  if [ ! -f "/home/$DEV_USER/.ssh/id_ed25519" ]; then
    log ">>> Generating SSH keypair for dev user (for GitHub access)"
    su - "$DEV_USER" -c 'ssh-keygen -t ed25519 -C "devbox-deploy-key" -f ~/.ssh/id_ed25519 -N ""'
  fi

  # Create config dirs and files required by devcontainer bind mounts
  mkdir -p "/home/$DEV_USER/.config" "/home/$DEV_USER/.claude" "/home/$DEV_USER/.gnupg" "/home/$DEV_USER/.ssh"
  # .gitconfig MUST be a file (not dir) — devcontainer bind-mounts it as a file
  touch "/home/$DEV_USER/.gitconfig"
  chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.config" "/home/$DEV_USER/.claude" "/home/$DEV_USER/.gnupg" "/home/$DEV_USER/.gitconfig"
  chmod 700 "/home/$DEV_USER/.gnupg"

  # Git configuration on the host
  if [ -n "$GIT_NAME" ]; then
    su - "$DEV_USER" -c "git config --global user.name '$GIT_NAME'"
  fi
  if [ -n "$GIT_EMAIL" ]; then
    su - "$DEV_USER" -c "git config --global user.email '$GIT_EMAIL'"
  fi
  # Safe defaults
  su - "$DEV_USER" -c "git config --global init.defaultBranch main"
  su - "$DEV_USER" -c "git config --global pull.rebase true"
  su - "$DEV_USER" -c "git config --global push.autoSetupRemote true"

  # User-level file descriptor limits (complements sysctl)
  cat > /etc/security/limits.d/99-dev-user.conf << LIMITS
$DEV_USER soft nofile 65536
$DEV_USER hard nofile 65536
$DEV_USER soft nproc  65536
$DEV_USER hard nproc  65536
LIMITS

  mark_phase 6
fi

# ---------------------------------------------------------------------------
# Phase 7: SSH hardening
# ---------------------------------------------------------------------------
if should_run 7; then
  log ">>> Phase 7: Hardening SSH"

  # SAFETY: Verify the dev user can SSH in before locking out root.
  # Test that the dev user exists and has authorized_keys.
  if ! id -u "$DEV_USER" &>/dev/null; then
    die "Dev user '$DEV_USER' does not exist. Cannot disable root login safely."
  fi
  if [ ! -f "/home/$DEV_USER/.ssh/authorized_keys" ]; then
    warn "Dev user has no authorized_keys — keeping root login enabled as fallback"
    _permit_root="prohibit-password"
  else
    _permit_root="no"
  fi

  cat > /etc/ssh/sshd_config.d/99-hardened.conf << SSHD
PermitRootLogin $_permit_root
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
SSHD

  # Validate config before restarting — if invalid, do NOT restart
  if sshd -t; then
    systemctl restart sshd
  else
    warn "sshd config validation failed — skipping restart to avoid lockout"
  fi

  mark_phase 7
fi

# ---------------------------------------------------------------------------
# Phase 8: Firewall
# ---------------------------------------------------------------------------
if should_run 8; then
  log ">>> Phase 8: Configuring firewall"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh               # Keep public SSH open — only lock down AFTER Tailscale is verified
  ufw allow 60000:61000/udp   # mosh ports
  ufw allow 41641/udp         # Tailscale WireGuard
  ufw allow in on tailscale0  # All Tailscale traffic
  ufw --force enable

  mark_phase 8
fi

# ---------------------------------------------------------------------------
# Phase 9: fail2ban
# ---------------------------------------------------------------------------
if should_run 9; then
  log ">>> Phase 9: Configuring fail2ban"
  cat > /etc/fail2ban/jail.local << 'JAIL'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
JAIL
  systemctl enable --now fail2ban

  mark_phase 9
fi

# ---------------------------------------------------------------------------
# Phase 10: Unattended security upgrades
# ---------------------------------------------------------------------------
if should_run 10; then
  log ">>> Phase 10: Enabling unattended security upgrades"
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UU'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
UU

  mark_phase 10
fi

# ---------------------------------------------------------------------------
# Phase 11: Docker + Buildx
# ---------------------------------------------------------------------------
if should_run 11; then
  log ">>> Phase 11: Installing Docker"
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi
  usermod -aG docker "$DEV_USER"
  systemctl enable --now docker

  # Docker daemon config
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << 'DOCKER'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3",
    "compress": "true"
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 65536 },
    "nproc": { "Name": "nproc", "Soft": 65536, "Hard": 65536 }
  },
  "dns": ["1.1.1.1", "8.8.8.8"],
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "userland-proxy": false,
  "live-restore": true
}
DOCKER
  systemctl restart docker

  # Ensure Docker Buildx is available
  if ! docker buildx version &>/dev/null; then
    log ">>> Installing Docker Buildx"
    BUILDX_VERSION=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | jq -r .tag_name)
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
      -o /usr/local/lib/docker/cli-plugins/docker-buildx
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
  fi
  log "Docker Buildx: $(docker buildx version 2>/dev/null || echo 'installed')"

  # Verify docker compose plugin is present
  if ! docker compose version &>/dev/null; then
    warn "Docker Compose plugin not found — installing"
    apt-get install -y -qq docker-compose-plugin
  fi
  log "Docker Compose: $(docker compose version 2>/dev/null || echo 'installed')"

  mark_phase 11
fi

# ---------------------------------------------------------------------------
# Phase 12: Node.js on host (needed for devcontainer CLI)
# ---------------------------------------------------------------------------
if should_run 12; then
  log ">>> Phase 12: Installing Node.js ${NODE_MAJOR}.x on host"
  if ! command -v node &>/dev/null; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y -qq nodejs
  fi
  log "Node.js: $(node --version 2>/dev/null)"
  log "npm: $(npm --version 2>/dev/null)"

  # Install devcontainer CLI globally
  if ! command -v devcontainer &>/dev/null; then
    npm install -g @devcontainers/cli
  fi
  log "devcontainer CLI: $(devcontainer --version 2>/dev/null || echo 'installed')"

  # Make npm global prefix writable by dev user (so they can update packages without sudo)
  NPM_PREFIX=$(npm config get prefix 2>/dev/null || echo "/usr/lib")
  if [ -d "$NPM_PREFIX/lib/node_modules" ]; then
    chown -R "$DEV_USER:$DEV_USER" "$NPM_PREFIX/lib/node_modules" 2>/dev/null || true
  fi
  if [ -d "$NPM_PREFIX/bin" ]; then
    chown -R "$DEV_USER:$DEV_USER" "$NPM_PREFIX/bin" 2>/dev/null || true
  fi

  mark_phase 12
fi

# ---------------------------------------------------------------------------
# Phase 13: Tailscale
# ---------------------------------------------------------------------------
if should_run 13; then
  log ">>> Phase 13: Installing Tailscale"
  if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  if [ -n "$TAILSCALE_AUTHKEY" ]; then
    log ">>> Connecting to Tailscale as '$TAILSCALE_HOSTNAME'"
    tailscale up \
      --authkey="$TAILSCALE_AUTHKEY" \
      --ssh \
      --hostname="$TAILSCALE_HOSTNAME" \
      --accept-dns=true \
      --accept-routes=true

    # Verify Tailscale is actually connected before locking down SSH
    if tailscale status &>/dev/null; then
      TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
      log "Tailscale connected. IP: $TS_IP"

      # NOW it's safe to lock down public SSH — Tailscale SSH works
      log ">>> Locking SSH to Tailscale only"
      ufw delete allow ssh 2>/dev/null || true
      ufw allow in on tailscale0 to any port 22 proto tcp
      ufw reload
      log ">>> Public SSH disabled. Use Tailscale SSH or mosh via Tailscale."
    else
      warn "Tailscale auth succeeded but status check failed — keeping public SSH open as fallback"
    fi
  else
    warn "TAILSCALE_AUTHKEY not set — public SSH remains open"
    warn "Run manually: sudo tailscale up --ssh --hostname=$TAILSCALE_HOSTNAME"
    warn "Then lock down SSH: sudo ufw delete allow ssh && sudo ufw allow in on tailscale0 to any port 22 proto tcp && sudo ufw reload"
  fi

  mark_phase 13
fi

# ---------------------------------------------------------------------------
# Phase 14: Ollama
# ---------------------------------------------------------------------------
if should_run 14; then
  log ">>> Phase 14: Installing Ollama"
  if ! command -v ollama &>/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  systemctl enable --now ollama

  # Configure Ollama to listen on all interfaces (for Docker containers)
  mkdir -p /etc/systemd/system/ollama.service.d
  cat > /etc/systemd/system/ollama.service.d/override.conf << 'OLLAMA'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_KEEP_ALIVE=30m"
OLLAMA
  systemctl daemon-reload
  systemctl restart ollama

  # Restrict Ollama to Tailscale + Docker only
  ufw allow from 100.64.0.0/10 to any port 11434 proto tcp
  ufw allow from 172.16.0.0/12 to any port 11434 proto tcp
  ufw reload

  # Pull models via the Ollama API (runs as ollama user — no permission issues)
  if [ -n "$OLLAMA_MODELS" ]; then
    log ">>> Pulling Ollama models in background"
    # Wait for Ollama to be ready
    for i in $(seq 1 30); do
      if curl -sf http://localhost:11434/api/tags &>/dev/null; then
        break
      fi
      sleep 1
    done

    for model in $OLLAMA_MODELS; do
      log ">>> Pulling model: $model (background)"
      # Use the HTTP API — the server handles storage with correct permissions
      curl -sf http://localhost:11434/api/pull -d "{\"name\": \"$model\"}" > /dev/null 2>&1 &
    done
  fi

  mark_phase 14
fi

# ---------------------------------------------------------------------------
# Phase 15: NVMe health monitoring
# ---------------------------------------------------------------------------
if should_run 15; then
  log ">>> Phase 15: Setting up NVMe health monitoring"

  # Enable smartd for all NVMe drives
  if command -v smartctl &>/dev/null; then
    # Configure smartd to monitor all devices, email-less (just log)
    cat > /etc/smartd.conf << 'SMARTD'
# Monitor all devices, log warnings to syslog
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 5,45,55
SMARTD
    systemctl enable --now smartd 2>/dev/null || true
  fi

  # Create a daily NVMe health check script
  cat > /etc/cron.daily/nvme-health << 'NVME'
#!/bin/bash
# Daily NVMe health check — logs to syslog
for dev in /dev/nvme?n1; do
  [ -b "$dev" ] || continue
  health=$(smartctl -H "$dev" 2>/dev/null | grep -i "overall" || echo "unknown")
  wear=$(nvme smart-log "$dev" 2>/dev/null | grep "percentage_used" | awk '{print $NF}' || echo "N/A")
  temp=$(nvme smart-log "$dev" 2>/dev/null | grep "temperature" | head -1 | awk '{print $NF}' || echo "N/A")
  logger -t nvme-health "$dev: $health | wear=${wear}% | temp=${temp}C"
done
NVME
  chmod +x /etc/cron.daily/nvme-health

  mark_phase 15
fi

# ---------------------------------------------------------------------------
# Phase 16: Oh My Zsh for dev user
# ---------------------------------------------------------------------------
if should_run 16; then
  log ">>> Phase 16: Installing Oh My Zsh"
  if [ ! -d "/home/$DEV_USER/.oh-my-zsh" ]; then
    su - "$DEV_USER" -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -- --unattended' || true
  fi

  mark_phase 16
fi

# ---------------------------------------------------------------------------
# Phase 17: Tmux config
# ---------------------------------------------------------------------------
if should_run 17; then
  log ">>> Phase 17: Minimal tmux config (full version installed by sync-dotfiles)"
  if [ ! -f "/home/$DEV_USER/.tmux.conf" ]; then
    cat > "/home/$DEV_USER/.tmux.conf" << 'TMUX'
# Placeholder — sync-dotfiles.sh installs the full config from configs/tmux.conf
set-option -g history-limit 200000
set -g mouse on
TMUX
    chown "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.tmux.conf"
  fi

  mark_phase 17
fi

# ---------------------------------------------------------------------------
# Phase 18: Wait for background jobs
# ---------------------------------------------------------------------------
log ">>> Waiting for background jobs to finish..."
wait

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
# Clean up phase file on success
rm -f "$PHASE_FILE"

log ""
log "=== Bootstrap Complete ==="
log "Hostname:      $(hostname)"
log "Server IP:     $(hostname -I | awk '{print $1}')"
if tailscale status &>/dev/null 2>&1; then
  log "Tailscale IP:  $(tailscale ip -4)"
  log "Tailscale DNS: $TAILSCALE_HOSTNAME"
fi
log "SSH user:      $DEV_USER"
log "Docker:        $(docker --version 2>/dev/null)"
log "Docker Buildx: $(docker buildx version 2>/dev/null || echo 'N/A')"
log "Node.js:       $(node --version 2>/dev/null || echo 'N/A')"
log "Ollama:        $(ollama --version 2>/dev/null || echo 'installed')"
log ""

# Print the SSH public key so user can add it as a GitHub deploy key
if [ -f "/home/$DEV_USER/.ssh/id_ed25519.pub" ]; then
  log "=== GitHub Deploy Key (add to repo Settings > Deploy Keys) ==="
  cat "/home/$DEV_USER/.ssh/id_ed25519.pub" >&2
  log "================================================================"
fi

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  warn "GIT_NAME and/or GIT_EMAIL not set. Configure before first commit:"
  warn "  git config --global user.name 'Your Name'"
  warn "  git config --global user.email 'you@example.com'"
fi

log ""
log "Next steps:"
log "  1. Add the deploy key above to GitHub (if not already done)"
log "  2. From MacBook: ./scripts/sync-dotfiles.sh"
log "  3. From MacBook: ./scripts/setup-devcontainer.sh"
log "  4. Connect:      ssh $DEV_USER@$TAILSCALE_HOSTNAME"
log "             or:   mosh $DEV_USER@$TAILSCALE_HOSTNAME"
