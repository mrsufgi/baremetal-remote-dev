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
# Identity for the PRIMARY $DEV_USER only (Phase 6). Other users created via
# scripts/add-dev-user.sh receive their own name/email as CLI args, never these.
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
      # Add to fstab if not already there. fstrim.timer handles TRIM weekly,
      # so we skip the `discard` mount option (avoids inline-TRIM latency spikes).
      if ! grep -q "$DATA_MOUNT" /etc/fstab; then
        echo "LABEL=data $DATA_MOUNT ext4 defaults,noatime 0 2" >> /etc/fstab
      fi
      mount -a
    fi
    log "Data disk mounted at $DATA_MOUNT"
  else
    log ">>> Phase 3: No DATA_DISK set, skipping second disk setup"
  fi

  # Tune fstab mount options on / and /data for NVMe perf:
  #   - add `noatime` (skip access-time writes; big win on busy filesystems)
  #   - strip `discard` if present (we run fstrim.timer below — inline TRIM adds latency)
  # Idempotent: only rewrites lines that need it. /boot is intentionally left alone.
  for mp in / /data; do
    if awk -v m="$mp" '$2==m && $0 !~ /^#/ {found=1} END{exit !found}' /etc/fstab; then
      # Read current opts (column 4), compute new opts, rewrite only if changed.
      old_opts=$(awk -v m="$mp" '$2==m && $0 !~ /^#/ {print $4; exit}' /etc/fstab)
      new_opts=$(echo "$old_opts" | tr ',' '\n' | grep -vxE 'discard|relatime|' | paste -sd,)
      case ",$new_opts," in
        *,noatime,*) ;;
        *) new_opts="${new_opts:+${new_opts},}noatime" ;;
      esac
      if [ "$old_opts" != "$new_opts" ]; then
        log "fstab: $mp  $old_opts  ->  $new_opts"
        # Escape slashes in mountpoint for sed
        mp_esc=$(echo "$mp" | sed 's|/|\\/|g')
        sed -i -E "s|^([^#[:space:]]+[[:space:]]+${mp_esc}[[:space:]]+[^[:space:]]+[[:space:]]+)${old_opts}([[:space:]])|\1${new_opts}\2|" /etc/fstab
        mount -o remount "$mp" || log "  (remount of $mp deferred to next boot)"
      fi
    fi
  done

  # Enable periodic TRIM for NVMe drives (may not exist in minimal installs)
  if systemctl list-unit-files fstrim.timer &>/dev/null; then
    systemctl enable --now fstrim.timer
  else
    log "fstrim.timer not available — install util-linux if TRIM is needed"
  fi

  mark_phase 3
fi

# ---------------------------------------------------------------------------
# Phase 4: sysctl tuning
# ---------------------------------------------------------------------------
if should_run 4; then
  log ">>> Phase 4: Applying sysctl + ulimit tuning (devhost: free-loader limits)"
  cat > /etc/sysctl.d/99-dev-server.conf << 'SYSCTL'
# Single-tenant dev host: lift kernel ceilings so file watchers, embedding
# indexers, language servers, devcontainers never hit limits.
fs.inotify.max_user_watches = 8388608
fs.inotify.max_user_instances = 65536
fs.inotify.max_queued_events = 1048576
fs.file-max = 9223372036854775807
fs.nr_open = 2097152
vm.max_map_count = 2147483642
kernel.pid_max = 4194304
kernel.threads-max = 4194304

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

# Bubblewrap (Claude Code sandboxing)
kernel.unprivileged_userns_clone = 1
SYSCTL
  sysctl --system 2>&1 | grep -E '99-dev-server|fs\.|vm\.' | head -10

  # Per-user PAM limits (* and root). Applied via OpenSSH PAM, sudo, etc.
  cat > /etc/security/limits.d/99-devhost.conf << 'LIMITS'
*       soft    nofile      1048576
*       hard    nofile      1048576
*       soft    nproc       unlimited
*       hard    nproc       unlimited
*       soft    memlock     unlimited
*       hard    memlock     unlimited
*       soft    stack       unlimited
*       hard    stack       unlimited
root    soft    nofile      1048576
root    hard    nofile      1048576
root    soft    nproc       unlimited
root    hard    nproc       unlimited
root    soft    memlock     unlimited
root    hard    memlock     unlimited
root    soft    stack       unlimited
root    hard    stack       unlimited
LIMITS

  # Ensure pam_limits.so is loaded (Ubuntu/Debian defaults usually have it,
  # idempotent add if missing).
  for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam" ] && grep -qE '^session\s+required\s+pam_limits.so' "$pam" || \
      echo 'session required pam_limits.so' >> "$pam"
  done

  # systemd defaults (governs daemons like docker.service, tailscaled, etc.)
  mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
  for f in /etc/systemd/system.conf.d/99-devhost.conf /etc/systemd/user.conf.d/99-devhost.conf; do
    cat > "$f" << 'SD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
