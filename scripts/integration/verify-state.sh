#!/bin/bash
# Verify base role state on a test VM after bootstrap/converge.
#
# Usage: verify-state.sh <vm-ip> <ssh-key-path>
#
# Runs assertions via SSH and reports pass/fail for each check.

set -euo pipefail

VM_IP="${1:?Usage: verify-state.sh <vm-ip> <ssh-key-path>}"
SSH_KEY="${2:?Usage: verify-state.sh <vm-ip> <ssh-key-path>}"

PASS=0
FAIL=0

ssh_vm() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR root@"${VM_IP}" "$@"
}

check() {
  local desc="$1"
  shift
  if ssh_vm "$@" &>/dev/null; then
    echo "  [PASS] ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local desc="$1"
  local file="$2"
  local pattern="$3"
  if ssh_vm "grep -q '${pattern}' '${file}'" &>/dev/null; then
    echo "  [PASS] ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

echo "--- Base role verification ---"

# --- Admin user ---
check "Admin user 'testadmin' exists" id testadmin
check "Admin user has home directory" test -d /home/testadmin
check "Admin user shell is /bin/bash" \
  "getent passwd testadmin | grep -q ':/bin/bash'"

# --- Password hash (vault decryption test) ---
check "Admin user has password hash set (vault decryption)" \
  "getent shadow testadmin | grep -q '\\\$6\\\$rounds=500000'"

# --- SSH hardening ---
check "sshd_config exists" test -f /etc/ssh/sshd_config
check_contains "PermitRootLogin no" /etc/ssh/sshd_config "PermitRootLogin no"
check_contains "PasswordAuthentication no" /etc/ssh/sshd_config "PasswordAuthentication no"
check_contains "PubkeyAuthentication yes" /etc/ssh/sshd_config "PubkeyAuthentication yes"
check_contains "PermitEmptyPasswords no" /etc/ssh/sshd_config "PermitEmptyPasswords no"
check_contains "MaxAuthTries 3" /etc/ssh/sshd_config "MaxAuthTries 3"

# --- Timezone and locale ---
check "Timezone symlink exists" test -L /etc/localtime

# --- Base packages ---
check "git is installed" command -v git
check "vim is installed" command -v vim
check "curl is installed" command -v curl

# --- ansible-pull timer ---
check "ansible-pull.service unit exists" \
  test -f /etc/systemd/system/ansible-pull.service
check "ansible-pull.timer unit exists" \
  test -f /etc/systemd/system/ansible-pull.timer
check "ansible-pull.timer is enabled" \
  "systemctl is-enabled ansible-pull.timer"
check "ansible-pull.timer is active" \
  "systemctl is-active ansible-pull.timer"

# --- ansible-pull wrapper and vault scripts ---
check "ansible-pull-wrapper exists" test -x /usr/local/bin/ansible-pull-wrapper
check "ansible-vault-client exists" test -x /usr/local/bin/ansible-vault-client

# --- Unattended-upgrades should NOT be present on Arch ---
check "unattended-upgrades not installed (Arch)" \
  "! pacman -Qi unattended-upgrades 2>/dev/null"

# --- Summary ---
echo ""
echo "--- Verification: ${PASS} passed, ${FAIL} failed ---"

if [ ${FAIL} -gt 0 ]; then
  exit 1
fi
