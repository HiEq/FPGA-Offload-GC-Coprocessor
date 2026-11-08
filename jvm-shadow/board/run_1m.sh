#!/bin/sh
# Run the 1M-object self-built workload (G1M) with COLD + verify.
#   sh run_1m.sh [nodes] [refs]
D=$(cd "$(dirname "$0")" && pwd)
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
N=${1:-1000000}
env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
    FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
    "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -cp "$D" G1M "$N"
