#!/bin/bash
# Run the full integration test pipeline and log output to a shared location.
#
# Usage: run-all.sh
#
# This script runs all integration test steps in order:
#   1. Generate test GPG key (if not present)
#   2. Create the test VM (if not present, or --recreate)
#   3. Run the integration test
#
# Output is teed to scripts/integration/integration-test.log so it can
# be read from any environment that shares the repo checkout.
#
# Options:
#   --recreate    Destroy and recreate the VM before testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/integration-test.log"
RECREATE=false

for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# Truncate log file
> "${LOG_FILE}"

{
  echo "=== Integration test started: $(date --iso-8601=seconds) ==="
  echo ""

  # --- Step 1: Generate test GPG key ---
  echo "=== Step 1: Generate test GPG key ==="
  "${SCRIPT_DIR}/generate-test-gpg-key.sh"
  echo ""

  # --- Step 2: Create VM ---
  if [ "${RECREATE}" = true ] || ! virsh dominfo test-archlinux &>/dev/null; then
    echo "=== Step 2: Create test VM ==="
    "${SCRIPT_DIR}/create-base-vms.sh"
  else
    echo "=== Step 2: VM already exists (use --recreate to rebuild) ==="
  fi
  echo ""

  # --- Step 3: Run integration test ---
  echo "=== Step 3: Run integration test ==="
  "${SCRIPT_DIR}/run-integration-test.sh"

  echo ""
  echo "=== Integration test finished: $(date --iso-8601=seconds) ==="

} 2>&1 | tee "${LOG_FILE}"
