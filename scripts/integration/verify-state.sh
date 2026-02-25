#!/bin/bash
# Verify base role state on a test VM after bootstrap/converge.
#
# Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>
#
# Uses virsh to run commands on the VM (root SSH is blocked by sshd
# hardening). Falls back to SSH as testadmin for connectivity checks.

set -euo pipefail

VM_NAME="${1:?Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>}"
VM_IP="${2:?Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>}"
SSH_KEY="${3:?Usage: verify-state.sh <vm-name> <vm-ip> <ssh-key-path>}"

PASS=0
FAIL=0

# Run a command on the VM via qemu-guest-agent
vm_run() {
  local cmd="$1"
  virsh qemu-agent-command "${VM_NAME}" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/bash\",\"arg\":[\"-c\",\"${cmd}\"],\"capture-output\":true}}" 2>/dev/null
}

# Run a command on the VM via SSH as testadmin
ssh_testadmin() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 testadmin@"${VM_IP}" "$@"
}

# Run a command on the VM via SSH as root (may fail after hardening)
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

check_contains() {
  local desc="$1"
  local file="$2"
  local pattern="$3"
  if ssh_testadmin "sudo grep -q '${pattern}' '${file}'" &>/dev/null; then
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

# --- Verify root SSH is actually blocked ---
if ssh_root "true" &>/dev/null; then
  echo "  [FAIL] Root SSH login is blocked"
  FAIL=$((FAIL + 1))
else
  echo "  [PASS] Root SSH login is blocked"
  PASS=$((PASS + 1))
fi

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
