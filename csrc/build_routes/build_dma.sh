#!/bin/bash
# Build the FOGCCC DMA staging module against the current PetaLinux tree.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SDK_ENV="${SDK_ENV:-$HOME/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi}"
KERNEL_BUILD="${KERNEL_BUILD:-$HOME/xilinx/fogccc2_linux/build/tmp/work/zynq_generic_7z100-amd-linux-gnueabi/linux-xlnx/6.18.10+git+v2026.1/linux-zynq_generic_7z100-standard-build}"
[ -f "$SDK_ENV" ] || { echo "ERROR: SDK_ENV not found: $SDK_ENV"; exit 1; }
[ -d "$KERNEL_BUILD" ] || { echo "ERROR: KERNEL_BUILD not found: $KERNEL_BUILD"; exit 1; }
# shellcheck disable=SC1090
. "$SDK_ENV"
MODSRC="$ROOT/driver/fogccc_dma"
OUT="$ROOT/artifacts/userdata/ko"
mkdir -p "$OUT"

make -C "$KERNEL_BUILD" M="$MODSRC" ARCH=arm \
     CROSS_COMPILE=arm-amd-linux-gnueabi- \
     CC=arm-amd-linux-gnueabi-gcc modules
cp "$MODSRC/fogccc_dma.ko" "$OUT/fogccc_dma.ko"
file "$OUT/fogccc_dma.ko"
echo "=== DMA kernel module DONE ==="
