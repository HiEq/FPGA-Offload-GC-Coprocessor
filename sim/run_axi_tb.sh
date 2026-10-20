#!/bin/sh
# run_axi_tb.sh - directed unit test for gc_axi_read (outstanding cap).
# Linux counterpart of run_axi_tb.bat. Same pass criteria: no FAIL lines and the
# TB's own PASS banner must be present.
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
CACHE=${TMPDIR:-/tmp}/fogccc_axi_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" "$SRC/rtl/gc_axi_read.v" "$SRC/sim/axi_proto_check.v" "$SRC/sim/tb_axi_read.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_axi_read -s axi_tb --mt 20 || exit 1

echo "=== xsim ==="
"$XV/xsim" axi_tb -R > axi_tb.log 2>&1 || { cat axi_tb.log; exit 1; }
cat axi_tb.log

grep -q -e '\[AXITB\]\[FAIL\]' -e '\[AXI\]\[FAIL\]' -e '\[TB\]\[FAIL\]' axi_tb.log && {
    echo "=== AXI TB REPORTED FAILURES (see $CACHE/axi_tb.log) ===" >&2
    exit 1
}
grep -q '\[AXITB\] ==================== PASS' axi_tb.log || {
    echo "=== AXI TB DID NOT REACH ITS PASS BANNER (see $CACHE/axi_tb.log) ===" >&2
    exit 1
}

echo "=== AXI TB DONE ==="
echo "cache dir: $CACHE"
