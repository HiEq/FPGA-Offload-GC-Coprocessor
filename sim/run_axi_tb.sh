#!/bin/sh
# run_axi_tb.sh - Linux twin of run_axi_tb.bat (same compile list, snapshot and criteria).
set -u
if [ -n "${VIVADO_BIN:-}" ]; then
    XV=$VIVADO_BIN
elif command -v vivado >/dev/null 2>&1; then
    XV=$(dirname "$(command -v vivado)")
else
    echo "ERROR: Vivado not found. Set VIVADO_BIN to the folder containing xvlog." >&2
    exit 1
fi
SRC=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${TMPDIR:-/tmp}/fogccc_run_axi_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_axi_read.v" \
    "$SRC/sim/axi_proto_check.v" \
    "$SRC/sim/tb_axi_read.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_axi_read -s axi_tb --mt 8 || exit 1

echo "=== xsim ==="
"$XV/xsim" axi_tb -R > axi_tb.log 2>&1 || { cat axi_tb.log; exit 1; }
cat axi_tb.log

grep -q '\[AXITB\]\[FAIL\]' axi_tb.log && { echo "=== REPORTED FAILURES (see $CACHE/axi_tb.log) ===" >&2; exit 1; }
grep -q '\[AXITB\] ==================== PASS' axi_tb.log || { echo "=== NO PASS BANNER (see $CACHE/axi_tb.log) ===" >&2; exit 1; }
echo "=== RUN_AXI_TB DONE ==="
echo "cache dir: $CACHE"
