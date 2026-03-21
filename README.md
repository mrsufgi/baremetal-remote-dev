# Remote Dev Server

Reproducible bare-metal dev server on Hetzner. Provisions Docker, Tailscale, Ollama, and a full devcontainer in under 30 minutes. All you need is a MacBook with internet.

## Prerequisites

- **macOS** with Terminal (or any Unix-like shell)
- **SSH key** (`~/.ssh/id_ed25519`) — if you don't have one: `ssh-keygen -t ed25519`
- **Tailscale** installed on your MacBook — [tailscale.com/download](https://tailscale.com/download)
- **VS Code** with the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension (optional, for IDE access)
- A credit card for Hetzner (no upfront costs, pay-as-you-go)

No Docker, Node.js, or other tooling needed locally. Everything runs on the remote server.

## One-Command Setup (After Configuration)

Once you have a server IP and Tailscale auth key, the full setup is four commands:

```bash
# 1. Bootstrap the server (runs as root, ~5 min)
ssh root@SERVER_IP 'TAILSCALE_AUTHKEY=tskey-auth-xxx OLLAMA_MODELS="gemma3:9b snowflake-arctic-embed2" bash -s' < bootstrap.sh

# 2. Sync your credentials (~30 sec)
./scripts/sync-dotfiles.sh

# 3. Set up SSH config on your MacBook (~1 sec)
./scripts/connect.sh

# 4. Clone repo and start devcontainer (~10-15 min first time)
./scripts/setup-devcontainer.sh
```

Then connect:

```bash
code --remote ssh-remote+devbox ~/workspace
```

## Step-by-Step Guide

### Step 1: Order a Hetzner Auction Server

Go to [hetzner.com/sb](https://www.hetzner.com/sb/) (Server Auction / Server-Bidding).

**What to look for:**

| Spec | Minimum | Recommended |
|------|---------|-------------|
| CPU | 8 cores | i9-9900K / Ryzen 5 3600 |
| RAM | 32 GB | 64-128 GB |
| Disk | 256 GB NVMe | 2x NVMe (OS + data) |
| Location | Any | Falkenstein (FSN) or Helsinki (HEL) |

**Ordering process:**

1. Click a server that meets specs, then "Order"
2. Choose **Ubuntu 24.04** as the operating system
3. Under SSH Keys, **add your public key** (`~/.ssh/id_ed25519.pub`)
4. No RAID needed — the bootstrap handles disk layout
5. Complete checkout (no setup fee on auction servers)
6. Wait for provisioning email (~15-30 min) with your server IP

### Step 2: Get a Tailscale Auth Key

Go to [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).

Create a new auth key with these settings:

- **Reusable**: No (one-off)
- **Ephemeral**: No
- **Pre-authorized**: Yes
- **Expiry**: 90 days
- **Tags**: none needed

Copy the key — it starts with `tskey-auth-`. You'll need it in the next step.

### Step 3: Configure

```bash
cp .env.example .env
```

Edit `.env` and fill in:

```bash
SERVER_IP=<from Hetzner provisioning email>
TAILSCALE_AUTHKEY=tskey-auth-<your key>
REPO_URL=git@github.com:your-org/your-repo.git
ANTHROPIC_API_KEY=sk-ant-<your key>
```

Optional fields:

| Variable | Default | Purpose |
|----------|---------|---------|
| `TAILSCALE_HOSTNAME` | `devbox` | MagicDNS name on your tailnet |
| `DEV_USER` | `dev` | Linux user created on server |
| `DATA_DISK` | _(empty)_ | Second NVMe device path (e.g., `/dev/nvme1n1`) |
| `OLLAMA_MODELS` | `gemma3:9b snowflake-arctic-embed2` | Models to pre-pull |
| `STRIPE_SECRET_KEY` | _(empty)_ | For local webhook forwarding |

### Step 4: Bootstrap the Server

```bash
ssh root@SERVER_IP 'TAILSCALE_AUTHKEY=tskey-auth-xxx OLLAMA_MODELS="gemma3:9b snowflake-arctic-embed2" bash -s' < bootstrap.sh
```

Or source your `.env` and pass variables:

```bash
source .env
ssh root@${SERVER_IP} "TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY} OLLAMA_MODELS='${OLLAMA_MODELS}' DATA_DISK='${DATA_DISK}' bash -s" < bootstrap.sh
```

**What bootstrap does (in order):**

1. Installs system packages (git, tmux, zsh, ripgrep, etc.)
2. Sets up second data disk (if `DATA_DISK` is set)
3. Tunes sysctl (inotify watches, file descriptors, network)
4. Creates 8 GB swap
5. Creates `dev` user with passwordless sudo and your SSH key
6. Hardens SSH (key-only auth, no root login)
7. Configures UFW firewall
8. Sets up fail2ban
9. Enables unattended security upgrades
10. Installs Docker with tuned daemon config
11. Installs and connects Tailscale (locks SSH to Tailscale-only)
12. Installs Ollama, binds to `0.0.0.0:11434`, pulls models
13. Installs Oh My Zsh and configures tmux

**After bootstrap completes**, SSH on port 22 is locked to Tailscale. You can only reach the server via your tailnet from this point.

### Step 5: Sync Your Config

```bash
./scripts/sync-dotfiles.sh
```

This copies from your MacBook to the remote:

| What | Method | Notes |
|------|--------|-------|
| SSH public keys | `rsync` | Private keys are **never** copied — agent forwarding only |
| GPG keys | `gpg --export` / `--import` | For signed commits |
| Git config | `scp` + patch | Fixes macOS-specific settings for Linux |
| GitHub CLI auth | `rsync` | `~/.config/gh/hosts.yml` |
| Claude Code config | `rsync` | Settings and plugins (excludes logs/worktrees) |
| `ANTHROPIC_API_KEY` | Appended to `~/.zshrc` | For headless Claude Code auth |

### Step 6: Set Up SSH on Your MacBook

```bash
./scripts/connect.sh
```

This appends an entry to `~/.ssh/config` with:

- Tailscale MagicDNS hostname resolution
- SSH agent forwarding (your GitHub key works on the remote)
- Connection multiplexing (instant subsequent connections)
- Keepalive every 15s (prevents drops)
- Compression enabled
- A `-direct` fallback alias using the public IP

### Step 7: Start the Devcontainer

```bash
./scripts/setup-devcontainer.sh
```

This SSHes into the server and:

1. Installs Node.js and `@devcontainers/cli` (if not present)
2. Clones your repo to `~/workspace`
3. Runs `devcontainer up` (builds all Docker images)

First build takes ~10-15 minutes. Subsequent starts are under 30 seconds.

### Step 8: Connect

```bash
# VS Code (recommended)
code --remote ssh-remote+devbox ~/workspace

# Terminal only
ssh devbox

# Terminal with tmux (survives disconnects)
ssh devbox -t 'tmux attach-session -t work || tmux new-session -s work'
```

Bookmark this VS Code URI for one-click access:

```
vscode://vscode-remote/ssh-remote+devbox/home/dev/workspace
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│ MacBook                                                                 │
│                                                                         │
│  VS Code ──── Remote SSH Extension                                      │
│                     │                                                   │
│              Tailscale (WireGuard)                                       │
│                     │  ~15-20ms to EU datacenter                        │
└─────────────────────┼───────────────────────────────────────────────────┘
                      │
┌─────────────────────┼───────────────────────────────────────────────────┐
│ Bare Metal Server   │  (Hetzner Auction, e.g. i9-9900K / 128GB RAM)    │
│                     │                                                   │
│  ┌──────────────────┴──────────────────────────────────┐               │
│  │ SSH (multiplexed, compressed, agent-forwarded)       │               │
│  └──────────────────┬──────────────────────────────────┘               │
│                     │                                                   │
│  ┌──────────────────┴──────────────────────────────────┐               │
│  │ Docker Engine                                        │               │
│  │                                                      │               │
│  │  ┌─── Devcontainer (docker-compose) ──────────────┐ │               │
│  │  │                                                 │ │               │
│  │  │  App Container (workspace, your code)           │ │               │
│  │  │  Postgres x2                                    │ │               │
│  │  │  Temporal (server + UI + worker = 3 containers) │ │               │
│  │  │  NATS                                           │ │               │
│  │  │  Redis                                          │ │               │
│  │  │  MinIO (S3-compatible storage)                  │ │               │
│  │  │  Firebase Emulator                              │ │               │
│  │  │                                                 │ │               │
│  │  └─────────────────────────────────────────────────┘ │               │
│  └──────────────────────────────────────────────────────┘               │
│                                                                         │
│  ┌────────────────────────────────────────────────────┐                │
│  │ Ollama (host-level, CPU inference)                  │                │
│  │   ├── gemma3:9b                                     │                │
│  │   └── snowflake-arctic-embed2                       │                │
│  │   Accessible at host.docker.internal:11434          │                │
│  └────────────────────────────────────────────────────┘                │
│                                                                         │
│  Tailscale SSH ── UFW Firewall ── fail2ban                              │
└─────────────────────────────────────────────────────────────────────────┘
```

## Daily Workflow

### Starting Your Day

```bash
# Option A: VS Code (opens directly into devcontainer workspace)
code --remote ssh-remote+devbox ~/workspace

# Option B: Terminal with persistent tmux session
ssh devbox -t 'tmux attach-session -t work || tmux new-session -s work'
```

### Quick Health Check

```bash
./scripts/status.sh
```

Shows CPU, RAM, disk, Docker containers, Tailscale status, Ollama models, and CPU temperature.

### Ending Your Day

Just close VS Code or detach tmux (`Ctrl+B`, then `D`). The server keeps running. Your containers stay up. Reconnect anytime.

## Ollama Integration

Ollama runs on the host (not inside Docker) for direct CPU/memory access. The devcontainer reaches it via Docker's host gateway.

### From Inside the Devcontainer

```bash
# List available models
curl http://host.docker.internal:11434/api/tags

# Run inference
curl http://host.docker.internal:11434/api/generate -d '{
  "model": "gemma3:9b",
  "prompt": "Hello"
}'
```

### MCP Server Configuration

Point any MCP server config that uses Ollama to `http://host.docker.internal:11434`:

```json
{
  "ollama": {
    "baseUrl": "http://host.docker.internal:11434"
  }
}
```

This works because the devcontainer's `docker-compose.yml` includes:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

### Managing Models

```bash
# SSH into the host (not the container) to manage models
ssh devbox

# Pull a new model
ollama pull llama3.1:8b

# List models
ollama list

# Remove a model
ollama rm gemma3:9b
```

## Troubleshooting

### Can't SSH After Bootstrap

**Symptom:** `ssh root@SERVER_IP` hangs or is refused.

**Cause:** Bootstrap locks SSH to Tailscale-only. After bootstrap, port 22 is only open on the `tailscale0` interface.

**Fix:**

```bash
# Check Tailscale is running on your MacBook
tailscale status

# Ping the server via Tailscale
tailscale ping devbox

# SSH via Tailscale hostname (not IP)
ssh dev@devbox
```

If Tailscale isn't connecting, verify:
- Your MacBook's Tailscale is logged in and connected
- The auth key hasn't expired
- The server shows up in [Tailscale admin](https://login.tailscale.com/admin/machines)

**Emergency fallback:** If you still have the Hetzner KVM console (Robot panel), you can re-open port 22:

```bash
# From Hetzner KVM console
sudo ufw allow ssh
```

### Devcontainer Build Fails

**Out of disk space:**

```bash
ssh devbox
docker system prune -af --volumes   # WARNING: removes all unused images/volumes
df -h                                 # check free space
```

**Network errors during build:**

```bash
# Check DNS resolution inside Docker
ssh devbox 'docker run --rm alpine nslookup github.com'

# If DNS fails, Docker daemon uses 1.1.1.1 and 8.8.8.8 (set in bootstrap).
# Restart Docker:
ssh devbox 'sudo systemctl restart docker'
```

**Permission denied on mounts:**

```bash
# Ensure mount source dirs exist
ssh devbox 'mkdir -p ~/.config ~/.ssh ~/.gnupg && touch ~/.gitconfig'
```

### Ollama Not Reachable from Container

```bash
# Check Ollama is running on the host
ssh devbox 'systemctl status ollama'

# Test from host
ssh devbox 'curl -s http://localhost:11434/api/tags | jq .'

# Test from inside devcontainer (via VS Code terminal or exec)
curl http://host.docker.internal:11434/api/tags

# If host.docker.internal doesn't resolve, check docker-compose has:
#   extra_hosts:
#     - "host.docker.internal:host-gateway"
```

If Ollama is running but the container can't reach it, check the firewall:

```bash
ssh devbox 'sudo ufw status | grep 11434'
# Should show: 11434/tcp ALLOW 172.16.0.0/12
```

### VS Code Slow or Unresponsive

**File watcher limits:** Already handled by bootstrap (sets `fs.inotify.max_user_watches=1048576`). Verify:

```bash
ssh devbox 'cat /proc/sys/fs/inotify/max_user_watches'
# Should be 1048576
```

**VS Code settings:** Add to your remote workspace settings (`.vscode/settings.json`):

```json
{
  "files.watcherExclude": {
    "**/node_modules/**": true,
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true,
    "**/dist/**": true
  }
}
```

**Extension host using too much memory:** Disable extensions you don't need on the remote. In VS Code, open the Extensions panel and disable heavy extensions for the SSH remote.

### Connection Drops

**tmux is your safety net.** Always use tmux for long-running tasks:

```bash
# Start or reattach
ssh devbox -t 'tmux attach-session -t work || tmux new-session -s work'

# Detach: Ctrl+B, then D
# Reattach after disconnect: same command above
```

**SSH keepalive already configured** by `connect.sh` (every 15s, 4 retries = 60s tolerance). If you still get drops:

```bash
# Check multiplexed connection state
ssh -O check devbox

# Kill stale multiplexed connection
ssh -O exit devbox

# Reconnect
ssh devbox
```

### Docker Containers Won't Start (Port Conflicts)

```bash
# See what's using a port
ssh devbox 'sudo ss -tlnp | grep :5432'

# Stop all containers and restart
ssh devbox 'docker compose -f ~/workspace/.devcontainer/docker-compose.yml down'
ssh devbox 'docker compose -f ~/workspace/.devcontainer/docker-compose.yml up -d'
```

## Cost Breakdown

Hetzner auction servers have **no setup fee** and **hourly billing with a monthly cap**.

| Server Example | Monthly Cap | Daily Cost | 5-Day Sprint | 20 Days |
|----------------|-------------|------------|--------------|---------|
| i7-8700, 64GB RAM | ~EUR 39 | ~EUR 1.30 | ~EUR 6.50 | ~EUR 26 |
| i9-9900K, 128GB RAM | ~EUR 59 | ~EUR 1.97 | ~EUR 9.85 | ~EUR 39 |
| Ryzen 5 3600, 128GB RAM | ~EUR 45 | ~EUR 1.50 | ~EUR 7.50 | ~EUR 30 |

Prices vary by auction availability. Check [hetzner.com/sb](https://www.hetzner.com/sb/) for current listings.

**Additional costs:** None. Tailscale is free for personal use. Ollama is free. No egress fees on Hetzner.

## Teardown

When you're done with the server:

```bash
./scripts/teardown.sh
```

**Phase 1 (pre-flight):** Checks for uncommitted git changes, unpushed commits, running containers, and credentials on disk. Aborts if you say no.

**Phase 2 (cleanup):** Stops Docker containers, removes credentials (SSH keys, GPG, GitHub CLI, Claude config, shell history), disconnects Tailscale.

**After the script, do these manually:**

1. **Cancel server** at [robot.hetzner.com](https://robot.hetzner.com) -> Servers -> Cancel
2. **Remove Tailscale device** at [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
3. **Revoke auth key** at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
4. **Clean local SSH config:**
   ```bash
   ssh-keygen -R devbox
   # Edit ~/.ssh/config and remove the 'devbox' and 'devbox-direct' blocks
   ```
5. **Optionally rotate credentials** (GitHub token, Anthropic API key) if you want extra safety

## Security Model

### What Lives Where

| Credential | Location | How It Gets There | Risk |
|------------|----------|-------------------|------|
| SSH private key | MacBook only | Never leaves your machine | Agent forwarding exposes it per-session |
| SSH public key | Server `~/.ssh/authorized_keys` | Copied by bootstrap from root | Low — public keys are public |
| GPG private keys | Server `~/.gnupg/` | Exported/imported by `sync-dotfiles.sh` | Medium — removed by teardown |
| GitHub CLI token | Server `~/.config/gh/hosts.yml` | Copied by `sync-dotfiles.sh` | Medium — removed by teardown |
| Anthropic API key | Server `~/.zshrc` | Appended by `sync-dotfiles.sh` | Medium — removed by teardown |
| Tailscale auth key | Used once during bootstrap | Passed as env var, not stored | Low — one-off, expires |
| Stripe secret key | Server `.devcontainer/.env.local` | Written by `setup-devcontainer.sh` | Medium — removed by teardown |

### Network Security

- **UFW firewall**: deny-all incoming, allow Tailscale interface only
- **SSH**: key-only auth, no root login, no password auth, fail2ban (3 strikes = 1hr ban)
- **Ollama**: only accessible from Tailscale IPs (`100.64.0.0/10`) and Docker networks (`172.16.0.0/12`)
- **Port 22**: only open on `tailscale0` after bootstrap (not on public interface)
- **Unattended upgrades**: security patches auto-installed

### SSH Agent Forwarding

Your SSH private key never touches the server. When you `ssh devbox`, agent forwarding lets the server use your local key for GitHub operations (`git push`, `gh` commands) without copying it. The forwarded key is only available during your active SSH session.

## Scripts Reference

| Script | Run From | Purpose |
|--------|----------|---------|
| `bootstrap.sh` | MacBook (piped to server) | Full server provisioning: Docker, Tailscale, Ollama, SSH hardening, firewall |
| `scripts/sync-dotfiles.sh` | MacBook | Syncs git/GPG/GitHub/Claude config to server |
| `scripts/connect.sh` | MacBook | Generates `~/.ssh/config` entry with multiplexing and keepalive |
| `scripts/setup-devcontainer.sh` | MacBook | Clones repo and runs `devcontainer up` on the server |
| `scripts/status.sh` | MacBook | Health check: CPU, RAM, disk, Docker, Ollama, temps |
| `scripts/teardown.sh` | MacBook | Credential cleanup, Tailscale disconnect, cancellation checklist |

All scripts read from `.env` for configuration. All scripts are idempotent (safe to re-run).
