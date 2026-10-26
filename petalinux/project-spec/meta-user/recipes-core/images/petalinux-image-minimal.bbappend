IMAGE_INSTALL:append = " byobu tmux htop glibc-binary-localedata-en-us"

# THISDIR 在函数体里会被展开成基础 recipe 的目录，这里用 := 立即固定
FOGCCC_FILES := "${THISDIR}/files"

# 串口 getty 用 921600（Petalinux 的 SERIAL baud 选项不驱动 sysvinit-inittab），
# 并把静态 lf 二进制和配置塞进 initramfs（FOGCCC 是 initramfs，没有可持久化的根）。
ROOTFS_POSTPROCESS_COMMAND += "fogccc_postprocess; "

fogccc_postprocess() {
    # files/lf 不入库（5.6 MB，超过单文件 1 MiB 的上限）
    test -f /lf || bbfatal "lf missing: put lf r42 (lf-linux-arm) at \/lf"
    sed -i 's/start_getty 115200 ttyPS0/start_getty 921600 ttyPS0/' ${IMAGE_ROOTFS}/etc/inittab
    install -d ${IMAGE_ROOTFS}/usr/bin
    install -m 0755 ${FOGCCC_FILES}/lf ${IMAGE_ROOTFS}/usr/bin/lf
    install -d ${IMAGE_ROOTFS}/home/root/.config/lf
    install -m 0644 ${FOGCCC_FILES}/lfrc ${IMAGE_ROOTFS}/home/root/.config/lf/lfrc
}
