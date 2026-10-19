#!/bin/sh
# ============================================================
# mount_data.sh  --  put this on the BOOT (FAT32) partition
#
#   mounts both card partitions and shows what is there:
#     /dev/mmcblk0p1  ->  /mnt/boot       (BOOT.BIN, image.ub, boot.scr)
#     /dev/mmcblk0p2  ->  /mnt/userdata   (USERDATA: project files, logs)
#
#   usage on the board:   sh /mnt/boot/mount_data.sh
#   (or:  sh /mnt/mount_data.sh  if BOOT is mounted on /mnt)
# ============================================================
mkdir -p /mnt/boot /mnt/userdata

if ! mountpoint -q /mnt/boot; then
    mount -t vfat /dev/mmcblk0p1 /mnt/boot 2>/dev/null && echo "mounted  /dev/mmcblk0p1 -> /mnt/boot"
fi
if [ -b /dev/mmcblk0p2 ]; then
    if ! mountpoint -q /mnt/userdata; then
        mount -t vfat /dev/mmcblk0p2 /mnt/userdata 2>/dev/null && echo "mounted  /dev/mmcblk0p2 -> /mnt/userdata"
    fi
else
    echo "NOTE: /dev/mmcblk0p2 (USERDATA) does not exist yet."
    echo "      create it with:  mkfs.vfat -F 32 -n USERDATA /dev/mmcblk0p2"
fi

echo ""
echo "--- /mnt/boot ---"
ls -l /mnt/boot 2>/dev/null | head -20
echo ""
echo "--- /mnt/userdata ---"
ls -l /mnt/userdata 2>/dev/null | head -20