DefaultLimitSTACK=infinity
SD
  done
  systemctl daemon-reexec

  # Profile.d safety net — applies to login shells regardless of how spawned.
  # Critical for Tailscale SSH sessions, which bypass OpenSSH's PAM stack
  # (tailscaled be-child fork-execs the shell directly). Without this, ulimits
  # in tailscale-ssh sessions only inherit from tailscaled's own limits.
  cat > /etc/profile.d/99-devhost-ulimits.sh << 'PROF'
if [ -n "${PS1:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
  ulimit -n 1048576 2>/dev/null || true
  ulimit -u 1048576 2>/dev/null || true
  ulimit -l unlimited 2>/dev/null || true
  ulimit -s unlimited 2>/dev/null || true
fi
PROF
  chmod 644 /etc/profile.d/99-devhost-ulimits.sh

  # CPU governor → performance (pin max clock). Free perf on short/bursty work:
  # compiles, test runs, container starts stop paying the clock ramp-up tax.
  cat > /etc/systemd/system/cpu-performance.service << 'UNIT'
[Unit]
Description=Pin CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now cpu-performance.service || log "CPU governor pinning skipped (no cpufreq on this hardware)"

  # /tmp as tmpfs — compiles, tests, npm/pip temp files stay in RAM.
  # Ubuntu doesn't auto-enable tmp.mount, so we use a plain fstab entry
  # (idempotent: only add if not already present).
  if ! grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]+tmpfs' /etc/fstab; then
    echo 'tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=16G 0 0' >> /etc/fstab
    # Mount now (if /tmp is currently on disk, this shadows it until reboot;
    # real switchover happens cleanly at next boot).
    mount /tmp 2>/dev/null || log "tmpfs /tmp queued for next boot"
    log "tmpfs /tmp entry added to fstab (16G max)"
  fi

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

  # 'developers' group exists for legacy compatibility (was used for shared workspace
  # collaboration). Per-user workspaces don't need it, but keeping the group means
  # add-dev-user.sh and scripts that reference it still work.
  groupadd -f developers
  # Docker group is created by the Docker install in Phase 11, but we need it now
  # so we can put $DEV_USER in it at user-creation time. Idempotent.
  groupadd -f docker

  if ! id -u "$DEV_USER" &>/dev/null; then
    useradd -m -s /bin/zsh -G sudo,docker,developers "$DEV_USER"
    echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$DEV_USER"
    chmod 440 "/etc/sudoers.d/$DEV_USER"
  else
    # Make sure dev is in the developers group even if the user already existed
    usermod -a -G developers "$DEV_USER"
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

  # Pre-populate GitHub host key so git clone doesn't prompt
  if ! su - "$DEV_USER" -c "grep -q github.com ~/.ssh/known_hosts 2>/dev/null"; then
    log ">>> Adding GitHub host key to known_hosts"
    su - "$DEV_USER" -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null"
  fi

  # Create config dirs and files required by devcontainer bind mounts
  mkdir -p "/home/$DEV_USER/.config" "/home/$DEV_USER/.claude" "/home/$DEV_USER/.gnupg" "/home/$DEV_USER/.ssh"
  # .gitconfig MUST be a file (not dir) — devcontainer bind-mounts it as a file
  touch "/home/$DEV_USER/.gitconfig"
  chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.config" "/home/$DEV_USER/.claude" "/home/$DEV_USER/.gnupg" "/home/$DEV_USER/.gitconfig"
  chmod 700 "/home/$DEV_USER/.gnupg"

  # Per-user workspace on /data — each box has ONE primary user (DEV_USER),
  # they own their workspace exclusively, mode 700. No shared collaboration
  # at the filesystem level (collaborate via git instead). Simple POSIX perms.
  mkdir -p "/data/$DEV_USER/workspace"
  chown -R "$DEV_USER:$DEV_USER" "/data/$DEV_USER"
  chmod 700 "/data/$DEV_USER" "/data/$DEV_USER/workspace"

  cat > /etc/profile.d/developers-umask.sh << 'UMASK'
