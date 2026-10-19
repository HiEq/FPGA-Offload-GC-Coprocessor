#!/bin/sh
# ============================================================
# irq_loss_test.sh - DIAGNOSTIC ONLY, not an acceptance test.
#
#   sh irq_loss_test.sh [cycles]
#
# Each cycle: run one GC test (done 0 -> 1), then arm the driver, then check
# that the interrupt count advanced by exactly one.  A level line that stays
# high until the next run cannot lose an edge, so the expectation is N/N.
#
# Also measures the documented coalescing case: two runs while the line is
# disarmed must produce ONE interrupt (level semantics), not two.
# ============================================================
D=${D:-/run/media/USERDATA-mmcblk0p2}
N=${1:-10}
DEV=/dev/fogccc_irq
KO=$D/ko/fogccc-irq.ko

insmod "$KO" || { echo "VERDICT: INSMOD_FAILED"; exit 1; }
sleep 1
# done may already be high from a previous run, so the very first arm can fire
# immediately; take the baseline AFTER that, otherwise every count is off by one
echo arm > "$DEV"
sleep 1
base=$(cut -d' ' -f1 "$DEV")
echo "base count = $base   (each cycle must add exactly 1)"

ok=0
i=1
while [ $i -le $N ]; do
    python3 "$D/gc_test.py" 1024 1 2 --seed $((100 + i)) >/dev/null 2>&1
    echo arm > "$DEV"
    sleep 1
    c=$(cut -d' ' -f1 "$DEV")
    exp=$((base + i))
    if [ "$c" = "$exp" ]; then
        ok=$((ok + 1))
    else
        echo "  cycle $i: count=$c expected=$exp  ** MISMATCH **"
    fi
    i=$((i + 1))
done

echo "cycles=$N ok=$ok"

# ---- coalescing: two runs while disarmed -> one interrupt (level line) ----
python3 "$D/gc_test.py" 1024 1 2 --seed 900 >/dev/null 2>&1
python3 "$D/gc_test.py" 1024 1 2 --seed 901 >/dev/null 2>&1
c0=$(cut -d' ' -f1 "$DEV")
echo arm > "$DEV"
sleep 1
c1=$(cut -d' ' -f1 "$DEV")
echo "coalescing: 2 runs while disarmed -> count $c0 -> $c1 (expect +1)"

dmesg | tail -4
rmmod fogccc_irq

if [ "$ok" = "$N" ] && [ $((c1 - c0)) -eq 1 ]; then
    echo "VERDICT: NO_LOSS $ok/$N, coalescing=1"
    exit 0
fi
echo "VERDICT: FAIL  ok=$ok/$N, coalescing=$((c1 - c0))"
exit 1
