#!/bin/sh
# ============================================================
# run_repeat.sh - repeated GC / cmark measurements
#
#   sh run_repeat.sh [N]        (default 10)
#
# Group 1: N runs, different seeds
# Group 2: N cmark runs
# Group 3: 5 runs, same seed
# ============================================================
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-10}
BASE=$((20251017))

echo "################################################################"
echo "#  REPEAT TEST   N=$N   dir=$D"
echo "################################################################"

echo "=== GROUP1: gc_test, different seeds (vs CPython) ==="
i=1
while [ $i -le $N ]; do
    python3 "$D/gc_test.py" 4096 1 2 --seed $((BASE + i)) 2>&1 | grep -E '^  \[ *1/'
    i=$((i + 1))
done

echo "=== GROUP2: cmark, independent graphs (vs C) ==="
i=1
while [ $i -le $N ]; do
    sh "$D/run_cmark.sh" 4096 1 2 2>&1 | grep -E 'totals:|per object:'
    i=$((i + 1))
done

echo "=== GROUP3: same seed x5 (DDR jitter only) ==="
i=1
while [ $i -le 5 ]; do
    python3 "$D/gc_test.py" 4096 1 2 --seed 424242 2>&1 | grep -E '^  \[ *1/'
    i=$((i + 1))
done

echo "=== REPEAT_DONE ==="
