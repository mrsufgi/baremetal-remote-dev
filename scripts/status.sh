#!/usr/bin/env bash
# =============================================================================
# Check remote server status — quick health check
# =============================================================================
# Run from MacBook: ./scripts/status.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found" >&2
  exit 1
fi
source "$ENV_FILE"

DEV_USER="${DEV_USER:-dev}"

if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
  SERVER="${DEV_USER}@${TAILSCALE_HOSTNAME}"
else
  SERVER="${DEV_USER}@${SERVER_IP:?Set SERVER_IP in .env}"
fi

echo "=== Remote Dev Server Status ==="
echo "Server: ${SERVER}"
echo ""

ssh "${SERVER}" << 'STATUS'
echo "--- System ---"
echo "Uptime:  $(uptime -p)"
echo "Load:    $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
echo "Memory:  $(free -h | awk '/Mem:/{printf "%s used / %s total", $3, $2}')"
echo "Swap:    $(free -h | awk '/Swap:/{printf "%s used / %s total", $3, $2}')"
echo "Disk:"
df -h / /data 2>/dev/null | tail -n +2 | awk '{printf "  %-15s %s used / %s (%s)\n", $6, $3, $2, $5}'
echo ""

echo "--- Docker ---"
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
TOTAL=$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l)
echo "Containers: $RUNNING running / $TOTAL total"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null | head -15
echo ""

echo "--- Tailscale ---"
if command -v tailscale &>/dev/null; then
  echo "Status: $(tailscale status --self --json 2>/dev/null | jq -r '.Self.Online // "unknown"' 2>/dev/null || echo 'unknown')"
  echo "IP:     $(tailscale ip -4 2>/dev/null || echo 'not connected')"
fi
echo ""

echo "--- Ollama ---"
if command -v ollama &>/dev/null; then
  echo "Status: $(systemctl is-active ollama)"
  ollama list 2>/dev/null | head -5
fi
echo ""

echo "--- CPU Temp ---"
sensors 2>/dev/null | grep -E 'Core|Package' | head -5 || echo "(sensors not available)"
STATUS
