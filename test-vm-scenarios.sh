#!/usr/bin/env bash
set -euo pipefail
# Simple harness to exercise common VM install scenarios
# Usage examples:
#   ./test-vm-scenarios.sh --uefi --tpm --encrypt
#   ./test-vm-scenarios.sh --uefi --no-encrypt
#   ./test-vm-scenarios.sh --bios --no-encrypt
#   ./test-vm-scenarios.sh --bios --encrypt-no-tpm

MODE="uefi"        # uefi|bios
ENCRYPT=0
TPM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uefi) MODE="uefi"; shift;;
    --bios) MODE="bios"; shift;;
    --encrypt) ENCRYPT=1; shift;;
    --no-encrypt) ENCRYPT=0; shift;;
    --tpm) TPM=1; shift;;
    --encrypt-no-tpm) ENCRYPT=1; TPM=0; shift;;
    *) echo "Unknown option: $1"; exit 2;;
  esac

done

cd "$(dirname "$0")"

echo "Building ISO (non-interactive cache-friendly build)..."
./build-iso-docker.sh --non-interactive --no-artifacts || true

ISO_PATH=$(ls -1 iso-output/*.iso | sort | tail -n1)
if [ -z "${ISO_PATH:-}" ]; then
  echo "ERROR: ISO not found in iso-output/."
  exit 1
fi

echo "Launching VM: MODE=$MODE ENCRYPT=$ENCRYPT TPM=$TPM"
# Defer to the build script's VM runner; it prefers UEFI with OVMF and will fall back to BIOS
VM_ARGS=(--vm)
if [ "$MODE" = "bios" ]; then
  VM_ARGS+=(--vm-bios)
fi
./build-iso-docker.sh "${VM_ARGS[@]}"

echo "Note: This is an interactive smoke test. Inside the VM, run:"
echo "  sudo easyos-install"
echo "Then select options to match: MODE=$MODE ENCRYPT=$ENCRYPT TPM=$TPM"
