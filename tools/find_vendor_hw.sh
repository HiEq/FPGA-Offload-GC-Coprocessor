#!/bin/bash
set +e
echo "## find any vendor hwh"
find /mnt/c/Users/wwwmt/Desktop/04_OS-ZYNQ7100_Lite资料 /mnt/c/Users/wwwmt/AppData/Local/Temp -name "*.hwh" 2>/dev/null | head -20
echo
echo "## find vendor xsa / bd"
find /mnt/c/Users/wwwmt/Desktop/04_OS-ZYNQ7100_Lite资料 -iname "*.xsa" -o -iname "*.bd" 2>/dev/null | head -10
echo
echo "## vendor ps7_init: MIO 0..8 / 40..45 configured?"
V=/mnt/c/Users/wwwmt/AppData/Local/Temp/zynq_sd_example/05_zynq_sd/vitis/ps7_init.c
ls -la $V 2>/dev/null
for a in F8000700 F8000704 F8000708 F800070C F8000710 F8000714 F8000718 F800071C \
         F80007A0 F80007A4 F80007A8 F80007AC F80007B0 F80007B4; do
  c=$(grep -c "EMIT_MASKWRITE(0X$a" $V 2>/dev/null)
  if [ "$c" -gt 0 ]; then
    v=$(grep -o "EMIT_MASKWRITE(0X$a[^)]*)" $V | head -1)
    echo "  $v"
  fi
done
