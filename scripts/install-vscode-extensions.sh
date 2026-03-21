#!/usr/bin/env bash
# =============================================================================
# install-vscode-extensions.sh
# Installs recommended VS Code extensions for Berries EMR remote development.
# Run this on your LOCAL MacBook (not inside the devcontainer).
#
# Usage:
#   ./scripts/install-vscode-extensions.sh
#
# Prerequisites:
#   - VS Code installed with `code` CLI in PATH
#     (Cmd+Shift+P → "Shell Command: Install 'code' command in PATH")
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# Extensions to install
# --------------------------------------------------------------------------
EXTENSIONS=(
  # Remote development
  ms-vscode-remote.remote-ssh
  ms-vscode-remote.remote-ssh-edit
  ms-vscode-remote.remote-containers

  # Language support — installed locally, run on remote
  Prisma.prisma
  golang.Go
  redhat.vscode-yaml
  tamasfe.even-better-toml
  bufbuild.vscode-buf

  # Docker & infrastructure
  ms-azuretools.vscode-docker

  # GitHub integration
  github.vscode-github-actions
  GitHub.vscode-pull-request-github

  # Code quality
  oxc.oxc-vscode
  dbaeumer.vscode-eslint

  # AI assistant
  Anthropic.claude-code

  # Git
  eamodio.gitlens
)

# --------------------------------------------------------------------------
# Check that `code` CLI is available
# --------------------------------------------------------------------------
if ! command -v code &>/dev/null; then
  echo "ERROR: 'code' command not found."
  echo "Open VS Code → Cmd+Shift+P → 'Shell Command: Install code command in PATH'"
  exit 1
fi

# --------------------------------------------------------------------------
# Install extensions
# --------------------------------------------------------------------------
echo "Installing ${#EXTENSIONS[@]} VS Code extensions..."
echo ""

INSTALLED=0
SKIPPED=0
FAILED=0

for ext in "${EXTENSIONS[@]}"; do
  if code --list-extensions 2>/dev/null | grep -qi "^${ext}$"; then
    echo "  [skip] ${ext} (already installed)"
    ((SKIPPED++))
  else
    if code --install-extension "${ext}" --force >/dev/null 2>&1; then
      echo "  [ ok ] ${ext}"
      ((INSTALLED++))
    else
      echo "  [FAIL] ${ext}"
      ((FAILED++))
    fi
  fi
done

echo ""
echo "Done: ${INSTALLED} installed, ${SKIPPED} skipped, ${FAILED} failed."

if (( FAILED > 0 )); then
  echo ""
  echo "Some extensions failed to install. Check your network or extension IDs."
  exit 1
fi

echo ""
echo "Next steps:"
echo "  1. Merge configs/vscode-remote-settings.json into your VS Code settings.json"
echo "  2. Connect to the remote dev server: ./scripts/connect.sh"