# Members of the developers group get umask 002 so new files are group-writable,
# enabling collaboration on /data/workspace without chmod dance.
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx developers; then
  umask 002
fi
UMASK
  chmod 644 /etc/profile.d/developers-umask.sh

  # Scripts reference $HOME/workspace; symlinking keeps that path working
  # while the actual bytes live on /data (per-user, owner-only).
  if [ ! -L "/home/$DEV_USER/workspace" ]; then
    if [ -d "/home/$DEV_USER/workspace" ]; then
      if [ -n "$(ls -A "/home/$DEV_USER/workspace" 2>/dev/null)" ]; then
        die "Found /home/$DEV_USER/workspace with existing contents. Stop any running devcontainers, then run:
    rsync -aHAX /home/$DEV_USER/workspace/ /data/$DEV_USER/workspace/ && rm -rf /home/$DEV_USER/workspace
  and re-run bootstrap."
      fi
      rmdir "/home/$DEV_USER/workspace"
    fi
    ln -s "/data/$DEV_USER/workspace" "/home/$DEV_USER/workspace"
    chown -h "$DEV_USER:$DEV_USER" "/home/$DEV_USER/workspace"
    log "workspace: /home/$DEV_USER/workspace -> /data/$DEV_USER/workspace"
  fi

  # Always ensure a "dev" admin user exists at UID 1100 — single point of admin
  # access on every box, separate from the primary developer account. This way
  # the primary user (DEV_USER) gets UID 1000 to match container vscode UID
  # (no chown overhead during devcontainer builds), and dev sits at 1100 as
  # a stable admin escape hatch.
  if [ "$DEV_USER" != "dev" ] && ! id -u dev &>/dev/null; then
    log ">>> Creating dev admin user (UID 1100)"
    useradd -m -u 1100 -s /bin/zsh -G sudo,docker,developers dev
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev
    chmod 440 /etc/sudoers.d/dev
    install -d -m 700 -o dev -g dev /home/dev/.ssh
    if [ -f /root/.ssh/authorized_keys ]; then
      cp /root/.ssh/authorized_keys /home/dev/.ssh/authorized_keys
      chown dev:dev /home/dev/.ssh/authorized_keys
      chmod 600 /home/dev/.ssh/authorized_keys
    fi
    mkdir -p /data/dev/workspace
    chown -R dev:dev /data/dev
    chmod 700 /data/dev /data/dev/workspace
    ln -s /data/dev/workspace /home/dev/workspace
    chown -h dev:dev /home/dev/workspace
    log "dev admin: uid=1100, sudo NOPASSWD, your SSH key authorized"
  fi

  # Polkit bypass for NOPASSWD-sudo users — mirrors sudo policy at the polkit
  # layer so bare `systemctl restart foo`, etc. don't prompt for password.
  # Users WITHOUT NOPASSWD sudo (e.g., teammates added via add-dev-user.sh)
  # still get the polkit auth dialog, matching their sudo experience.
  POLKIT_USERS='"dev"'
  if [ "$DEV_USER" != "dev" ]; then
    POLKIT_USERS="\"$DEV_USER\", $POLKIT_USERS"
  fi
  cat > /etc/polkit-1/rules.d/49-nopwd-sudo.rules <<POLKIT
