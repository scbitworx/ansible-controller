#!/bin/bash
# Generate a test-only GPG key for integration testing.
#
# This key is committed to the repo. It protects nothing real —
# it exists solely to validate the vault decryption pipeline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA_DIR="${SCRIPT_DIR}/testdata"
GPG_KEY="${TESTDATA_DIR}/test-gpg-key.asc"

if [ -f "${GPG_KEY}" ]; then
  echo "Test GPG key already exists at ${GPG_KEY}"
  echo "Delete it first if you want to regenerate."
  exit 0
fi

mkdir -p "${TESTDATA_DIR}"

# Generate key in a temporary GPG home (don't pollute user's keyring)
TEMP_GNUPG=$(mktemp -d)
trap 'rm -rf "${TEMP_GNUPG}"' EXIT

chmod 700 "${TEMP_GNUPG}"

gpg --batch --homedir "${TEMP_GNUPG}" --gen-key << 'GPG_PARAMS'
%no-protection
Key-Type: EdDSA
Key-Curve: ed25519
Subkey-Type: ECDH
Subkey-Curve: cv25519
Name-Real: Integration Test
Name-Email: integration-test@scbitworx.local
Expire-Date: 0
%commit
GPG_PARAMS

# Export the full keypair (public + private — this is intentional for testing)
gpg --batch --homedir "${TEMP_GNUPG}" --armor --export-secret-keys > "${GPG_KEY}"

echo "Test GPG key generated at ${GPG_KEY}"
echo "This key is for integration testing only — commit it to the repo."
