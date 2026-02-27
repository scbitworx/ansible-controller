#!/bin/bash
# Verify controller-owned state on a test VM after bootstrap/converge.
#
# This script checks only controller-deployed resources and pipeline-level
# concerns. Role-specific assertions (packages, sshd config, timers, users,
# etc.) are owned by each role's Testinfra tests.
#
# Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>

set -euo pipefail

VM_NAME="${1:?Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>}"
VM_IP="${2:?Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>}"
SSH_KEY="${3:?Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>}"

PASS=0
FAIL=0

# Run a command on the VM via SSH as testadmin
ssh_testadmin() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 testadmin@"${VM_IP}" "$@"
}

# Run a command on the VM via SSH as root (should fail after hardening)
ssh_root() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 root@"${VM_IP}" "$@"
}

check() {
  local desc="$1"
  shift
  if ssh_testadmin "sudo $*" &>/dev/null; then
    echo "  [PASS] ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

echo "--- Controller integration verification ---"

# --- Controller-deployed scripts ---
check "ansible-pull-wrapper exists and is executable" \
  test -x /usr/local/bin/ansible-pull-wrapper
check "ansible-vault-client exists and is executable" \
  test -x /usr/local/bin/ansible-vault-client

# --- Vault pipeline proof (password hash was decrypted and applied) ---
check "Vault-encrypted password hash was applied (proves vault pipeline)" \
  "getent shadow testadmin | grep -q '\\\$6\\\$rounds=500000'"

# --- Full converge proof (root SSH blocked = sshd hardening ran) ---
if ssh_root "true" &>/dev/null; then
  echo "  [FAIL] Root SSH login is blocked (proves full converge)"
  FAIL=$((FAIL + 1))
else
  echo "  [PASS] Root SSH login is blocked (proves full converge)"
  PASS=$((PASS + 1))
fi

# --- Summary ---
echo ""
echo "--- Verification: ${PASS} passed, ${FAIL} failed ---"

if [ ${FAIL} -gt 0 ]; then
  exit 1
fi
