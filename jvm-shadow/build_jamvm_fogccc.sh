#!/bin/bash
# Build a second JamVM that contains the FOGCCC shadow exporter.
# Installs to ~/jamvm-fogccc; the baseline build stays untouched.
set -e

source ~/petalinux_sdk/environment-setup-cortexa9t2hf-neon-amd-linux-gnueabi >/dev/null 2>&1

rm -rf ~/jamvm-src-fogccc
cp -a ~/jamvm-src ~/jamvm-src-fogccc
cd ~/jamvm-src-fogccc
make distclean >/dev/null 2>&1 || true

HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/jamvm-patch/apply_patch.py"
python3 "$HERE/jamvm-patch/apply_addr_order.py"
python3 "$HERE/jamvm-patch/apply_card.py"
python3 "$HERE/jamvm-patch/apply_incr.py"

automake --gnu >/dev/null 2>&1 || true

./configure \
    --host=arm-linux-gnueabi \
    --build=x86_64-linux-gnu \
    --with-java-runtime-library=openjdk8 \
    --disable-int-inlining \
    --prefix="$HOME/jamvm-fogccc" \
    CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" > /tmp/jamvm-fogccc-conf.log 2>&1 || {
        tail -30 /tmp/jamvm-fogccc-conf.log; exit 1; }

make -j4 > /tmp/jamvm-fogccc-make.log 2>&1 || {
    grep -E 'error|Error' /tmp/jamvm-fogccc-make.log | head -30; exit 1; }

make install > /dev/null 2>&1 || true
cp ~/jamvm-fogccc/lib/libjvm.so /tmp/lj.so
arm-amd-linux-gnueabi-strip --strip-unneeded /tmp/lj.so
gzip -9 -c /tmp/lj.so > /mnt/c/Users/wwwmt/AppData/Local/Temp/opencode/libjvm-fogccc.so.gz
ls -l ~/jamvm-fogccc/lib/libjvm.so /tmp/lj.so /mnt/c/Users/wwwmt/AppData/Local/Temp/opencode/libjvm-fogccc.so.gz
arm-amd-linux-gnueabi-readelf -d ~/jamvm-fogccc/lib/libjvm.so | grep NEEDED
