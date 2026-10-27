#!/bin/sh
# ============================================================
# irq_drv_test.sh - prove the PL completion really raises IRQ_F2P[0]
# (GIC SPI 61 -> a Linux virq the driver maps; the virq number is dynamic)
#
#   sh irq_drv_test.sh [ko_path]
#
# Run this with the PL freshly configured (done = 0).  Then:
#   arm        -> count stays 0        (nothing raised it yet)
#   one GC run -> count becomes 1      (done rose -> IRQ -> handler)
#   the handler disables the line (level-triggered)
# ============================================================
D=${D:-/run/media/USERDATA-mmcblk0p2}
KO=${1:-$D/ko/fogccc-irq.ko}
DEV=/dev/fogccc_irq

echo "== insmod $KO =="
insmod "$KO" || { echo "VERDICT: INSMOD_FAILED"; exit 1; }
n=0; while [ ! -e "$DEV" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
[ -e "$DEV" ] || { echo "VERDICT: NO_DEVNODE"; exit 1; }
dmesg | tail -3

echo "== state before arm: $(cat $DEV) =="
echo arm > $DEV
sleep 1
BEFORE=$(cat $DEV)
echo "== state after arm (done is still 0, so no IRQ expected): $BEFORE =="

echo "== run one GC test (done 0 -> 1) =="
python3 "$D/fpga_vs_python.py" 1024 1 2 --seed 11 2>&1 | grep -E 'seed=|^  \[ *1/|PASSED'
# Poll for the interrupt with a timeout; a second run (count already > 0) is
# supported below.
n=0
while [ $n -lt 50 ]; do
    C=$(cut -d' ' -f1 "$DEV" 2>/dev/null)
    [ -n "$C" ] && [ "$C" -gt "$(echo "$BEFORE" | cut -d' ' -f1)" ] && break
    sleep 0.1; n=$((n+1))
done
AFTER=$(cat $DEV)
echo "== state after run: $AFTER =="
dmesg | tail -3

BEFORE_N=$(echo "$BEFORE" | cut -d' ' -f1)
BEFORE_A=$(echo "$BEFORE" | cut -d' ' -f2)
AFTER_N=$(echo "$AFTER"  | cut -d' ' -f1)
AFTER_A=$(echo "$AFTER"  | cut -d' ' -f2)
if [ "$AFTER_N" -gt "$BEFORE_N" ] && [ "$AFTER_A" = "0" ]; then
    echo "VERDICT: IRQ_DRIVEN_DONE_OK  (before='$BEFORE' after='$AFTER')"
    rc=0
else
    echo "VERDICT: FAIL  (before='$BEFORE' after='$AFTER')"
    rc=1
fi
echo "== rmmod =="
rmmod fogccc_irq || echo "(rmmod failed)"
dmesg | tail -2
exit $rc
