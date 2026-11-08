#!/bin/sh
# Self-built workload suite on the board.
#
#   sh selftest.sh [nodes]
#
# G1M and FogcccWorkload run three System.gc() with COLD + verify on the
# hardware side; G1M also runs the original JamVM so the mark time can be
# compared.  FogcccTree, FogcccMutate and FogcccThreads run hardware-side;
# HelloWorld is a stock-JVM smoke run (a 260 kB heap is below the takeover
# gate, so forcing the adapter there is out of contract).
# One progress line per stage, one table at the end.
#
# Exit status: 0 when every stage passed, 1 otherwise.
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
LOG=/run/media/USERDATA-mmcblk0p2/fogccc-logs/selftest
N=${1:-1000000}
# FogcccWorkload allocates a node plus a reference array per node, so its
# object count is about twice N.  Keep it under the 1,048,576-id limit.
WN=$N
if [ "$WN" -gt 400000 ]; then WN=400000; fi
SECS=${SECS:-600}
TOTAL=7

HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$LOG"
rm -f "$LOG"/*.log
ROWS=$LOG/rows.txt
: > "$ROWS"
T_START=$(date +%s)
STAGE=0
FAILS=0
if [ -t 1 ]; then TTY=1; else TTY=0; fi

bar() {
    # bar <percent 0..100> <message>
    _pct=$1
    [ "$_pct" -gt 100 ] && _pct=100
    _fill=$(( _pct * 20 / 100 ))
    _bar=''
    _i=0
    while [ $_i -lt 20 ]; do
        if [ $_i -lt $_fill ]; then _bar="$_bar#"; else _bar="$_bar-"; fi
        _i=$((_i + 1))
    done
    printf '\r  [%s] %3d%%  %s\033[K' "$_bar" "$_pct" "$2"
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

e2e_of() {
    kind=$1
    log=$2
    wall=$3
    v=''
    case $kind in
        g1m)    v=$(sed -n 's/.*G1M_DONE.* ms=\([0-9]*\).*/\1/p' "$log" | tail -1) ;;
        wl)     v=$(sed -n 's/.*FOGCCC_WORKLOAD.*gc_ms=\([0-9]*\).*/\1/p' "$log" | tail -1) ;;
        tree)   v=$(sed -n 's/.*FOGCCC_TREE nodes=.*total_ms=\([0-9]*\).*/\1/p' "$log" | tail -1) ;;
        mutate) v=$(sed -n 's/.*MUTATE total_ms=\([0-9]*\).*/\1/p' "$log" | tail -1) ;;
        hello)  v=$(sed -n 's/.*HELLO_GC_MS=\([0-9]*\).*/\1/p' "$log" | tail -1) ;;
    esac
    if [ -z "$v" ]; then v=$wall; fi
    printf '%s' "$v"
}

pattern_of() {
    case $1 in
        g1m)     printf 'G1M_DONE' ;;
        wl)      printf 'FOGCCC_WORKLOAD' ;;
        tree)    printf 'FOGCCC_TREE nodes=' ;;
        mutate)  printf 'MUTATE total_ms=' ;;
        threads) printf 'THREADS bad=0 nulls=0' ;;
        hello)   printf 'HELLO_GC_MS=' ;;
    esac
}

