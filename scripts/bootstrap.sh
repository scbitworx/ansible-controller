#!/bin/bash
set -euo pipefail

REPO="https://github.com/scbitworx/ansible-controller.git"
VAULT_CLIENT="/usr/local/bin/ansible-vault-client"
INVENTORY="inventory/hosts.yml"

# --- Parse optional arguments ---

while getopts "i:" opt; do
  case "$opt" in
    i) INVENTORY="$OPTARG" ;;
    *) echo "Usage: $0 [-i inventory_path]" >&2; exit 1 ;;
  esac
done

# --- Prerequisite checks ---

if ! command -v gpg &>/dev/null; then
  echo "ERROR: gpg is not installed. Install gnupg first." >&2
  exit 1
fi

if ! command -v pass &>/dev/null; then
  echo "ERROR: pass is not installed. Install pass (password-store) first." >&2
  exit 1
fi

if ! pass ls scbitworx/vault-password &>/dev/null; then
  echo "ERROR: pass entry 'scbitworx/vault-password' not found." >&2
  echo "Initialize the pass store and add the vault password:" >&2
  echo "  pass init <gpg-key-id>" >&2
  echo "  pass insert scbitworx/vault-password" >&2
  exit 1
fi

# --- Install Ansible if not present (distro-aware) ---

if ! command -v ansible-pull &>/dev/null; then
  if command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm ansible
  elif command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y ansible
  fi
fi

# --- Deploy inline vault client (chicken-and-egg: the templated version
#     is deployed by the playbook, but we need it for the first run) ---

cat > "$VAULT_CLIENT" << 'INLINE_CLIENT'
#!/bin/sh
set -eu
PASSWORD=$(pass scbitworx/vault-password 2>/dev/null) || {
  echo "ERROR: Failed to retrieve scbitworx/vault-password from pass" >&2
  exit 1
}
printf '%s' "$PASSWORD"
INLINE_CLIENT
chmod 755 "$VAULT_CLIENT"

# --- Run the initial ansible-pull ---

ansible-pull \
  -U "$REPO" \
  -i "$INVENTORY" \
  --vault-id "scbitworx@${VAULT_CLIENT}" \
  --limit "$(hostname)" \
  local.yml