polkit.addRule(function(action, subject) {
    var nopasswd_users = [$POLKIT_USERS];
    if (nopasswd_users.indexOf(subject.user) !== -1) {
        return polkit.Result.YES;
    }
});
POLKIT
  chmod 644 /etc/polkit-1/rules.d/49-nopwd-sudo.rules
  systemctl restart polkit 2>/dev/null || true
  log "polkit: bypass for NOPASSWD-sudo users ($POLKIT_USERS)"

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

  # SSH-based commit signing (git 2.34+). Uses the dev user's ed25519 key —
  # same key that SSHs in, same key that pushes to GitHub. No GPG/passphrase dance.
  # Register the PUBLIC key on GitHub as both an Auth key and a Signing key,
  # then every commit gets a "Verified" badge automatically.
  if [ -f "/home/$DEV_USER/.ssh/id_ed25519.pub" ]; then
    su - "$DEV_USER" -c "git config --global gpg.format ssh"
    su - "$DEV_USER" -c "git config --global user.signingkey '/home/$DEV_USER/.ssh/id_ed25519.pub'"
    su - "$DEV_USER" -c "git config --global commit.gpgsign true"
    su - "$DEV_USER" -c "git config --global tag.gpgsign true"
    # Allowed-signers file lets `git log --show-signature` verify your own commits locally.
    su - "$DEV_USER" -c "mkdir -p ~/.config/git"
    su - "$DEV_USER" -c "printf '%s %s\n' \"\$(git config user.email)\" \"\$(cat ~/.ssh/id_ed25519.pub)\" > ~/.config/git/allowed_signers"
    su - "$DEV_USER" -c "git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers"
  fi

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

  # SAFETY: Verify the dev user can SSH in before tightening root access.
  if ! id -u "$DEV_USER" &>/dev/null; then
    die "Dev user '$DEV_USER' does not exist. Cannot safely adjust root login."
  fi

  # Root SSH policy:
  #   ROOT_SSH_ENABLED=yes → root SSH requires BOTH publickey AND password (2FA)
  #   ROOT_SSH_ENABLED=no  → disable root SSH; only $DEV_USER can get in (default hardening)
  # Dev user is ALWAYS key-only (single-factor key) regardless of root setting.
  if [ "${ROOT_SSH_ENABLED:-no}" = "yes" ]; then
    _permit_root="yes"
    _root_pw_note="enabled (2FA: key + password both required)"
  else
    if [ ! -f "/home/$DEV_USER/.ssh/authorized_keys" ]; then
      warn "Dev user has no authorized_keys — keeping root key-login as fallback"
      _permit_root="prohibit-password"
    else
      _permit_root="no"
    fi
    _root_pw_note="restricted ($_permit_root)"
  fi
  log "Root SSH: $_root_pw_note"

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

  # When root SSH is enabled, require BOTH publickey AND password for root (2FA).
  # Comma-separated = sequential/AND; space-separated would be alternatives/OR.
  # Dev user and everyone else stay strictly key-only (single factor).
  if [ "${ROOT_SSH_ENABLED:-no}" = "yes" ]; then
    cat > /etc/ssh/sshd_config.d/98-root-password.conf << 'SSHD_ROOT'
Match User root
    PasswordAuthentication yes
    AuthenticationMethods publickey,password
SSHD_ROOT
  else
    rm -f /etc/ssh/sshd_config.d/98-root-password.conf
  fi

  # Install fail2ban to blunt brute-force on the now-exposed password path.
  # (No-op if already installed — bootstrap is idempotent.)
  if [ "${ROOT_SSH_ENABLED:-no}" = "yes" ] && ! command -v fail2ban-client &>/dev/null; then
    apt-get install -y -qq fail2ban
    cat > /etc/fail2ban/jail.d/sshd.local << 'JAIL'
[sshd]
enabled = true
port    = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
JAIL
    systemctl enable --now fail2ban
    log "fail2ban enabled (5 fails in 10m → 1h ban)"
  fi

  mkdir -p /run/sshd
  if sshd -t; then
    # Ubuntu uses ssh.service; RHEL/others use sshd.service. Try both.
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
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
  mkdir -p /etc/docker /data/docker
  cat > /etc/docker/daemon.json << 'DOCKER'
{
  "data-root": "/data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3",
    "compress": "true"
  },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 1048576, "Hard": 1048576 },
    "nproc": { "Name": "nproc", "Soft": 1048576, "Hard": 1048576 }
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

  # Install global npm packages under the DEV USER's own prefix (~/.npm-global).
  # Previously this ran `npm install -g` as root (system-wide) and then
  # `chown -R dev:dev $(npm config get prefix)/bin` to make it writable — but
  # nodejs's deb package reports prefix=/usr, so that chown nuked ownership and
  # setuid on /usr/bin/sudo, /usr/bin/su, /usr/bin/passwd, etc. Never again.
  su - "$DEV_USER" -c 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global'
  if ! su - "$DEV_USER" -c 'command -v devcontainer' &>/dev/null; then
    su - "$DEV_USER" -c 'npm install -g @devcontainers/cli'
  fi
  log "devcontainer CLI: $(su - "$DEV_USER" -c 'devcontainer --version' 2>/dev/null || echo 'installed')"

  # Put ~/.npm-global/bin on PATH system-wide (so sudo/ssh/etc. see it too)
  cat > /etc/profile.d/npm-global.sh << 'NPMPATH'
