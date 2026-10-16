#!/bin/bash
set +e
PL=/home/hieq/xilinx/fogccc_linux
VEND=/mnt/c/Users/wwwmt/AppData/Local/Temp/zynq_sd_example/05_zynq_sd/vitis/design_1_wrapper/design_1.hwh
OUT=/mnt/c/Users/wwwmt/Desktop/fogccc_build
NEW=/mnt/c/Users/wwwmt/Desktop/FPGA\ Offload\ GC\ Coprocessor\ for\ CPython

mkdir -p /tmp/hw
rm -rf /tmp/hw/*; cd /tmp/hw
unzip -o -q $PL/project-spec/hw-description/system.xsa system.hwh 2>/dev/null
cp system.hwh our.hwh 2>/dev/null
[ -f "$VEND" ] && cp "$VEND" vend.hwh

for f in our.hwh vend.hwh; do
  [ -f "$f" ] || continue
  echo "===================== $f ====================="
  echo "-- QSPI --"
  grep -o 'NAME="PCW_QSPI[A-Z0-9_]*" VALUE="[^"]*"' $f | sort -u
  grep -o 'NAME="PCW_EN_QSPI" VALUE="[^"]*"' $f
  echo "-- SD / eMMC --"
  grep -o 'NAME="PCW_SD[01]_[A-Z0-9_]*" VALUE="[^"]*"' $f | sort -u
  grep -o 'NAME="PCW_EN_SDIO[01]" VALUE="[^"]*"' $f
  echo "-- MIO 0..15 --"
  for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    v=$(grep -o "NAME=\"PCW_MIO_$i\" VALUE=\"[^\"]*\"" $f | head -1)
    [ -n "$v" ] && echo "  MIO_$i = $v"
  done
  echo "-- MIO 40..45 --"
  for i in 40 41 42 43 44 45; do
    v=$(grep -o "NAME=\"PCW_MIO_$i\" VALUE=\"[^\"]*\"" $f | head -1)
    [ -n "$v" ] && echo "  MIO_$i = $v"
  done
  echo
done
