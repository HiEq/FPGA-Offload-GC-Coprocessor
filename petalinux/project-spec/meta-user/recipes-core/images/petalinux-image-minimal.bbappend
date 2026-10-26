IMAGE_INSTALL:append = " byobu tmux htop glibc-binary-localedata-en-us"

# THISDIR 在函数体里会被展开成基础 recipe 的目录，这里 := 立即固定
FOGCCC_FILES := "${THISDIR}/files"

# 串口 getty 用 921600（Petalinux 的 SERIAL baud 选项不驱动 sysvinit-inittab），
# 登录时先问终端尺寸再启动 byobu，并把静态 lf 二进制和配置塞进 initramfs
# （FOGCCC 是 initramfs，没有可持久化的根）。
ROOTFS_POSTPROCESS_COMMAND += "fogccc_postprocess; "

fogccc_postprocess() {
    # files/lf 不入库（5.6 MB，超过单文件 1 MiB 的上限）
    test -f ${FOGCCC_FILES}/lf || bbfatal "lf missing: put lf r42 (lf-linux-arm) at ${FOGCCC_FILES}/lf"
    sed -i 's/start_getty 115200 ttyPS0/start_getty 921600 ttyPS0/' ${IMAGE_ROOTFS}/etc/inittab
    install -d ${IMAGE_ROOTFS}/usr/bin
    install -m 0755 ${FOGCCC_FILES}/lf ${IMAGE_ROOTFS}/usr/bin/lf
    install -d ${IMAGE_ROOTFS}/home/root/.config/lf
    install -m 0644 ${FOGCCC_FILES}/lfrc ${IMAGE_ROOTFS}/home/root/.config/lf/lfrc

    # 终端尺寸：只保留一个查询者——99-byobu.sh 在启动 byobu 之前调用它。
    # 镜像自带的 /usr/bin/tty-size 是同一脚本的旧副本；两者各发一次 CSI 18 t，
    # 一个进程把两条应答一起读走时，另一个读空并退回 35x120（顶栏只有 120 列宽），
    # 多出来的那条应答再被打到 shell 上（登录时出现 [8;56;179t）。
    install -d ${IMAGE_ROOTFS}/usr/local/bin
    install -m 0755 ${FOGCCC_FILES}/tty-size ${IMAGE_ROOTFS}/usr/local/bin/tty-size
    rm -f ${IMAGE_ROOTFS}/usr/bin/tty-size
    sed -i 's#/usr/bin/tty-size#/usr/local/bin/tty-size#' ${IMAGE_ROOTFS}/etc/profile.d/99-byobu.sh
    grep -q '/usr/local/bin/tty-size' ${IMAGE_ROOTFS}/etc/profile.d/99-byobu.sh || bbfatal "99-byobu.sh does not call /usr/local/bin/tty-size"
    # Yocto 的 /etc/profile 还会在串口 tty 上再调一次 resize（同样是 CSI 18 t，
    # 读不到就放弃，晚到的应答变成登录输入）；串口尺寸只由 tty-size 负责。
    grep -q 'resize >/dev/null' ${IMAGE_ROOTFS}/etc/profile || bbfatal "/etc/profile: resize call not found"
    sed -i 's#resize >/dev/null#: >/dev/null#' ${IMAGE_ROOTFS}/etc/profile

    # 状态栏的 load_average 换成实时 CPU%（D 状态的 tmux 会把 loadavg 抬到 1 以上，误导）
    install -m 0755 ${FOGCCC_FILES}/byobu-cpu-usage ${IMAGE_ROOTFS}/usr/lib/byobu/load_average
    # 右侧各项之间补空格：byobu 的 item 自己不带分隔符
    sed -i 's#printf "%s" "$usage";#printf " %s" "$usage";#' ${IMAGE_ROOTFS}/usr/lib/byobu/memory
    sed -i 's#printf "%s" "$pct";#printf " %s" "$pct";#' ${IMAGE_ROOTFS}/usr/lib/byobu/disk
}
