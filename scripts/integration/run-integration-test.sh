#!/bin/bash
# Run integration test: revert VM, set up vault, bootstrap, verify, idempotency.
#
# Prerequisites: VM created by create-base-vms.sh with a "clean" snapshot.
#
# IMPORTANT: This runs against a disposable VM, never production hosts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA_DIR="${SCRIPT_DIR}/testdata"
CONTROLLER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_NAME="test-archlinux"
SSH_KEY="${TESTDATA_DIR}/id_ed25519"
TEST_VAULT_PASSWORD="test-vault-password-do-not-use"
GPG_KEY="${TESTDATA_DIR}/test-gpg-key.asc"
INVENTORY="inventory/test-hosts.yml"

PASS=0
FAIL=0

# --- Helper functions ---

ssh_vm() {
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR root@"${VM_IP}" "$@"
}

scp_vm() {
  scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$@"
}

get_vm_ip() {
  virsh domifaddr "${VM_NAME}" 2>/dev/null \
    | grep -oP '(\d+\.){3}\d+' | head -1
}

wait_for_ssh() {
  local max_wait=60
  local waited=0
  while [ ${waited} -lt ${max_wait} ]; do
    if ssh_vm true 2>/dev/null; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "ERROR: VM not accessible via SSH after ${max_wait}s" >&2
  return 1
}

report() {
  local status="$1"
  local msg="$2"
  if [ "${status}" = "PASS" ]; then
    echo "  [PASS] ${msg}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${msg}"
    FAIL=$((FAIL + 1))
  fi
}

# --- Preflight checks ---

if [ ! -f "${SSH_KEY}" ]; then
  echo "ERROR: SSH key not found at ${SSH_KEY}" >&2
  echo "Run create-base-vms.sh first." >&2
  exit 1
fi

if [ ! -f "${GPG_KEY}" ]; then
  echo "ERROR: Test GPG key not found at ${GPG_KEY}" >&2
  echo "Generate it with: ${SCRIPT_DIR}/generate-test-gpg-key.sh" >&2
  exit 1
fi

if ! virsh dominfo "${VM_NAME}" &>/dev/null; then
  echo "ERROR: VM ${VM_NAME} does not exist." >&2
  echo "Run create-base-vms.sh first." >&2
  exit 1
fi

# --- Step 1: Revert to clean snapshot ---

echo "=== Step 1: Reverting to clean snapshot ==="
virsh snapshot-revert "${VM_NAME}" clean
virsh start "${VM_NAME}" 2>/dev/null || true

VM_IP=$(get_vm_ip)
if [ -z "${VM_IP}" ]; then
  # IP may take a moment after revert
  sleep 10
  VM_IP=$(get_vm_ip)
fi

echo "VM IP: ${VM_IP}"
wait_for_ssh

# --- Step 2: Pre-bootstrap vault setup ---

echo ""
echo "=== Step 2: Setting up vault/pass/GPG ==="

# Copy the GPG key to the VM
scp_vm "${GPG_KEY}" root@"${VM_IP}":/tmp/test-gpg-key.asc

# Install pass and gnupg, import key, init pass store, insert vault password
ssh_vm << 'REMOTE_SETUP'
set -euo pipefail

# Install prerequisites
pacman -Sy --noconfirm pass gnupg

# Import the test GPG key
gpg --batch --import /tmp/test-gpg-key.asc
rm -f /tmp/test-gpg-key.asc

# Trust the key (get the fingerprint first)
GPG_FPR=$(gpg --list-keys --with-colons 2>/dev/null \
  | awk -F: '/^fpr:/{print $10; exit}')
echo "${GPG_FPR}:6:" | gpg --import-ownertrust

# Initialize pass store
pass init "${GPG_FPR}"

REMOTE_SETUP

# Insert the vault password (can't be done in heredoc due to pipe)
echo "${TEST_VAULT_PASSWORD}" | ssh_vm "pass insert -f scbitworx/vault-password"

echo "Vault setup complete."

# --- Step 3: Run bootstrap ---

echo ""
echo "=== Step 3: Running bootstrap.sh ==="

# Copy bootstrap script to VM
scp_vm "${CONTROLLER_DIR}/scripts/bootstrap.sh" root@"${VM_IP}":/tmp/bootstrap.sh

# Run bootstrap with test inventory
if ssh_vm "bash /tmp/bootstrap.sh -i ${INVENTORY}" 2>&1; then
  report PASS "bootstrap.sh completed successfully"
else
  report FAIL "bootstrap.sh failed"
  echo "ERROR: Bootstrap failed. Aborting." >&2
  exit 1
fi

# --- Step 4: Verify state ---

echo ""
echo "=== Step 4: Verifying state ==="
"${SCRIPT_DIR}/verify-state.sh" "${VM_IP}" "${SSH_KEY}"
VERIFY_EXIT=$?
if [ ${VERIFY_EXIT} -eq 0 ]; then
  report PASS "verify-state.sh passed"
else
  report FAIL "verify-state.sh failed"
fi

# --- Step 5: Idempotency check ---

echo ""
echo "=== Step 5: Idempotency check (second run) ==="

# Run ansible-pull-wrapper (deployed by bootstrap)
PULL_OUTPUT=$(ssh_vm "/usr/local/bin/ansible-pull-wrapper" 2>&1) || true

# Check the ansible-pull log for changed tasks
CHANGED_COUNT=$(ssh_vm "grep -c 'changed=' /var/log/ansible-pull.log | tail -1" 2>/dev/null) || true

# Parse the last PLAY RECAP line for changed count
RECAP_LINE=$(ssh_vm "grep 'changed=' /var/log/ansible-pull.log | tail -1" 2>/dev/null) || true
if echo "${RECAP_LINE}" | grep -qP 'changed=0\b'; then
  report PASS "Idempotency: second run produced no changes"
else
  report FAIL "Idempotency: second run had changes: ${RECAP_LINE}"
fi

# --- Summary ---

echo ""
echo "==========================================="
echo "  Integration Test Results"
echo "==========================================="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo "==========================================="

if [ ${FAIL} -gt 0 ]; then
  exit 1
fi