run_stage() {
    tag=$1
    side=$2
    kind=$3
    name=$4
    shift 4
    STAGE=$((STAGE + 1))
    log=$LOG/$name.log
    printf '[%d/%d] %s (%s)\n' "$STAGE" "$TOTAL" "$tag" "$side"
    "$@" > "$log" 2>&1 &
    pid=$!
    t0=$(date +%s)
    case $kind in
        g1m|wl|tree) exp=20 ;;          # these use the GC-round bar
        mutate)      exp=5 ;;
        threads)     exp=5 ;;
        hello)       exp=3 ;;
        *)           exp=10 ;;
    esac
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        el=$((now - t0))
        if [ "$el" -ge "$SECS" ]; then
            kill -9 "$pid" 2>/dev/null
            echo TIMEOUT >> "$log"
            break
        fi
        if [ "$TTY" -eq 1 ]; then
            case $kind in
                g1m|wl|tree)
                    # Three System.gc() rounds print as they finish, so this
                    # bar is real progress; the others are time estimates.
                    rounds=$(grep -c 'round=' "$log" 2>/dev/null || true)
                    [ -z "$rounds" ] && rounds=0
                    pct=$(( rounds * 100 / 3 ))
                    msg=$(printf '%s %s  GC %d/3  %ds' "$tag" "$side" "$rounds" "$el")
                    ;;
                *)
                    pct=$(( el * 100 / exp ))
                    [ "$pct" -gt 96 ] && pct=96
                    msg=$(printf '%s %s  %ds' "$tag" "$side" "$el")
                    ;;
            esac
            bar "$pct" "$msg"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null
    el=$(( $(date +%s) - t0 ))

    res=PASS
    if grep -q TIMEOUT "$log"; then
        res=TIMEOUT
    elif grep -q 'CPU mark for this round' "$log"; then
        res=FALLBACK
    elif ! grep -q "$(pattern_of "$kind")" "$log"; then
        res=FAIL
    fi
    ex=$(extra_of "$log")
    if [ -z "$ex" ]; then ex=-; fi
    if [ "$res" = PASS ] && [ "$ex" != - ] && [ "$ex" != 0 ]; then
        res=FAIL
    fi
    if [ "$res" != PASS ]; then FAILS=$((FAILS + 1)); fi

    if [ "$side" = sw ]; then mk=$(mark_sw "$log"); else mk=$(mark_hw "$log"); fi
    if [ "$TTY" -eq 1 ]; then
        bar 100 "$(printf '%s %s  %s %ds' "$tag" "$side" "$res" "$el")"
        printf '\n\n'
    else
        printf '  -> %s  %ds\n' "$res" "$el"
    fi
    printf '%-22s %-4s %-6s %8s %8s %5s\n' \
        "$tag" "$side" "$res" "$(e2e_of "$kind" "$log" $((el * 1000)))" "$mk" "$ex" >> "$ROWS"
}

echo "=== self-built workloads ===================================================="
echo "    G1M $N | FogcccWorkload $WN | Tree | Mutate | Threads | Hello"
echo "    heap 700m (smoke 256m) | timeout ${SECS}s per run"
echo "    logs: $LOG"
echo

run_stage "G1M $N" hw g1m g1m_hw \
    env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
        FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
        "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -cp "$HERE" G1M "$N"

run_stage "G1M $N" sw g1m g1m_sw \
    env FOGCCC_STW=1 "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m \
        -verbosegc -cp "$HERE" G1M "$N"

run_stage "FogcccWorkload $WN" hw wl wl_hw \
    env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
        FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
        "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -cp "$HERE" FogcccWorkload "$WN" 2

run_stage FogcccTree hw tree tree_hw \
    env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
        FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
        "$J" -XXaltjvm=jamvm-fogccc -Xms256m -Xmx256m -cp "$HERE" FogcccTree

run_stage FogcccMutate hw mutate mutate_hw \
    env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
        FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
        "$J" -XXaltjvm=jamvm-fogccc -Xms256m -Xmx256m -cp "$HERE" FogcccMutate

run_stage FogcccThreads hw threads threads_hw \
    env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
        FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
        "$J" -XXaltjvm=jamvm-fogccc -Xms256m -Xmx256m -cp "$HERE" FogcccThreads

run_stage HelloWorld jvm hello hello_hw \
    "$J" -XXaltjvm=jamvm-fogccc -Xms256m -Xmx256m -cp "$HERE" HelloWorld

WALL=$(( $(date +%s) - T_START ))
printf '\n'
SEP="----------------------------------------------------------"
printf '%s\n' "$SEP"
printf '%-22s %-4s %-6s %8s %8s %5s\n' test side result e2e_ms mark_ms extra
printf '%s\n' "$SEP"
cat "$ROWS"
printf '%s\n' "$SEP"
printf ' %d/%d passed | wall %ds\n' $((TOTAL - FAILS)) "$TOTAL" "$WALL"

if [ "$FAILS" -eq 0 ]; then exit 0; else exit 1; fi
