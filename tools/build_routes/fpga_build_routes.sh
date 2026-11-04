#!/bin/sh
# FOGCCC C/DMA graph-build checks, run on the board from USERDATA.
#
#   sh fpga_build_routes.sh
#
# Requires root.  The PL engine is not touched; this only rebuilds the graph
# with C or PS PL330 DMA and then runs the project's four-way test.
set -e
cd "$(dirname "$0")"

MOD=ko/fogccc_dma.ko
chmod +x bin/verify_c_build bin/verify_dma_build bin/dma_build_one 2>/dev/null || true

cleanup() {
    rmmod fogccc_dma 2>/dev/null || true
}
trap cleanup EXIT

echo "============================================================"
echo " 1/4  C build: direct writes vs cached build + memcpy"
echo "============================================================"
./bin/verify_c_build

echo "============================================================"
echo " 2/4  DMA build: cached C -> coherent staging -> PL330 DMA"
echo "============================================================"
rmmod fogccc_dma 2>/dev/null || true
insmod "$MOD"
./bin/verify_dma_build
rmmod fogccc_dma 2>/dev/null || true

echo "============================================================"
echo " 3/4  Four-way test, graph built by C"
echo "============================================================"
python3 tests/four_way_c_build.py

echo "============================================================"
echo " 4/4  Four-way test, graph built by DMA"
echo "============================================================"
insmod "$MOD"
python3 tests/four_way_dma_build.py
rmmod fogccc_dma 2>/dev/null || true

echo
echo "BUILD_ROUTES_DONE"