# Added by bootstrap.sh: user-level npm global bin
if [ -d "$HOME/.npm-global/bin" ]; then
  case ":$PATH:" in *":$HOME/.npm-global/bin:"*) ;; *) export PATH="$HOME/.npm-global/bin:$PATH";; esac
fi
NPMPATH
  chmod 644 /etc/profile.d/npm-global.sh

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
# Phase 13b: GitHub CLI (gh) — for opening PRs, reviewing, etc.
# ---------------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
  log ">>> Installing GitHub CLI (gh)"
  # Official GitHub apt repo (Ubuntu packages often lag)
  install -dm 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh
  log "gh: $(gh --version 2>/dev/null | head -1)"
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

  # Store models on /data (they can be tens of GB — keep root lean).
  # The ollama installer creates an 'ollama' system user that owns the models dir.
  mkdir -p /data/ollama/models
  chown -R ollama:ollama /data/ollama

  # Configure Ollama to listen on all interfaces (for Docker containers)
  mkdir -p /etc/systemd/system/ollama.service.d
  cat > /etc/systemd/system/ollama.service.d/override.conf << 'OLLAMA'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_MODELS=/data/ollama/models"
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
# Phase 18: SentinelOne agent (install-only — registration happens later)
# ---------------------------------------------------------------------------
# Install the S1 agent package if S1_INSTALLER_URL is set. We intentionally
# DO NOT register with a site token here so you can configure it on your
# own time via: sudo /opt/sentinelone/bin/sentinelctl management token set <TOKEN>
# then: sudo /opt/sentinelone/bin/sentinelctl control start
# Set S1_SITE_TOKEN in .env to auto-register during bootstrap.
if should_run 18; then
  if [ -n "${S1_INSTALLER_URL:-}" ]; then
    log ">>> Phase 18: Installing SentinelOne agent"
    if ! command -v sentinelctl &>/dev/null && [ ! -x /opt/sentinelone/bin/sentinelctl ]; then
      S1_PKG="/tmp/sentinel-agent.deb"
      log "Downloading S1 package from ${S1_INSTALLER_URL}"
      if ! curl -fsSL -o "$S1_PKG" "$S1_INSTALLER_URL"; then
        warn "S1 download failed — skipping. Check S1_INSTALLER_URL."
      else
        # S1 installer is a .deb; dpkg handles it. Fix deps if needed.
        dpkg -i "$S1_PKG" || apt-get install -fy
        rm -f "$S1_PKG"
        log "S1 agent installed at /opt/sentinelone (stopped, unregistered)"
      fi
    else
      log "S1 agent already installed"
    fi

    # Optional: auto-register + start if token provided. Otherwise leave stopped.
    if [ -n "${S1_SITE_TOKEN:-}" ] && [ -x /opt/sentinelone/bin/sentinelctl ]; then
      log "Registering S1 agent with site token"
      /opt/sentinelone/bin/sentinelctl management token set "$S1_SITE_TOKEN" || warn "S1 token set failed"
      /opt/sentinelone/bin/sentinelctl control start || warn "S1 start failed"
    else
      log "S1 token not set — agent installed but inactive. Configure later with:"
      log "  sudo /opt/sentinelone/bin/sentinelctl management token set <TOKEN>"
      log "  sudo /opt/sentinelone/bin/sentinelctl control start"
    fi
  else
    log ">>> Phase 18: S1_INSTALLER_URL not set — skipping SentinelOne install"
  fi
  mark_phase 18
fi

# ---------------------------------------------------------------------------
# Phase 19: Wait for background jobs
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

# Devcontainer storage report: workspace bind-mount + Docker images/volumes
# both live on /data, so this is what the container effectively sees.
DATA_AVAIL=$(df -BG --output=avail /data 2>/dev/null | tail -1 | tr -dc '0-9')
DATA_TOTAL=$(df -BG --output=size  /data 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$DATA_AVAIL" ]; then
  log "Devcontainer storage: ${DATA_AVAIL}G free of ${DATA_TOTAL}G on /data"
  log "  workspace:  /home/$DEV_USER/workspace -> /data/workspace"
  log "  docker:     /data/docker (images, layers, volumes)"
  log "  ollama:     /data/ollama/models"
  if [ "$DATA_AVAIL" -lt 500 ]; then
    warn "Less than 500G free on /data — devcontainer may hit storage limits"
  fi
fi
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
