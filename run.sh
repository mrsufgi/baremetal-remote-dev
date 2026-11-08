#!/usr/bin/env bash
# =============================================================================
# Berries Remote Dev — Interactive Setup Wizard
# =============================================================================
# Single entry point for the entire remote dev server lifecycle.
# Run from your MacBook: ./run.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# ---------------------------------------------------------------------------
# Colors & formatting
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
banner() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}${BOLD}║              Berries Remote Dev Setup Wizard                ║${RESET}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

info()    { echo -e "  ${BLUE}ℹ${RESET}  $1"; }
success() { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
error()   { echo -e "  ${RED}✖${RESET}  $1"; }
step()    { echo -e "\n${BOLD}── $1 ──${RESET}"; }
progress() { echo -e "  ${CYAN}▸${RESET} $1"; }

ask() {
  local prompt="$1" default="${2:-}"
  if [ -n "$default" ]; then
    echo -en "  ${YELLOW}?${RESET} ${prompt} ${DIM}[${default}]${RESET}: "
    read -r answer
    echo "${answer:-$default}"
  else
    echo -en "  ${YELLOW}?${RESET} ${prompt}: "
    read -r answer
    echo "$answer"
  fi
}

ask_secret() {
  local prompt="$1"
  echo -en "  ${YELLOW}?${RESET} ${prompt}: "
  read -rs answer
  echo ""
  echo "$answer"
}

confirm() {
  local prompt="$1"
  echo -en "  ${YELLOW}?${RESET} ${prompt} ${DIM}[Y/n]${RESET}: "
  read -r answer
  [[ "${answer:-Y}" =~ ^[Yy]$ ]]
}

build_bootstrap_env() {
  local vars=""
  local -a BOOTSTRAP_VARS=(
    TAILSCALE_AUTHKEY TAILSCALE_HOSTNAME SERVER_HOSTNAME
    OLLAMA_MODELS DEV_USER DATA_DISK DATA_MOUNT
    GIT_NAME GIT_EMAIL NODE_MAJOR TIMEZONE
  )
  for var in "${BOOTSTRAP_VARS[@]}"; do
    if [ -n "${!var:-}" ]; then
      vars+="${var}='${!var}' "
    fi
  done
  echo "$vars"
}

run_script() {
  local script="$1" label="$2"
  local script_path

  # Resolve script path — check scripts/ subdir first, then root
  if [ -f "${SCRIPT_DIR}/scripts/${script}" ]; then
    script_path="${SCRIPT_DIR}/scripts/${script}"
  elif [ -f "${SCRIPT_DIR}/${script}" ]; then
    script_path="${SCRIPT_DIR}/${script}"
  else
    error "Script not found: ${script}"
    return 1
  fi

  progress "Running: ${label}..."
  echo ""
  if bash "$script_path"; then
    success "${label} — done"
    return 0
  else
    error "${label} — failed (exit code $?)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# .env interactive setup
# ---------------------------------------------------------------------------
setup_env() {
  step "Environment Configuration"
  echo ""
  info "I'll walk you through creating your .env file."
  info "You can always edit it later: ${DIM}${ENV_FILE}${RESET}"
  echo ""

  local server_ip ts_authkey ts_hostname repo_url anthropic_key
  local ollama_models dev_user data_disk data_mount stripe_key

  server_ip=$(ask "Server IP (from Hetzner panel, or leave blank if not yet provisioned)")
  echo ""

  ts_authkey=$(ask_secret "Tailscale auth key (https://login.tailscale.com/admin/settings/keys)")
  if [ -z "$ts_authkey" ]; then
    warn "No Tailscale key provided — you'll need to add it to .env later"
  fi
  echo ""

  ts_hostname=$(ask "Tailscale hostname (for MagicDNS)" "devbox")
  echo ""

  repo_url=$(ask "Repository SSH URL" "git@github.com:your-org/your-repo.git")
  echo ""

  anthropic_key=$(ask_secret "Anthropic API key (for Claude Code headless auth)")
  if [ -z "$anthropic_key" ]; then
    warn "No Anthropic key provided — Claude Code won't work until you add it"
  fi
  echo ""

  ollama_models=$(ask "Ollama models to pre-pull (space-separated)" "gemma3:9b snowflake-arctic-embed2")
  dev_user=$(ask "Dev user on server" "dev")
  echo ""

  local git_name git_email timezone data_disk data_mount
  git_name=$(ask "Git user.name (for commits on server)" "")
  git_email=$(ask "Git user.email (for commits on server)" "")
  timezone=$(ask "Timezone" "UTC")
  data_disk=$(ask "Second disk device (leave empty for single-disk server)" "")
  data_mount=$(ask "Data mount point" "/data")
  echo ""

  stripe_key=""
  if confirm "Do you have a Stripe secret key to configure?"; then
    stripe_key=$(ask_secret "Stripe secret key")
  fi

  # Write the .env file
  cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# Remote Dev Server Configuration
# Generated by run.sh on $(date +%Y-%m-%d)
# =============================================================================

# Server IP (from Hetzner Robot panel after provisioning)
SERVER_IP=${server_ip}

# Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
# Create: one-off, persistent, pre-authorized, 30-day expiry
TAILSCALE_AUTHKEY=${ts_authkey}

# Tailscale hostname (used for MagicDNS: devbox.your-tailnet.ts.net)
TAILSCALE_HOSTNAME=${ts_hostname}

# Your repo (SSH URL)
REPO_URL=${repo_url}

# Anthropic API key (for Claude Code headless auth — no browser needed)
ANTHROPIC_API_KEY=${anthropic_key}

# Ollama models to pre-pull (space-separated)
OLLAMA_MODELS="${ollama_models}"

# Dev user on the server (created by bootstrap)
DEV_USER=${dev_user}

# Server hostname (also used for Tailscale if TAILSCALE_HOSTNAME not set separately)
SERVER_HOSTNAME=${ts_hostname}

# Git identity on the host (needed before first clone/commit)
GIT_NAME=${git_name}
GIT_EMAIL=${git_email}

# Node.js major version to install on host (for devcontainer CLI)
NODE_MAJOR=22

# Timezone
TIMEZONE=${timezone}

# Second NVMe disk device (leave empty for single-disk servers)
DATA_DISK=${data_disk}
DATA_MOUNT=${data_mount}

# Optional: Stripe secret key (for webhook forwarding)
STRIPE_SECRET_KEY=${stripe_key}
ENVEOF

  echo ""
  success ".env file created at ${ENV_FILE}"
  info "Review and edit anytime: ${DIM}vim ${ENV_FILE}${RESET}"
}

# ---------------------------------------------------------------------------
# Check/ensure .env
# ---------------------------------------------------------------------------
ensure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    warn ".env file not found"
    echo ""
    if confirm "Would you like to create it now?"; then
      setup_env
    else
      info "Copy the example and fill it in manually:"
      echo -e "    ${DIM}cp ${ENV_EXAMPLE} ${ENV_FILE} && vim ${ENV_FILE}${RESET}"
      exit 1
    fi
  else
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    success ".env loaded"
  fi
}

# ---------------------------------------------------------------------------
# Full setup flow
# ---------------------------------------------------------------------------
full_setup() {
  step "Full Setup"
  echo ""
  info "This will set up everything from scratch:"
  echo -e "    ${DIM}0. Install Ubuntu on rescue system (if needed)${RESET}"
  echo -e "    ${DIM}1. Setup MacBook prerequisites${RESET}"
  echo -e "    ${DIM}2. Bootstrap the remote server${RESET}"
  echo -e "    ${DIM}3. Sync dotfiles & credentials${RESET}"
  echo -e "    ${DIM}4. Setup GitHub access on server${RESET}"
  echo -e "    ${DIM}5. Configure SSH connection${RESET}"
  echo -e "    ${DIM}6. Start the devcontainer${RESET}"
  echo ""

  if ! confirm "Ready to begin?"; then
    info "Cancelled."
    return
  fi

  # Source .env for SERVER_IP
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  # ── Step 0: Install OS (if in rescue mode) ──
  step "Step 0/6 — Install OS (if needed)"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  local os_id
  os_id=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@${SERVER_IP}" \
    "grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2" 2>/dev/null || echo "unknown")
  if [ "$os_id" != "ubuntu" ]; then
    warn "Server is in rescue mode (not Ubuntu). Installing OS first..."
    run_script "install-os.sh" "Install Ubuntu 24.04"
  else
    success "Server already running Ubuntu — skipping OS install"
  fi

  # ── Step 1: MacBook setup ──
  step "Step 1/6 — MacBook Setup"
  if [ -f "${SCRIPT_DIR}/scripts/setup-macbook.sh" ]; then
    run_script "setup-macbook.sh" "MacBook prerequisites"
  else
    warn "scripts/setup-macbook.sh not found — skipping"
    info "Make sure you have: Tailscale, SSH keys, VS Code CLI installed"
  fi

  # ── Step 2: Server bootstrap ──
  step "Step 2/6 — Bootstrap Server"

  if [ -z "${SERVER_IP:-}" ]; then
    echo ""
    warn "SERVER_IP is not set in .env"
    info "Order a server from https://www.hetzner.com/sb/ (Server Auction)"
    info "Pick one with 32GB+ RAM (64-128GB recommended)"
    info "Select your SSH public key during checkout"
    echo ""
    SERVER_IP=$(ask "Enter the server IP when ready")

    # Update .env with the IP
    if [ -n "$SERVER_IP" ]; then
      sed -i.bak "s/^SERVER_IP=.*/SERVER_IP=${SERVER_IP}/" "$ENV_FILE"
      rm -f "${ENV_FILE}.bak"
      success "SERVER_IP updated in .env"
    else
      error "Cannot continue without a server IP"
      return 1
    fi
  fi

  echo ""
  info "Bootstrapping server at ${BOLD}${SERVER_IP}${RESET}"
  info "This installs Docker, Tailscale, Ollama, hardens SSH, etc."
  info "It will run as root via SSH and takes ~5-10 minutes."
  echo ""

  if confirm "Proceed with bootstrap?"; then
    progress "Running bootstrap on ${SERVER_IP}..."
    echo ""

    local env_vars
    env_vars=$(build_bootstrap_env)
    local bootstrap_cmd="${env_vars}bash -s"

    if ssh -o StrictHostKeyChecking=accept-new "root@${SERVER_IP}" "$bootstrap_cmd" < "${SCRIPT_DIR}/bootstrap.sh"; then
      success "Server bootstrap complete"
    else
      error "Bootstrap failed — check output above"
      if ! confirm "Continue anyway?"; then
        return 1
      fi
    fi
  fi

  # ── Step 3: Sync dotfiles ──
  step "Step 3/6 — Sync Dotfiles"
  run_script "sync-dotfiles.sh" "Dotfile & credential sync"

  # ── Step 4: GitHub access ──
  step "Step 4/6 — GitHub Access"
  info "Creates a server-specific SSH key for GitHub (recommended, avoids 1Password/agent issues)"
  if [ -f "${SCRIPT_DIR}/scripts/setup-github.sh" ]; then
    run_script "setup-github.sh" "GitHub SSH key setup"
  else
    warn "scripts/setup-github.sh not found — skipping"
  fi

  # ── Step 5: SSH config ──
  step "Step 5/6 — SSH Configuration"
  run_script "connect.sh" "SSH config setup"

  # ── Step 6: Devcontainer ──
  step "Step 6/6 — Start Devcontainer"
  run_script "setup-devcontainer.sh" "Devcontainer setup"

  # ── Done ──
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║                    Setup Complete!                           ║${RESET}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Connect with VS Code:${RESET}"
  echo -e "    ${CYAN}code --remote ssh-remote+${TAILSCALE_HOSTNAME:-devbox} ~/workspace${RESET}"
  echo ""
  echo -e "  ${BOLD}Connect with terminal:${RESET}"
  echo -e "    ${CYAN}ssh ${TAILSCALE_HOSTNAME:-devbox}${RESET}"
  echo ""
  echo -e "  ${BOLD}Connect with tmux (survives disconnects):${RESET}"
  echo -e "    ${CYAN}ssh ${TAILSCALE_HOSTNAME:-devbox} -t 'tmux attach-session -t work || tmux new-session -s work'${RESET}"
  echo ""
  echo -e "  ${BOLD}Check status:${RESET}"
  echo -e "    ${CYAN}./run.sh${RESET}  then select ${BOLD}6) Check status${RESET}"
  echo ""
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
  echo -e "  ${BOLD}What would you like to do?${RESET}"
  echo ""
  echo -e "    ${CYAN}1)${RESET}  Full setup ${DIM}(runs everything in order)${RESET}"
  echo -e "    ${CYAN}2)${RESET}  Setup MacBook only"
  echo -e "    ${CYAN}3)${RESET}  Bootstrap server only"
  echo -e "    ${CYAN}4)${RESET}  Sync dotfiles & credentials"
  echo -e "    ${CYAN}5)${RESET}  Setup GitHub access"
  echo -e "    ${CYAN}6)${RESET}  Start devcontainer"
  echo -e "    ${CYAN}7)${RESET}  Check status"
  echo -e "    ${CYAN}8)${RESET}  Teardown"
  echo ""
  echo -e "    ${CYAN}9)${RESET}  Edit .env"
  echo -e "    ${CYAN}i)${RESET}  Install OS ${DIM}(rescue → Ubuntu 24.04)${RESET}"
  echo -e "    ${CYAN}r)${RESET}  Recreate .env from scratch"
  echo -e "    ${CYAN}0)${RESET}  Exit"
  echo ""
  echo -en "  ${YELLOW}?${RESET} Select an option: "
  read -r choice
  echo ""

  case "$choice" in
    1)
      full_setup
      ;;
    2)
      step "MacBook Setup"
      if [ -f "${SCRIPT_DIR}/scripts/setup-macbook.sh" ]; then
        run_script "setup-macbook.sh" "MacBook prerequisites"
      else
        warn "scripts/setup-macbook.sh not found yet"
        info "This script will install MacBook prerequisites (Tailscale, etc.)"
        info "Create it at: ${DIM}${SCRIPT_DIR}/scripts/setup-macbook.sh${RESET}"
      fi
      ;;
    3)
      step "Bootstrap Server"
      # shellcheck source=/dev/null
      source "$ENV_FILE"
      if [ -z "${SERVER_IP:-}" ]; then
        SERVER_IP=$(ask "Enter the server IP")
        sed -i.bak "s/^SERVER_IP=.*/SERVER_IP=${SERVER_IP}/" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
      fi
      info "Running bootstrap on ${BOLD}${SERVER_IP}${RESET} as root..."
      echo ""
      local env_vars
      env_vars=$(build_bootstrap_env)
      local bootstrap_cmd="${env_vars}bash -s"
      ssh -o StrictHostKeyChecking=accept-new "root@${SERVER_IP}" "$bootstrap_cmd" < "${SCRIPT_DIR}/bootstrap.sh"
      ;;
    4)
      step "Sync Dotfiles"
      run_script "sync-dotfiles.sh" "Dotfile & credential sync"
      ;;
    5)
      step "GitHub Setup"
      run_script "setup-github.sh" "GitHub SSH key setup"
      ;;
    6)
      step "Start Devcontainer"
      run_script "setup-devcontainer.sh" "Devcontainer setup"
      ;;
    7)
      step "Server Status"
      run_script "status.sh" "Status check"
      ;;
    8)
      step "Teardown"
      run_script "teardown.sh" "Teardown"
      ;;
    9)
      ${EDITOR:-vim} "$ENV_FILE"
      ;;
    i|I)
      step "Install OS"
      run_script "install-os.sh" "Install Ubuntu 24.04 on rescue system"
      ;;
    r|R)
      setup_env
      ;;
    0)
      info "Goodbye!"
      exit 0
      ;;
    *)
      error "Invalid option: ${choice}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  banner

  info "One-stop setup for your Berries remote dev server."
  info "Provisions a Hetzner bare metal box with Docker, Tailscale,"
  info "Ollama, and a full devcontainer environment."
  echo ""

  ensure_env

  echo ""
  show_menu
}

main "$@"
