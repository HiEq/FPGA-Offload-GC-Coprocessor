#!/bin/sh
# Run the configurable self-built graph (FogcccWorkload).
#   sh run_workload.sh [nodes] [avg_refs] [chain%]
D=$(cd "$(dirname "$0")" && pwd)
J=/run/media/USERDATA-mmcblk0p2/jvm/zulu8/bin/java
N=${1:-1000000}
R=${2:-2}
C=${3:-0}
env FOGCCC_SHADOW=1 FOGCCC_TAKEOVER=1 FOGCCC_TAKEOVER_COLD=1 \
    FOGCCC_TAKEOVER_DECIDE=0 FOGCCC_TAKEOVER_VERIFY=1 FOGCCC_STW=1 \
    "$J" -XXaltjvm=jamvm-fogccc -Xms700m -Xmx700m -cp "$D" FogcccWorkload "$N" "$R" "$C"
