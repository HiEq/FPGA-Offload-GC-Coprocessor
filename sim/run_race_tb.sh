#!/bin/sh
# run_race_tb.sh - Linux twin of run_race_tb.bat (same compile list, snapshot and criteria).
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
CACHE=${TMPDIR:-/tmp}/fogccc_run_race_tb
mkdir -p "$CACHE" || exit 1
cd "$CACHE" || exit 1

echo "=== xvlog ==="
"$XV/xvlog" -sv \
    "$SRC/rtl/gc_axi_read.v" \
    "$SRC/sim/axi_proto_check.v" \
    "$SRC/sim/tb_runstart_race.v" || exit 1

echo "=== xelab ==="
"$XV/xelab" tb_runstart_race -s race_tb --mt 8 || exit 1

echo "=== xsim ==="
"$XV/xsim" race_tb -R > race_tb.log 2>&1 || { cat race_tb.log; exit 1; }
cat race_tb.log

grep -q '\[RACE\]\[FAIL\]' race_tb.log && { echo "=== REPORTED FAILURES (see $CACHE/race_tb.log) ===" >&2; exit 1; }
grep -q '\[RACE\] ==================== PASS' race_tb.log || { echo "=== NO PASS BANNER (see $CACHE/race_tb.log) ===" >&2; exit 1; }
echo "=== RUN_RACE_TB DONE ==="
echo "cache dir: $CACHE"
