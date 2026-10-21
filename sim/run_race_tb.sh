#!/bin/sh
# run_race_tb.sh - directed test for the run_start/abort same-cycle stale-R
# window (tb_runstart_race). Linux counterpart of run_race_tb.bat.
#
# The TB must hit the RREADY=0 window; a window miss is a FAIL, not a warning.
# Pass criteria: no [RACE][FAIL] lines and the TB's own PASS banner present.
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
CACHE=${TMPDIR:-/tmp}/fogccc_race_tb
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

grep -q '\[RACE\]\[FAIL\]' race_tb.log && {
    echo "=== RACE TB REPORTED FAILURES (see $CACHE/race_tb.log) ===" >&2
    exit 1
}
grep -q '\[RACE\] ==================== PASS' race_tb.log || {
    echo "=== RACE TB DID NOT REACH ITS PASS BANNER (see $CACHE/race_tb.log) ===" >&2
    exit 1
}

echo "=== RACE TB DONE ==="
echo "cache dir: $CACHE"
