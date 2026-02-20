#!/bin/bash
set -euo pipefail

REPO="https://github.com/scbitworx/ansible-controller.git"

# Install Ansible if not present (distro-aware)
if ! command -v ansible-pull &>/dev/null; then
  if command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm ansible
  elif command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y ansible
  fi
fi

# Run the initial ansible-pull (no wrapper script exists yet)
ansible-pull \
  -U "$REPO" \
  -i inventory/hosts.yml \
  --limit "$(hostname)" \
  local.yml
