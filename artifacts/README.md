# artifacts/ —— TF卡烧录文件

卡上分两个分区，文件按分区放置

## 根目录 → BOOT 分区

FAT32，卷标 `BOOT`，约 512 MB。板子由 FSBL 从该分区启动。

| 文件 | 大小 | 说明 |
|---|---|---|
| `BOOT.BIN` | 18.6 MB | FSBL + 比特流 + U-Boot |
| `image.ub` | 47.0 MB | 内核 + 设备树 + initramfs（内置 lf、tty-size 与 921600 的 getty） |
| `boot.scr` | 384 B | 只启动 FOGCCC 的 U-Boot 脚本（`console=ttyPS0,921600`），源文本 `boot-fogccc.cmd` |
| `uEnv.txt` | 40 B | 默认环境 bootargs（921600）；启动脚本不读取 |
| `system.dtb` | 18 KB | 设备树，与 `image.ub` 内的一致 |
| `zynq_fsbl.elf` | 347 KB | 厂商 FSBL 原始 ELF，`BOOT.BIN` 的**构建输入**；考虑到版权问题暂不入库、不随 Release 发布 |
| `mount_data.sh` | 1.2 KB | 板上把两个分区挂到 `/mnt/boot`、`/mnt/userdata` |

## `userdata/` → USERDATA 分区

FAT32，卷标 `USERDATA`。开机由 **udev** 挂到 `/run/media/USERDATA-mmcblk0p2`
（stock `/etc/fstab` 里**没有** p2 条目）；`/mnt/userdata` 需要自己挂：
`sh /mnt/boot/mount_data.sh`（主机脚本 `serial_run_gc.ps1` /
`serial_push_resume.ps1` 也会自己 `mkdir` + `mount`）。两条路径是同一个分区，固定用一个即可。

| 路径 | 说明 |
|---|---|
| `run_gc.sh` | GC 测试入口，需同级 `fpga_vs_python.py` |
| `run_repeat.sh` | 重复测量 |
| `fpga_vs_python.py` | GC 测试主体，`--seed` 可复现 |
| `README.txt` | 卡上目录说明 |
| `bin/test_main` | 板级 C 测试套件 |
| `ko/fogccc-irq.ko` | IRQ_F2P[0] 内核模块，由 PetaLinux 构建产出；不入库，随 `card-userdata.zip` 发布（vermagic 与已发布的 `image.ub` 严格配对）|
| `tests/side_table_test.py` | 容器图（真解释器 `tp_traverse` 边界）→「对象头+引用数组」的板级对照 |
| `tests/irq_drv_test.sh` | 中断驱动端到端验证 |
| `tests/abort_test.py` | `CTRL[3]` abort 的五段验收（基线/控制组/打断/同图恢复/换图恢复） |
| `tests/abort_sweep.py` | abort 相位扫描（0–480 µs），`--delays` 可重复单点 |
| `tests/done_race_test.py` | `START` posted-write 的 stale-DONE 实验 + 连续换图回归 |
| `tests/freelist_contract_test.py` / `tests/freelist_n4096_test.py` | free-list 软件契约负控（A–D）/ 4096 边界全覆盖 |
| `tests/dirty_set_test.py` / `dirty_concurrent_test.py` / `dirty_overflow_test.py` / `dirty_leftover_test.py` / `dirty_state.py` | 阶段 3A/3B：脏集、并发增量标记、溢出、残留屏障、收尾查脏 FIFO |
| `tests/ctrl_spill_test.py` | `CTRL` 写重投递的溢出防护验证 |
| `tests/dirty_api_test.py` | 阶段 3A 的 C 驱动 + ctypes 绑定接口验收（含 `--neg` 反向验证） |
| `tests/py_bfs.py` | Python BFS 参照（独立 oracle，`run_gc.sh` 用） |
| `py/fogccc.py` + `py/libfogccc.so` | Python ctypes 绑定，含 STATUS 与位图探针 |

日志不在本目录，`run_gc.sh` 写入卡上 `logs/`。

以下文件只留在仓库，不放入卡：

| 文件 | 说明 |
|---|---|
| `tools/debug/gic_dump.py`、`tools/debug/gic_irq_test.py` | GIC 诊断，可用 JTAG 读取同样寄存器 |
| `tools/debug/irq_loss_test.sh` | 诊断用途，非验收 |

## 注意

- 串口 921600 8N1；CPU 800 MHz，由 `BOOT.BIN` 里的 FSBL 在 DDR 初始化前设定。
- FOGCCC 镜像内置 `lf` r42（`/usr/bin/lf`）与 `~/.config/lf/lfrc`；`Enter` 用 `vim -R` 只读打开（`:q` 退出），`e` 用 `vim` 编辑（`:q!` 退出），目录不进编辑器，镜像里没有 `xdg-open`。
- 镜像内置 `vim-tiny`（`/usr/bin/vim`）替代 busybox vi，并预置 `~/.vimrc` 与 `/etc/vimrc`，避免 `E1187: Failed to source defaults.vim`。
- 镜像预置 `~/.config/byobu/.welcome-displayed`，登录不再打印 Byobu 欢迎语；tmux 的 DA2 查询（`CSI > c`）改为 `CSI > z`，串口上没有应答漏进 shell。
- 镜像带 `ncurses-terminfo-base`（`/etc/terminfo`），`less` / `vi` 有终端能力库可用。
- 登录时由 `/etc/profile.d/99-byobu.sh` 在启动 byobu 之前调 `/usr/local/bin/tty-size` 探测终端尺寸，这是唯一的 `ESC[18t` 查询者；`/etc/profile` 里 Yocto 自带的 `resize` 在串口 tty 上已停用。
- 状态栏的 `load_average` 项显示实时 CPU%（`/usr/lib/byobu/load_average`），右侧各项之间带空格。
- USERDATA 必须为 FAT32；内核未启用 exFAT。
- `image.ub` 非位级可复现（gzip 时间戳），以功能验证为准。

> 两个随卡二进制（`bin/test_main`、`py/libfogccc.so`）的 SHA256 记录在 `artifacts/SHA256SUMS`。

> 用 `tools/make_manifest.ps1` 重新生成；CI 跑 `-Check`，二进制改了但 manifest 没更新会直接红。

