#!/usr/bin/env bash
# =============================================================================
# Install Ubuntu (24.04 by default, UBUNTU_RELEASE in .env) on Hetzner Rescue System
# =============================================================================
# Run from your MacBook BEFORE bootstrap.sh — the server must be in rescue mode.
#
#   ./scripts/install-os.sh
#
# This uses Hetzner's installimage to:
#   - Set up software RAID1 across both NVMe drives (redundancy; override via RAID_LEVEL=0)
#   - Create LVM with configurable root + swap sizes, /data takes the rest
#     (sizes via ROOT_LV_SIZE / SWAP_LV_SIZE in .env; defaults 150G / 8G)
#   - Format root + data as xfs (faster for Docker / parallel I/O; cannot shrink)
#   - Workspace lives on /data/workspace (bootstrap relocates it), so 150G root is plenty
#   - Install Ubuntu LTS (UBUNTU_RELEASE, default 2404)
#   - Reboot into the new OS
#
# After reboot, run bootstrap.sh to provision the server.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "  ${CYAN}ℹ${RESET}  $1"; }
success() { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
error()   { echo -e "  ${RED}✖${RESET}  $1"; exit 1; }

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
else
  error ".env not found. Run ./run.sh first to create it."
fi

if [ -z "${SERVER_IP:-}" ]; then
  error "SERVER_IP is not set in .env"
fi

# LVM sizes (overridable via .env). /data always takes the remainder.
# Root only holds OS + /home dotfiles; workspace + Docker live on /data.
ROOT_LV_SIZE="${ROOT_LV_SIZE:-150G}"
SWAP_LV_SIZE="${SWAP_LV_SIZE:-8G}"

# Ubuntu release as Hetzner names its images (2404 = 24.04, 2604 = 26.04).
UBUNTU_RELEASE="${UBUNTU_RELEASE:-2404}"
UBUNTU_VERSION="${UBUNTU_RELEASE:0:2}.${UBUNTU_RELEASE:2:2}"

# Software RAID level across the two NVMe drives.
#   1 = mirror: survives a single disk failure, 1× capacity (default, recommended)
#   0 = stripe: 2× perf + 2× capacity, but any disk failure = total data loss
RAID_LEVEL="${RAID_LEVEL:-1}"
if [[ "$RAID_LEVEL" != "0" && "$RAID_LEVEL" != "1" ]]; then
  error "RAID_LEVEL must be 0 or 1 (got: $RAID_LEVEL)"
fi

# ---------------------------------------------------------------------------
# Verify rescue mode
# ---------------------------------------------------------------------------
info "Checking if server is in rescue mode..."
OS_ID=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@${SERVER_IP}" \
  "grep '^ID=' /etc/os-release | cut -d= -f2" 2>/dev/null || true)

if [ "$OS_ID" = "ubuntu" ]; then
  warn "Server is already running Ubuntu — not in rescue mode."
  echo -en "  ${YELLOW}?${RESET} Continue anyway? This will WIPE the server. [y/N]: "
  read -r answer
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Capacity preflight: make sure /data will be big enough for devcontainer use
# ---------------------------------------------------------------------------
MIN_DATA_GB="${MIN_DATA_GB:-500}"
info "Checking projected /data capacity..."
# Drive size in GB (smallest of the two, since RAID1 uses min; for RAID0 they should be equal)
DRIVE_BYTES=$(ssh "root@${SERVER_IP}" "blockdev --getsize64 /dev/nvme0n1 /dev/nvme1n1 2>/dev/null | sort -n | head -1" || echo 0)
if [ "$DRIVE_BYTES" -gt 0 ]; then
  DRIVE_GB=$((DRIVE_BYTES / 1024 / 1024 / 1024))
  # Strip unit suffix from sizes, assume G
  ROOT_GB=$(echo "$ROOT_LV_SIZE" | sed 's/[Gg]$//')
  SWAP_GB=$(echo "$SWAP_LV_SIZE" | sed 's/[Gg]$//')
  # Capacity multiplier: RAID1 = 1×, RAID0 = 2×. Minus ~2G for boot + LVM/md metadata.
  if [ "$RAID_LEVEL" = "0" ]; then
    VG_GB=$((DRIVE_GB * 2 - 2))
  else
    VG_GB=$((DRIVE_GB - 2))
  fi
  DATA_GB=$((VG_GB - ROOT_GB - SWAP_GB))
  info "Drives: ${DRIVE_GB}G each × 2 (RAID${RAID_LEVEL}) → vg0 ≈ ${VG_GB}G"
  info "Projected /data ≈ ${DATA_GB}G (after ${ROOT_GB}G root + ${SWAP_GB}G swap)"
  if [ "$DATA_GB" -lt "$MIN_DATA_GB" ]; then
    warn "Projected /data (${DATA_GB}G) is below MIN_DATA_GB=${MIN_DATA_GB}G."
    warn "Options: order larger drives, lower ROOT_LV_SIZE, set RAID_LEVEL=0, or override MIN_DATA_GB."
    echo -en "  ${YELLOW}?${RESET} Continue anyway? [y/N]: "
    read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
  else
    success "Projected /data (${DATA_GB}G) ≥ floor (${MIN_DATA_GB}G) — devcontainer will have ample room"
  fi
else
  warn "Could not detect drive size — skipping capacity preflight"
fi

# ---------------------------------------------------------------------------
# Locate the Ubuntu ${UBUNTU_VERSION} image on the rescue system.
# Hetzner switched the image archives from .tar.gz to .tar.zst (Sep 2026), so
# resolve whichever variant is present instead of hardcoding the extension.
# ---------------------------------------------------------------------------
IMAGE_PATH=$(ssh "root@${SERVER_IP}" \
  "ls /root/.oldroot/nfs/images/Ubuntu-${UBUNTU_RELEASE}-*-amd64-base.tar.zst \
      /root/.oldroot/nfs/images/Ubuntu-${UBUNTU_RELEASE}-*-amd64-base.tar.gz 2>/dev/null | head -1" || true)
if [ -z "$IMAGE_PATH" ]; then
  error "Ubuntu ${UBUNTU_VERSION} image not found in /root/.oldroot/nfs/images/ (checked .tar.zst and .tar.gz). Run: ssh root@${SERVER_IP} ls /root/.oldroot/nfs/images/"
fi
info "Using image: ${IMAGE_PATH}"

# ---------------------------------------------------------------------------
# Boot mode: newer servers (e.g. EX63) boot UEFI and installimage refuses to
# proceed without an EFI system partition ("ESP missing").
# ---------------------------------------------------------------------------
ESP_PART=""
if ssh "root@${SERVER_IP}" "[ -d /sys/firmware/efi ]"; then
  info "Rescue system booted in UEFI mode — adding a 256M EFI system partition"
  ESP_PART="PART /boot/efi esp 256M
"
fi

# ---------------------------------------------------------------------------
# Installimage config
# ---------------------------------------------------------------------------
INSTALL_CONFIG="DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1
SWRAID 1
SWRAIDLEVEL ${RAID_LEVEL}
BOOTLOADER grub
HOSTNAME ${SERVER_HOSTNAME:-devbox}
${ESP_PART}PART /boot ext4 1G
PART lvm vg0 all
LV vg0 root / xfs ${ROOT_LV_SIZE}
LV vg0 swap swap swap ${SWAP_LV_SIZE}
LV vg0 data /data xfs all
IMAGE ${IMAGE_PATH}"

info "Installing Ubuntu ${UBUNTU_VERSION} on ${BOLD}${SERVER_IP}${RESET}"
info "Disk layout: RAID${RAID_LEVEL} across 2x NVMe, LVM (${ROOT_LV_SIZE} root xfs + ${SWAP_LV_SIZE} swap + rest /data xfs — Docker + workspace on /data)"
if [ "$RAID_LEVEL" = "0" ]; then
  warn "RAID0 selected — NO redundancy. Single disk failure = total data loss."
fi
echo ""

# Upload config and run installimage
ssh -o StrictHostKeyChecking=accept-new "root@${SERVER_IP}" "cat > /tmp/install-config.txt << 'CONF'
${INSTALL_CONFIG}
CONF"

success "Install config uploaded"
info "Running installimage (this takes ~2-3 minutes)..."
echo ""

ssh "root@${SERVER_IP}" \
  "/root/.oldroot/nfs/install/installimage -a -c /tmp/install-config.txt" 2>&1

echo ""
success "Ubuntu ${UBUNTU_VERSION} installed"

# ---------------------------------------------------------------------------
# Reboot & wait
# ---------------------------------------------------------------------------
info "Rebooting server into Ubuntu..."
ssh "root@${SERVER_IP}" "reboot" 2>/dev/null || true

# Remove old host key (new OS = new keys)
ssh-keygen -R "${SERVER_IP}" 2>/dev/null || true

info "Waiting for server to come back online..."
for i in $(seq 1 30); do
  sleep 5
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
       "root@${SERVER_IP}" "echo ok" &>/dev/null; then
    echo ""
    success "Server is back online with Ubuntu ${UBUNTU_VERSION}"
    ssh -o StrictHostKeyChecking=accept-new "root@${SERVER_IP}" \
      "grep PRETTY_NAME /etc/os-release"
    echo ""
    info "Next step: run bootstrap"
    echo -e "    ${CYAN}./run.sh${RESET}  then select ${BOLD}3) Bootstrap server${RESET}"
    exit 0
  fi
  echo -n "."
done

echo ""
error "Server did not come back after 150 seconds. Check Hetzner Robot panel."
