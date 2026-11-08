#!/bin/sh
# Run one DaCapo benchmark.
#   sh run_dacapo.sh <bench> [hw|sw]
# hw = COLD + verify (default); sw = the same libjvm, stock collector.
D=$(cd "$(dirname "$0")" && pwd)
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
JAR=/run/media/USERDATA-mmcblk0p2/dacapo-9.12-MR1-bach.jar
B=$1
MODE=${2:-hw}
[ -n "$B" ] || { echo "usage: sh run_dacapo.sh <bench> [hw|sw]"; exit 2; }

if [ "$MODE" = "sw" ]; then
    env FOGCCC_STW=1 "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -verbosegc \
        -jar "$JAR" "$B" -s small --ignore-validation
else
    env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
        FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
        "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m \
        -jar "$JAR" "$B" -s small --ignore-validation
fi
