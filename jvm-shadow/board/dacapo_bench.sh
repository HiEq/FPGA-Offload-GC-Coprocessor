#!/bin/sh
# The four fast DaCapo benchmarks, hardware side against the original JamVM.
#
#   sh dacapo_bench.sh [seconds-per-run]
#
# Hardware side: COLD + verify, so the first collection already takes over and
# the CPU closure checks the hardware closure (verify_extra must be 0).
# Original side: the same libjvm with FOGCCC_STW=1 only.
# Fixed heap: JamVM corrupts itself on heap expansion.
#
# One progress line per stage, one table at the end.
# Exit status: 0 when every stage passed, 1 otherwise.
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
D=/run/media/USERDATA-mmcblk0p2/dacapo-9.12-MR1-bach.jar
LOG=/run/media/USERDATA-mmcblk0p2/fogccc-logs/quick
HEAP=${HEAP:-700m}
SECS=${1:-${SECS:-120}}
BENCHES="luindex pmd xalan lusearch"
TOTAL=8

mkdir -p "$LOG"
rm -f "$LOG"/*.log
ROWS=$LOG/rows.txt
: > "$ROWS"
T_START=$(date +%s)
STAGE=0
FAILS=0
if [ -t 1 ]; then TTY=1; else TTY=0; fi

bar() {
    _pct=$(( $1 * 100 / TOTAL ))
    _fill=$(( $1 * 20 / TOTAL ))
    _bar=''
    _i=0
    while [ $_i -lt 20 ]; do
        if [ $_i -lt $_fill ]; then _bar="$_bar#"; else _bar="$_bar-"; fi
        _i=$((_i + 1))
    done
    printf '\r  [%s] %3d%%  %s\033[K' "$_bar" "$_pct" "$2"
}

e2e_of() {
    sed -n 's/.*PASSED in \([0-9]*\) msec.*/\1/p' "$1" | tail -1
}

median() {
    n=$(wc -l < "$1" | tr -d ' ')
    if [ "$n" -eq 0 ]; then printf '-'; return; fi
    mid=$(( (n + 1) / 2 ))
    sort -n "$1" | sed -n "${mid}p" | awk '{printf "%.1f", $1}'
}

mark_hw() {
    t=$LOG/.mk
    sed -n 's/.*takeover timing us:.*mark=\([0-9]*\).*/\1/p' "$1" |
        while read -r u; do awk -v v="$u" 'BEGIN{printf "%.3f\n", v / 1000}'; done > "$t"
    median "$t"
    rm -f "$t"
}

mark_sw() {
    t=$LOG/.mk
    sed -n 's/.*Mark took \([0-9.]*\) seconds.*/\1/p' "$1" |
        while read -r s; do awk -v v="$s" 'BEGIN{printf "%.3f\n", v * 1000}'; done > "$t"
    median "$t"
    rm -f "$t"
}

extra_of() {
    sed -n 's/.*verify_extra=\([-0-9]*\).*/\1/p' "$1" | sort -n | tail -1
}

run_stage() {
    bench=$1
    side=$2
    shift 2
    STAGE=$((STAGE + 1))
    log=$LOG/$bench.$side.log
    printf '[%d/%d] %s (%s)\n' "$STAGE" "$TOTAL" "$bench" "$side"
    "$@" > "$log" 2>&1 &
    pid=$!
    t0=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        el=$((now - t0))
        if [ "$el" -ge "$SECS" ]; then
            kill -9 "$pid" 2>/dev/null
            echo TIMEOUT >> "$log"
            break
        fi
        if [ "$TTY" -eq 1 ]; then
            bar $((STAGE - 1)) "$(printf '%s %s  %ds' "$bench" "$side" "$el")"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null
    el=$(( $(date +%s) - t0 ))

    R_RES=PASS
    if grep -q TIMEOUT "$log"; then
        R_RES=TIMEOUT
    elif grep -q 'CPU mark for this round' "$log"; then
        R_RES=FALLBACK
    elif ! grep -q 'PASSED in' "$log"; then
        R_RES=FAIL
    fi
    R_EX=$(extra_of "$log")
    if [ -z "$R_EX" ]; then R_EX=-; fi
    if [ "$R_RES" = PASS ] && [ "$R_EX" != - ] && [ "$R_EX" != 0 ]; then
        R_RES=FAIL
    fi
    if [ "$R_RES" != PASS ]; then FAILS=$((FAILS + 1)); fi
    R_E2E=$(e2e_of "$log")
    if [ -z "$R_E2E" ]; then R_E2E=$((el * 1000)); fi
    if [ "$side" = hw ]; then R_MARK=$(mark_hw "$log"); else R_MARK=$(mark_sw "$log"); fi

    if [ "$TTY" -eq 1 ]; then
        bar "$STAGE" "$(printf '%s %s  %s %ds' "$bench" "$side" "$R_RES" "$el")"
        printf '\n'
    else
        printf '  -> %s  %ds\n' "$R_RES" "$el"
    fi
}

echo "=== DaCapo 9.12-MR1 -s small: $BENCHES, heap $HEAP"
echo "    logs: $LOG"

for bench in $BENCHES; do
    run_stage "$bench" hw \
        env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
            FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
            "$J" -XXaltjvm=jamvm-fogccc -Xms"$HEAP" -Xmx"$HEAP" \
            -jar "$D" "$bench" -s small --ignore-validation
    hw_res=$R_RES; hw_e2e=$R_E2E; hw_mark=$R_MARK; hw_ex=$R_EX

    run_stage "$bench" sw \
        env FOGCCC_STW=1 "$J" -XXaltjvm=jamvm-fogccc -Xms"$HEAP" -Xmx"$HEAP" \
            -verbosegc -jar "$D" "$bench" -s small --ignore-validation
    sw_res=$R_RES; sw_e2e=$R_E2E; sw_mark=$R_MARK

    if [ "$hw_mark" = - ] || [ "$sw_mark" = - ]; then
        ratio=-
    else
        ratio=$(awk -v a="$sw_mark" -v b="$hw_mark" 'BEGIN{ if (b + 0 > 0) printf "%.1fx", a / b; else printf "-" }')
    fi
    printf '%-9s %-5s %-5s %8s %8s %8s %8s %6s %5s\n' \
        "$bench" "$hw_res" "$sw_res" "$hw_e2e" "$sw_e2e" "$hw_mark" "$sw_mark" "$ratio" "$hw_ex" >> "$ROWS"
done

WALL=$(( $(date +%s) - T_START ))
printf '\n'
printf '%-9s %-5s %-5s %8s %8s %8s %8s %6s %5s\n' \
    bench hw sw e2e_hw e2e_sw mark_hw mark_sw ratio extra
cat "$ROWS"
printf '\nresult: %d/%d passed, wall %ds, logs %s\n' \
    $((TOTAL - FAILS)) "$TOTAL" "$WALL" "$LOG"

if [ "$FAILS" -eq 0 ]; then exit 0; else exit 1; fi
