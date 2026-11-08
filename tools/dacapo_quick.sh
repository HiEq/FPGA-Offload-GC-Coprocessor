#!/bin/sh
# Quick DaCapo regression (~75 s for HW+SW on this board).
#
# The four fast/medium benchmarks.  avrora (~92 s/iteration) and sunflow
# (~52 s/iteration) dominate the full suite and are run separately.
#
#   COLD + verify: the first collection already takes over, and the CPU
#   closure verifies the hardware closure (verify_extra must be 0).
#   Fixed heap: JamVM corrupts itself on heap expansion.
#
# Board paths (Zulu 8 + JamVM on the USERDATA partition).
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
D=/run/media/USERDATA-mmcblk0p2/dacapo-9.12-MR1-bach.jar
L=/run/media/USERDATA-mmcblk0p2/fogccc-logs/quick
HEAP=${HEAP:-700m}
SECS=${SECS:-120}
mkdir -p $L
rm -f $L/*.log

run_to() {
  f=$1; shift
  "$@" > $L/$f.log 2>&1 &
  pid=$!
  n=0
  while kill -0 $pid 2>/dev/null; do
    sleep 1
    n=$((n+1))
    if [ $n -ge $SECS ]; then
      kill -9 $pid 2>/dev/null
      echo "TIMEOUT" >> $L/$f.log
      break
    fi
  done
  wait $pid 2>/dev/null
}

for b in luindex pmd xalan lusearch; do
  echo "=== $b"
  run_to $b.hw env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
      FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
      $J -XXaltjvm=jamvm-fogccc -Xms$HEAP -Xmx$HEAP \
      -jar $D $b -s small --ignore-validation
  run_to $b.sw env FOGCCC_STW=1 \
      $J -XXaltjvm=jamvm-fogccc -Xms$HEAP -Xmx$HEAP -verbosegc \
      -jar $D $b -s small --ignore-validation
done

echo "bench,side,res,ms,extra"
for b in luindex pmd xalan lusearch; do
  for side in hw sw; do
    f=$L/$b.$side.log
    res=FAIL
    grep -aq 'PASSED in' $f && res=PASS
    grep -aq TIMEOUT $f && res=TIMEOUT
    ms=$(grep -o 'PASSED in [0-9]*' $f | grep -o '[0-9]*' | tail -1)
    ex=$(grep -o 'verify_extra=[-0-9]*' $f | tail -1 | cut -d= -f2)
    echo "$b,$side,$res,$ms,$ex"
  done
done
echo "=== QUICK_END"
