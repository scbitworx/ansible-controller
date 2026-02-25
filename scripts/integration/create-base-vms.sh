#!/bin/bash
# Create a disposable Arch Linux VM for integration testing.
#
# Prerequisites: libvirt, qemu, virt-install, genisoimage (cdrtools on Arch)
#
# This script is idempotent — it destroys any existing test-archlinux VM
# before creating a new one. The VM uses the official Arch Linux cloud image
# and cloud-init for initial configuration.
#
# IMPORTANT: This VM is for testing only. Never run against production hosts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA_DIR="${SCRIPT_DIR}/testdata"
WORK_DIR="${TESTDATA_DIR}/vm"
VM_NAME="test-archlinux"
IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_CACHE="${TESTDATA_DIR}/Arch-Linux-x86_64-cloudimg.qcow2"
DISK_SIZE="10G"
MEMORY=2048
VCPUS=2

# --- Preflight: verify all required tools are available ---

MISSING=()
for cmd in virsh virt-install qemu-img curl ssh ssh-keygen; do
  command -v "${cmd}" &>/dev/null || MISSING+=("${cmd}")
done

# Check for genisoimage or mkisofs
if command -v genisoimage &>/dev/null; then
  MKISO=genisoimage
elif command -v mkisofs &>/dev/null; then
  MKISO=mkisofs
else
  MISSING+=("genisoimage/mkisofs (install cdrtools on Arch, genisoimage on Debian/Ubuntu)")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: Missing required tools:" >&2
  for tool in "${MISSING[@]}"; do
    echo "  - ${tool}" >&2
  done
  exit 1
fi

# --- Ensure libvirt default network exists and is active ---

DEFAULT_NET_XML='<network>
  <name>default</name>
  <bridge name="virbr0"/>
  <forward mode="nat"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.122.2" end="192.168.122.254"/>
    </dhcp>
  </ip>
</network>'

if ! virsh net-info default &>/dev/null; then
  echo "Creating libvirt default network..."
  echo "${DEFAULT_NET_XML}" | virsh net-define /dev/stdin
  virsh net-autostart default
fi

if ! virsh net-info default 2>/dev/null | grep -q "Active:.*yes"; then
  echo "Starting libvirt default network..."
  virsh net-start default
fi

# --- Ensure directories exist ---

mkdir -p "${TESTDATA_DIR}" "${WORK_DIR}"

# --- Generate test SSH keypair (if not present) ---

SSH_KEY="${TESTDATA_DIR}/id_ed25519"
if [ ! -f "${SSH_KEY}" ]; then
  echo "Generating test SSH keypair..."
  ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "integration-test"
fi
SSH_PUBKEY=$(cat "${SSH_KEY}.pub")

# --- Download Arch cloud image (if not cached) ---

if [ ! -f "${IMAGE_CACHE}" ]; then
  echo "Downloading Arch Linux cloud image..."
  curl -L -o "${IMAGE_CACHE}" "${IMAGE_URL}"
fi

# --- Destroy existing VM (idempotent) ---

if virsh dominfo "${VM_NAME}" &>/dev/null; then
  echo "Destroying existing VM: ${VM_NAME}"
  virsh destroy "${VM_NAME}" 2>/dev/null || true
  virsh undefine "${VM_NAME}" --snapshots-metadata --remove-all-storage 2>/dev/null || true
fi

# --- Create VM disk from cloud image ---

echo "Creating VM disk..."
DISK="${WORK_DIR}/${VM_NAME}.qcow2"
cp "${IMAGE_CACHE}" "${DISK}"
qemu-img resize "${DISK}" "${DISK_SIZE}"

# --- Create cloud-init seed ISO ---

echo "Creating cloud-init seed ISO..."
SEED_DIR="${WORK_DIR}/seed"
mkdir -p "${SEED_DIR}"

cat > "${SEED_DIR}/meta-data" << EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

cat > "${SEED_DIR}/user-data" << EOF
#cloud-config
users:
  - name: root
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

# Ensure SSH is enabled
ssh_pwauth: false
EOF

SEED_ISO="${WORK_DIR}/seed.iso"

"${MKISO}" -output "${SEED_ISO}" -volid cidata -joliet -rock \
  "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"

# --- Create the VM ---

echo "Creating VM: ${VM_NAME}"
virt-install \
  --name "${VM_NAME}" \
  --memory "${MEMORY}" \
  --vcpus "${VCPUS}" \
  --disk "${DISK},format=qcow2" \
  --disk "${SEED_ISO},device=cdrom" \
  --import \
  --os-variant archlinux \
  --network default \
  --noautoconsole \
  --wait 0

# --- Wait for VM to be SSH-accessible ---

echo "Waiting for VM to become SSH-accessible..."
MAX_WAIT=180
WAITED=0
VM_IP=""

while [ ${WAITED} -lt ${MAX_WAIT} ]; do
  # Try virsh domifaddr first (requires guest agent), fall back to DHCP leases
  VM_IP=$(virsh domifaddr "${VM_NAME}" 2>/dev/null \
    | grep -oP '(\d+\.){3}\d+' | head -1) || true
  if [ -z "${VM_IP}" ]; then
    VM_IP=$(virsh net-dhcp-leases default 2>/dev/null \
      | grep "${VM_NAME}\|$(virsh domifaddr "${VM_NAME}" --source agent 2>/dev/null)" \
      | grep -oP '(\d+\.){3}\d+' | head -1) || true
  fi
  if [ -z "${VM_IP}" ]; then
    # Last resort: scan all DHCP leases (VM hostname may not match)
    VM_IP=$(virsh net-dhcp-leases default 2>/dev/null \
      | grep -oP '(\d+\.){3}\d+' | tail -1) || true
  fi
  if [ -n "${VM_IP}" ]; then
    if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
         -o UserKnownHostsFile=/dev/null root@"${VM_IP}" true 2>/dev/null; then
      break
    fi
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  echo "  waiting... (${WAITED}s)"
done

if [ -z "${VM_IP}" ] || [ ${WAITED} -ge ${MAX_WAIT} ]; then
  echo "ERROR: VM did not become SSH-accessible within ${MAX_WAIT}s" >&2
  echo "Debug info:" >&2
  echo "  virsh domstate: $(virsh domstate "${VM_NAME}" 2>&1)" >&2
  echo "  virsh domifaddr: $(virsh domifaddr "${VM_NAME}" 2>&1)" >&2
  echo "  DHCP leases: $(virsh net-dhcp-leases default 2>&1)" >&2
  exit 1
fi

echo "VM is accessible at ${VM_IP}"

# --- Wait for cloud-init to finish ---

echo "Waiting for cloud-init to complete..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@"${VM_IP}" "cloud-init status --wait" 2>/dev/null

# --- Take clean snapshot ---

echo "Taking clean snapshot..."
virsh snapshot-create-as "${VM_NAME}" clean --description "Clean state for integration testing"

echo ""
echo "=== VM created successfully ==="
echo "  Name:     ${VM_NAME}"
echo "  IP:       ${VM_IP}"
echo "  SSH key:  ${SSH_KEY}"
echo "  Snapshot: clean"
echo ""
echo "To run integration tests:"
echo "  ${SCRIPT_DIR}/run-integration-test.sh"
