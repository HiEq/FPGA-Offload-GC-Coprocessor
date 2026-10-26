setenv bootargs console=ttyPS0,921600 earlycon
echo "=== booting FOGCCC2 (image.ub) ==="
if load mmc 0:1 0x10000000 image.ub; then
bootm 0x10000000
fi
echo "=== image.ub failed, trying image.ub.orig ==="
if load mmc 0:1 0x10000000 image.ub.orig; then
bootm 0x10000000
fi
echo "=== both FOGCCC images failed ==="
